import XCTest
@testable import DeStream

private final class MemoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var pending: [String]?
    var saves = 0

    var store: AddonStore {
        AddonStore(load: { self.lock.withLock { self.data } },
                   save: { d in self.lock.withLock { self.data = d; self.saves += 1 } },
                   loadPendingDefaults: { self.lock.withLock { self.pending } },
                   savePendingDefaults: { p in self.lock.withLock { self.pending = p } })
    }

    var pendingDefaults: [String]? { lock.withLock { pending } }

    func savedAddons() throws -> [Addon] {
        try JSONDecoder().decode([Addon].self, from: XCTUnwrap(lock.withLock { data }))
    }
}

@MainActor
final class AddonRegistryTests: XCTestCase {
    private let cinemeta = "https://registry.test/cinemeta/manifest.json"
    private let cometSecret = "Q09NRVQtU0VDUkVULUNPTkZJRw"
    private var cometURL: String { "https://comet.registry.test/\(cometSecret)/manifest.json" }

    override func setUp() async throws {
        AddonMockURLProtocol.reset()
        try AddonMockURLProtocol.set(cinemeta, fixture: "cinemeta_manifest")
        try AddonMockURLProtocol.set(cometURL, fixture: "comet_manifest")
    }

    private func makeRegistry(_ mem: MemoryStore, defaults: [String]? = nil) -> AddonRegistry {
        AddonRegistry(client: AddonClient(session: AddonMockURLProtocol.session()), store: mem.store,
                      defaultManifestURLs: defaults ?? [cinemeta])
    }

    func testFirstLaunchInstallsDefaultsAndPersists() async throws {
        let mem = MemoryStore()
        let registry = makeRegistry(mem)
        XCTAssertTrue(registry.addons.isEmpty)
        await registry.refreshManifests()
        XCTAssertEqual(registry.addons.map(\.manifest.id), ["com.linvo.cinemeta"])
        XCTAssertEqual(try mem.savedAddons().first?.manifestURL, cinemeta)

        let reloaded = makeRegistry(mem)
        XCTAssertEqual(reloaded.addons.map(\.manifest.name), ["Cinemeta"], "cached manifest available without network")
    }

    func testRemovedDefaultIsNotReinstalled() async throws {
        let mem = MemoryStore()
        let registry = makeRegistry(mem)
        await registry.refreshManifests()
        registry.remove(registry.addons[0])
        XCTAssertTrue(registry.addons.isEmpty)
        let reloaded = makeRegistry(mem)
        await reloaded.refreshManifests()
        XCTAssertTrue(reloaded.addons.isEmpty)
    }

    func testOfflineFirstLaunchRetriesLater() async throws {
        let mem = MemoryStore()
        let offline = makeRegistry(mem, defaults: ["https://registry.test/offline/manifest.json"])
        await offline.refreshManifests()
        XCTAssertTrue(offline.addons.isEmpty)
        XCTAssertEqual(mem.saves, 0)
    }

    func testUnreadableStoreIsNeverOverwritten() async throws {
        struct Denied: Error {}
        let saves = MemoryStore()
        let store = AddonStore(load: { throw Denied() }, save: saves.store.save)
        let registry = AddonRegistry(client: AddonClient(session: AddonMockURLProtocol.session()), store: store,
                                     defaultManifestURLs: [cinemeta])
        XCTAssertNotNil(registry.storageError)
        await registry.refreshManifests()
        XCTAssertTrue(registry.addons.isEmpty, "defaults must not be installed over an unreadable list")
        try await registry.add(manifestURL: cometURL)
        XCTAssertEqual(registry.addons.count, 1)
        XCTAssertEqual(saves.saves, 0)
    }

    func testAddDuplicateAndConfigureURL() async throws {
        let mem = MemoryStore()
        let registry = makeRegistry(mem)
        let comet = try await registry.add(manifestURL: "https://comet.registry.test/\(cometSecret)/configure")
        XCTAssertEqual(comet.manifestURL, cometURL)

        do {
            try await registry.add(manifestURL: "stremio://comet.registry.test/\(cometSecret)/manifest.json")
            XCTFail("duplicate accepted")
        } catch {
            guard case AddonError.duplicate = error else { return XCTFail("\(error)") }
            XCTAssertFalse(error.localizedDescription.contains(cometSecret))
        }

        let other = "https://comet.registry.test/OTHERCONFIG/manifest.json"
        try AddonMockURLProtocol.set(other, fixture: "comet_manifest")
        try await registry.add(manifestURL: other)
        XCTAssertEqual(registry.addons.count, 2, "same addon with another config is allowed")
        XCTAssertEqual(registry.addons.map(\.order), [0, 1])
    }

    func testManifestURLFieldValidation() {
        XCTAssertEqual(AddonSettingsView.validate(" https://comet.test/abc/configure "), "https://comet.test/abc/manifest.json")
        XCTAssertEqual(AddonSettingsView.validate("stremio://comet.test/abc/manifest.json"), "https://comet.test/abc/manifest.json")
        XCTAssertEqual(AddonSettingsView.validate("comet.test/abc/"), "https://comet.test/abc/manifest.json")
        XCTAssertNil(AddonSettingsView.validate("ftp://comet.test/manifest.json"))
        XCTAssertNil(AddonSettingsView.validate("   "))
    }

    func testAddSameURLAgainFailsWithoutFetching() async throws {
        let registry = makeRegistry(MemoryStore())
        try await registry.add(manifestURL: cinemeta)
        AddonMockURLProtocol.set(cinemeta, AddonMockURLProtocol.Route(error: .notConnectedToInternet))
        do {
            try await registry.add(manifestURL: cinemeta + "/")
            XCTFail("duplicate accepted")
        } catch {
            guard case AddonError.duplicate = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(registry.addons.count, 1)
    }

    func testAddInvalidManifestFails() async {
        AddonMockURLProtocol.set("https://registry.test/html/manifest.json", json: "<html></html>")
        let registry = makeRegistry(MemoryStore())
        do {
            try await registry.add(manifestURL: "https://registry.test/html/manifest.json")
            XCTFail()
        } catch {
            XCTAssertTrue(registry.addons.isEmpty)
        }
    }

    func testMoveEnableRemovePersist() async throws {
        let mem = MemoryStore()
        let registry = makeRegistry(mem)
        try await registry.add(manifestURL: cinemeta)
        try await registry.add(manifestURL: cometURL)
        let third = "https://comet.registry.test/THIRD/manifest.json"
        try AddonMockURLProtocol.set(third, fixture: "comet_manifest")
        try await registry.add(manifestURL: third)
        let ids = registry.addons.map(\.id)

        registry.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(registry.addons.map(\.id), [ids[1], ids[2], ids[0]])
        registry.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(registry.addons.map(\.id), ids)
        registry.move(fromOffsets: IndexSet([0, 2]), toOffset: 2)
        XCTAssertEqual(registry.addons.map(\.id), [ids[1], ids[0], ids[2]])
        XCTAssertEqual(try mem.savedAddons().map(\.id), [ids[1], ids[0], ids[2]])
        XCTAssertEqual(registry.addons.map(\.order), [0, 1, 2])

        registry.setEnabled(registry.addons[0], false)
        XCTAssertEqual(registry.enabledAddons.map(\.id), [ids[0], ids[2]])
        XCTAssertEqual(try mem.savedAddons().map(\.enabled), [false, true, true])

        registry.remove(registry.addons[1])
        XCTAssertEqual(makeRegistry(mem).addons.map(\.id), [ids[1], ids[2]])
    }

    func testRefreshKeepsCachedManifestWhenOffline() async throws {
        let mem = MemoryStore()
        let registry = makeRegistry(mem)
        try await registry.add(manifestURL: cinemeta)
        AddonMockURLProtocol.set(cinemeta, AddonMockURLProtocol.Route(error: .notConnectedToInternet))
        await registry.refreshManifests()
        XCTAssertEqual(registry.addons.first?.manifest.name, "Cinemeta")
    }

    func testRefreshUpdatesManifest() async throws {
        let registry = makeRegistry(MemoryStore())
        try await registry.add(manifestURL: cinemeta)
        AddonMockURLProtocol.set(cinemeta, json: #"{"id":"com.linvo.cinemeta","name":"Cinemeta 2","resources":["meta"],"types":["movie"]}"#)
        await registry.refreshManifests()
        XCTAssertEqual(registry.addons.first?.manifest.name, "Cinemeta 2")
    }

    func testCatalogSelection() async throws {
        let registry = makeRegistry(MemoryStore())
        try await registry.add(manifestURL: cinemeta)
        try await registry.add(manifestURL: cometURL)
        XCTAssertEqual(registry.homeCatalogs.map(\.catalog.stableID), ["movie/top", "series/top", "movie/imdbRating", "series/imdbRating"])
        XCTAssertEqual(registry.searchCatalogs.map(\.catalog.stableID), ["movie/top", "series/top"])
        XCTAssertEqual(registry.addons(for: "stream", type: "series", id: "tt1:1:1").map(\.manifest.id), ["comet.elfhosted.com"])
        XCTAssertEqual(registry.addons(for: "meta", type: "series", id: "tt1").map(\.manifest.id), ["com.linvo.cinemeta"])
        registry.setEnabled(registry.addons[0], false)
        XCTAssertTrue(registry.homeCatalogs.isEmpty)
    }

    func testMetaFallsBackToNextAddon() async throws {
        let broken = "https://broken.registry.test/manifest.json"
        try AddonMockURLProtocol.set(broken, fixture: "cinemeta_manifest")
        let registry = makeRegistry(MemoryStore())
        try await registry.add(manifestURL: broken)
        try await registry.add(manifestURL: cinemeta)
        AddonMockURLProtocol.set("https://broken.registry.test/meta/series/tt0903747.json", json: "", status: 503)
        try AddonMockURLProtocol.set("https://registry.test/cinemeta/meta/series/tt0903747.json", fixture: "cinemeta_meta_series_tt0903747")
        let meta = try await registry.meta(type: "series", id: "tt0903747")
        XCTAssertEqual(meta.name, "Breaking Bad")

        do {
            _ = try await registry.meta(type: "series", id: "kitsu:1")
            XCTFail()
        } catch {
            guard case AddonError.notFound = error else { return XCTFail("\(error)") }
        }
    }

    func testStreamsMergeSortAndTimeout() async throws {
        let slow = "https://slow.registry.test/SLOWSECRET/manifest.json"
        let failing = "https://fail.registry.test/FAILSECRET/manifest.json"
        for url in [slow, failing] { try AddonMockURLProtocol.set(url, fixture: "comet_manifest") }
        let registry = makeRegistry(MemoryStore())
        registry.streamTimeout = 0.5
        let first = try await registry.add(manifestURL: cometURL)
        try await registry.add(manifestURL: slow)
        try await registry.add(manifestURL: failing)
        let second = "https://comet2.registry.test/manifest.json"
        try AddonMockURLProtocol.set(second, fixture: "comet_manifest")
        let last = try await registry.add(manifestURL: second)

        let id = "tt0903747:1:1"
        try AddonMockURLProtocol.set("https://comet.registry.test/\(cometSecret)/stream/series/\(id).json", fixture: "comet_streams_sample")
        AddonMockURLProtocol.set("https://slow.registry.test/SLOWSECRET/stream/series/\(id).json", json: #"{"streams":[]}"#, delay: 5)
        AddonMockURLProtocol.set("https://fail.registry.test/FAILSECRET/stream/series/\(id).json", json: "", status: 500)
        AddonMockURLProtocol.set("https://comet2.registry.test/stream/series/\(id).json",
                                 json: #"{"streams":[{"name":"[TB⬇️] B","url":"https://x.test/1"},{"name":"[TB⚡] A","url":"https://x.test/2"}]}"#)

        let start = Date()
        let result = await registry.streams(type: "series", id: id)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)

        XCTAssertEqual(result.streams.map(\.stream.name), [
            "[TB⚡] Comet 1080p", "[TB⚡] Comet 720p", "[TB⬇️] Comet 2160p", "[TB⬇️] Comet 480p",
            "[TB⚡] A", "[TB⬇️] B",
        ])
        XCTAssertEqual(result.streams.first?.id, "\(first.id.uuidString)-0")
        XCTAssertEqual(result.streams.last?.id, "\(last.id.uuidString)-1")
        XCTAssertEqual(result.streams.first?.addonID, first.id.uuidString)
        XCTAssertEqual(registry.addon(withID: result.streams[0].addonID)?.id, first.id)
        XCTAssertEqual(Set(result.streams.map(\.id)).count, result.streams.count)

        XCTAssertEqual(result.errors.count, 2)
        XCTAssertTrue(result.errors[0].contains("timed out"), result.errors[0])
        XCTAssertTrue(result.errors[1].contains("HTTP 500"), result.errors[1])
        for e in result.errors {
            XCTAssertFalse(e.contains("SECRET"), e)
        }
    }

    // MARK: - Recommended addons

    private let catalogsURL = "https://registry.test/catalogs/manifest.json"
    private let kitsuURL = "https://registry.test/kitsu/manifest.json"
    private let subsURL = "https://registry.test/subs/manifest.json"

    func testRecommendedListIsConsistent() {
        let recs = AddonRegistry.recommended
        XCTAssertEqual(Set(recs.map(\.id)).count, recs.count)
        XCTAssertEqual(Set(recs.map(\.manifestURL)).count, recs.count)
        for rec in recs {
            XCTAssertTrue(rec.manifestURL.hasPrefix("https://") && rec.manifestURL.hasSuffix("/manifest.json"), rec.name)
            XCTAssertFalse(rec.summary.isEmpty)
        }
        XCTAssertEqual(AddonRegistry.defaultManifestURLs.first, AddonRegistry.cinemetaManifestURL)
        XCTAssertTrue(Set(AddonRegistry.defaultManifestURLs).isSubset(of: recs.map(\.manifestURL)))
    }

    func testRecommendedFixturesMatchManifestIDs() throws {
        let fixtures = ["com.linvo.cinemeta": "cinemeta_manifest",
                        "pw.ers.netflix-catalog": "streaming_catalogs_manifest",
                        "community.anime.kitsu": "kitsu_manifest",
                        "org.stremio.opensubtitlesv3": "opensubtitles_manifest"]
        XCTAssertEqual(Set(fixtures.keys), Set(AddonRegistry.recommended.map(\.manifestID)))
        for (id, name) in fixtures {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures/\(name)", withExtension: "json"))
            let manifest = try AddonClient.decode(Manifest.self, from: Data(contentsOf: url), label: name)
            XCTAssertEqual(manifest.id, id)
            let hasHomeRows = !manifest.catalogs.filter { $0.requiredExtras.isEmpty }.isEmpty
            XCTAssertTrue(hasHomeRows || manifest.supports(resource: "subtitles", type: "movie", id: "tt0111161"),
                          "\(name) adds home rows or subtitles")
            XCTAssertFalse(manifest.resources.contains { $0.name == "stream" }, "\(name) must not be a stream provider")
        }
    }

    func testFirstLaunchInstallsAllDefaultsInOrder() async throws {
        try AddonMockURLProtocol.set(catalogsURL, fixture: "streaming_catalogs_manifest")
        try AddonMockURLProtocol.set(subsURL, fixture: "opensubtitles_manifest")
        let mem = MemoryStore()
        let registry = makeRegistry(mem, defaults: [cinemeta, catalogsURL, subsURL])
        await registry.refreshManifests()
        XCTAssertEqual(registry.addons.map(\.manifest.id), ["com.linvo.cinemeta", "pw.ers.netflix-catalog", "org.stremio.opensubtitlesv3"])
        XCTAssertEqual(try mem.savedAddons().map(\.manifestURL), [cinemeta, catalogsURL, subsURL])
        XCTAssertEqual(mem.pendingDefaults, [])
        XCTAssertEqual(registry.recommendedNotInstalled.map(\.manifestID), ["community.anime.kitsu"])
        XCTAssertEqual(registry.addons(for: "subtitles", type: "movie", id: "tt0111161").map(\.manifest.id),
                       ["org.stremio.opensubtitlesv3"])
    }

    func testRecommendedNotInstalledTracksInstalledManifestIDs() async throws {
        try AddonMockURLProtocol.set(kitsuURL, fixture: "kitsu_manifest")
        let registry = makeRegistry(MemoryStore(), defaults: [])
        XCTAssertEqual(registry.recommendedNotInstalled, AddonRegistry.recommended)

        let kitsu = try await registry.add(manifestURL: kitsuURL)
        XCTAssertFalse(registry.recommendedNotInstalled.contains { $0.manifestID == "community.anime.kitsu" },
                       "matched by manifest id, not URL")
        try await registry.add(manifestURL: cometURL)
        XCTAssertEqual(registry.recommendedNotInstalled.count, AddonRegistry.recommended.count - 1)

        registry.remove(kitsu)
        XCTAssertTrue(registry.recommendedNotInstalled.contains { $0.manifestID == "community.anime.kitsu" })
    }

    func testFailedDefaultIsRetriedUntilInstalledOnce() async throws {
        let mem = MemoryStore()
        let first = makeRegistry(mem, defaults: [cinemeta, subsURL])
        await first.refreshManifests()
        XCTAssertEqual(first.addons.map(\.manifest.id), ["com.linvo.cinemeta"], "subtitles addon unreachable")
        XCTAssertEqual(mem.pendingDefaults, [subsURL])

        let stillOffline = makeRegistry(mem, defaults: [cinemeta, subsURL])
        await stillOffline.refreshManifests()
        XCTAssertEqual(stillOffline.addons.count, 1)
        XCTAssertEqual(mem.pendingDefaults, [subsURL])

        try AddonMockURLProtocol.set(subsURL, fixture: "opensubtitles_manifest")
        let online = makeRegistry(mem, defaults: [cinemeta, subsURL])
        await online.refreshManifests()
        XCTAssertEqual(online.addons.map(\.manifest.id), ["com.linvo.cinemeta", "org.stremio.opensubtitlesv3"])
        XCTAssertEqual(mem.pendingDefaults, [])

        online.remove(online.addons[1])
        let later = makeRegistry(mem, defaults: [cinemeta, subsURL])
        await later.refreshManifests()
        XCTAssertEqual(later.addons.map(\.manifest.id), ["com.linvo.cinemeta"], "removed default stays removed")
    }

    func testRemovedDefaultWhilePendingOthersIsNotReinstalled() async throws {
        let mem = MemoryStore()
        let first = makeRegistry(mem, defaults: [cinemeta, subsURL])
        await first.refreshManifests()
        first.remove(first.addons[0])

        try AddonMockURLProtocol.set(subsURL, fixture: "opensubtitles_manifest")
        let next = makeRegistry(mem, defaults: [cinemeta, subsURL])
        await next.refreshManifests()
        XCTAssertEqual(next.addons.map(\.manifest.id), ["org.stremio.opensubtitlesv3"], "only the never-installed default is retried")
    }

    func testExistingListWithoutPendingGetsNoNewDefaults() async throws {
        let mem = MemoryStore()
        let old = makeRegistry(mem, defaults: [cinemeta])
        await old.refreshManifests()
        try AddonMockURLProtocol.set(subsURL, fixture: "opensubtitles_manifest")
        let upgraded = makeRegistry(mem, defaults: [cinemeta, subsURL])
        await upgraded.refreshManifests()
        XCTAssertEqual(upgraded.addons.map(\.manifest.id), ["com.linvo.cinemeta"])
    }
}

final class KeychainTests: XCTestCase {
    func testRoundTrip() throws {
        let key = "test-\(UUID().uuidString)"
        defer { Keychain.delete(key) }
        XCTAssertNil(Keychain.get(key))
        try Keychain.set(Data("one".utf8), for: key)
        XCTAssertEqual(Keychain.get(key), Data("one".utf8))
        try Keychain.set(Data("two".utf8), for: key)
        XCTAssertEqual(Keychain.get(key), Data("two".utf8))
        Keychain.delete(key)
        XCTAssertNil(Keychain.get(key))
    }
}
