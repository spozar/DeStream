import XCTest
@testable import DeStream

private final class FakeCollection: @unchecked Sendable {
    private let lock = NSLock()
    private var _remote: [StremioAddonDescriptor]
    private var _pushes: [[StremioAddonDescriptor]] = []
    private var _fetches = 0
    var error: StremioAPIError?

    init(_ remote: [StremioAddonDescriptor]) { _remote = remote }

    var remote: [StremioAddonDescriptor] {
        get { lock.withLock { _remote } }
        set { lock.withLock { _remote = newValue } }
    }
    var pushes: [[StremioAddonDescriptor]] { lock.withLock { _pushes } }
    var fetches: Int { lock.withLock { _fetches } }

    var api: AddonCollectionAPI {
        AddonCollectionAPI(
            fetch: { _ in
                try self.lock.withLock {
                    self._fetches += 1
                    if let e = self.error { throw e }
                    return self._remote
                }
            },
            push: { addons, _ in
                self.lock.withLock {
                    self._pushes.append(addons)
                    self._remote = addons
                }
            })
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    var addonStore: AddonStore { AddonStore(load: { self.lock.withLock { self.data } }, save: { d in self.lock.withLock { self.data = d } }) }
    var syncStore: AddonSyncStore { AddonSyncStore(load: { self.lock.withLock { self.data } }, save: { d in self.lock.withLock { self.data = d } }) }
}

@MainActor
final class AddonSyncTests: XCTestCase {
    private let cinemetaURL = "https://v3-cinemeta.strem.io/manifest.json"
    private let subsURL = "https://opensubtitles-v3.strem.io/manifest.json"
    private let kitsuURL = "https://anime-kitsu.strem.fun/manifest.json"
    private let cometURL = "https://comet.sync.test/U0VDUkVU/manifest.json"
    private let localFilesURL = "http://127.0.0.1:11470/local-addon/manifest.json"

    private var creds: AddonSync.Credentials? = AddonSync.Credentials(userID: "user-1", authKey: "auth")
    private var syncStore = DataBox()
    private var registryStore = DataBox()

    override func setUp() async throws {
        creds = AddonSync.Credentials(userID: "user-1", authKey: "auth")
        syncStore = DataBox()
        registryStore = DataBox()
        AddonMockURLProtocol.reset()
    }

    // MARK: - Fixtures

    private func json(_ fixture: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: CoreFixtures.data(fixture))
    }

    private func descriptor(_ fixture: String, _ url: String, official: Bool = false, protected: Bool = false) throws -> StremioAddonDescriptor {
        StremioAddonDescriptor(transportUrl: url, manifest: try json(fixture), flags: .init(official: official, protected: protected))
    }

    private var cinemeta: StremioAddonDescriptor { get throws { try descriptor("cinemeta_manifest", cinemetaURL, official: true, protected: true) } }
    private var subs: StremioAddonDescriptor { get throws { try descriptor("opensubtitles_manifest", subsURL, official: true) } }
    private var kitsu: StremioAddonDescriptor { get throws { try descriptor("kitsu_manifest", kitsuURL) } }
    private var comet: StremioAddonDescriptor { get throws { try descriptor("comet_manifest", cometURL) } }
    private var localFiles: StremioAddonDescriptor {
        StremioAddonDescriptor(
            transportUrl: localFilesURL,
            manifest: .object(["id": .string("org.stremio.local"), "name": .string("Local Files"), "version": .string("1.10.0"),
                               "resources": .array([.string("meta"), .string("stream")]),
                               "types": .array([.string("movie"), .string("series")]),
                               "catalogs": .array([]), "idPrefixes": .array([.string("local:"), .string("bt:")])]),
            flags: .init(official: true, protected: true))
    }

    private func local(_ d: StremioAddonDescriptor, enabled: Bool = true) throws -> Addon {
        var a = try XCTUnwrap(AddonSync.addon(from: d))
        a.enabled = enabled
        return a
    }

    private func make(local: [Addon], remote: FakeCollection) -> (AddonSync, AddonRegistry) {
        let registry = AddonRegistry(client: AddonClient(session: AddonMockURLProtocol.session()),
                                     store: registryStore.addonStore, defaultManifestURLs: [])
        registry.applySynced(local)
        let sync = AddonSync(account: StremioAccount(keychainKey: "test.addonSync.auth"), registry: registry,
                             api: remote.api, store: syncStore.syncStore,
                             credentials: { [unowned self] in self.creds }, fetchManifestJSON: { _ in nil })
        return (sync, registry)
    }

    private func ids(_ addons: [Addon]) -> [String] { addons.map(\.manifest.id) }
    private func ids(_ collection: [StremioAddonDescriptor]) -> [String] { collection.map { $0.manifestID ?? "" } }

    // MARK: - Mapping

    func testDescriptorRoundTripKeepsUnknownFieldsAndFlags() throws {
        let original = try cinemeta
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StremioAddonDescriptor.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertNotNil(decoded.manifest["addonCatalogs"], "fields DeStream doesn't model survive")
        XCTAssertTrue(decoded.flags.protected && decoded.flags.official)

        let addon = try XCTUnwrap(AddonSync.addon(from: original))
        XCTAssertEqual(addon.manifestURL, cinemetaURL)
        XCTAssertEqual(addon.syncKey, original.syncKey)

        let back = AddonSync.descriptor(for: addon)
        XCTAssertEqual(back.transportUrl, cinemetaURL)
        XCTAssertEqual(back.manifestID, "com.linvo.cinemeta")
        XCTAssertEqual(AddonSync.manifest(from: back.manifest), addon.manifest)
        XCTAssertTrue(back.flags.official)
    }

    func testSupportedAddons() throws {
        XCTAssertTrue(AddonSync.isSupported(try cinemeta))
        XCTAssertTrue(AddonSync.isSupported(try comet))
        XCTAssertFalse(AddonSync.isSupported(localFiles), "localhost transport")
        let catalogOnly = StremioAddonDescriptor(
            transportUrl: "https://addons.sync.test/manifest.json",
            manifest: .object(["id": .string("x.addoncatalog"), "name": .string("X"), "version": .string("1"),
                               "resources": .array([.string("addon_catalog")]), "types": .array([.string("all")])]),
            flags: .init())
        XCTAssertFalse(AddonSync.isSupported(catalogOnly))
    }

    func testInterleaveKeepsSecondaryNeighbours() {
        XCTAssertEqual(AddonSync.interleave(["c", "a", "d"], ["a", "x", "c", "d", "y"]), ["c", "a", "x", "d", "y"])
        XCTAssertEqual(AddonSync.interleave(["b"], ["x", "b"]), ["x", "b"])
    }

    // MARK: - First sync

    func testFirstSyncChoiceIsPersistedPerUser() async throws {
        let remote = FakeCollection([try cinemeta])
        let (sync, registry) = make(local: [], remote: remote)
        XCTAssertTrue(sync.needsFirstSyncChoice)
        try await sync.sync()
        XCTAssertEqual(remote.fetches, 0, "ongoing sync waits for the choice")

        try await sync.performFirstSync(.useAccount)
        XCTAssertFalse(sync.needsFirstSyncChoice)

        let reopened = AddonSync(account: StremioAccount(keychainKey: "test.addonSync.auth"), registry: registry,
                                 api: remote.api, store: syncStore.syncStore,
                                 credentials: { [unowned self] in self.creds }, fetchManifestJSON: { _ in nil })
        XCTAssertFalse(reopened.needsFirstSyncChoice)
        creds = AddonSync.Credentials(userID: "user-2", authKey: "auth2")
        XCTAssertTrue(reopened.needsFirstSyncChoice)
        creds = nil
        XCTAssertFalse(reopened.needsFirstSyncChoice, "signed out")
    }

    func testUseAccountReplacesLocalAndSkipsUnsupported() async throws {
        let remote = FakeCollection([try cinemeta, localFiles, try subs])
        let (sync, registry) = make(local: [try local(kitsu)], remote: remote)
        try await sync.performFirstSync(.useAccount)
        XCTAssertEqual(ids(registry.addons), ["com.linvo.cinemeta", "org.stremio.opensubtitlesv3"])
        XCTAssertTrue(remote.pushes.isEmpty)
        XCTAssertEqual(sync.accountOnlyAddonNames, ["Local Files"])
    }

    func testKeepThisDeviceKeepsProtectedAndUnsupportedRemote() async throws {
        let remote = FakeCollection([try cinemeta, localFiles, try subs])
        let (sync, registry) = make(local: [try local(kitsu), try local(comet)], remote: remote)
        try await sync.performFirstSync(.keepThisDevice)
        XCTAssertEqual(registry.addons.map(\.manifestURL), [kitsuURL, cometURL])
        let pushed = try XCTUnwrap(remote.pushes.last)
        XCTAssertEqual(pushed.map(\.transportUrl), [cinemetaURL, localFilesURL, kitsuURL, cometURL])
        XCTAssertEqual(pushed[1], localFiles, "unsupported addon pushed back untouched")
        XCTAssertEqual(sync.accountOnlyAddonNames, ["Cinemeta", "Local Files"])
    }

    func testMergeAppendsLocalOnlyAndPreservesEnabled() async throws {
        let remote = FakeCollection([try cinemeta, localFiles, try subs])
        let (sync, registry) = make(local: [try local(kitsu), try local(cinemeta, enabled: false)], remote: remote)
        try await sync.performFirstSync(.merge)
        XCTAssertEqual(registry.addons.map(\.manifestURL), [cinemetaURL, subsURL, kitsuURL])
        XCTAssertFalse(registry.addons[0].enabled, "local enabled flag kept")
        XCTAssertEqual(remote.pushes.last?.map(\.transportUrl), [cinemetaURL, localFilesURL, subsURL, kitsuURL])
        XCTAssertEqual(remote.pushes.last?[0], try cinemeta, "remote manifest JSON kept as-is")
    }

    // MARK: - Ongoing sync

    private func synced(local: [Addon], remote: [StremioAddonDescriptor]) async throws -> (AddonSync, AddonRegistry, FakeCollection) {
        let fake = FakeCollection(remote)
        let (sync, registry) = make(local: local, remote: fake)
        try await sync.performFirstSync(.merge)
        return (sync, registry, fake)
    }

    func testRemoteChangesApplyLocally() async throws {
        let (sync, registry, fake) = try await synced(local: [try local(cinemeta), try local(subs, enabled: false)],
                                                      remote: [try cinemeta, localFiles, try subs])
        let pushesBefore = fake.pushes.count
        fake.remote = [try subs, try kitsu, localFiles]
        try await sync.sync()
        XCTAssertEqual(registry.addons.map(\.manifestURL), [subsURL, kitsuURL], "remote add, remove and reorder applied")
        XCTAssertFalse(registry.addons[0].enabled)
        XCTAssertEqual(fake.pushes.count, pushesBefore, "nothing to push")
    }

    func testLocalChangesArePushedKeepingUnsupportedInPlace() async throws {
        let (sync, registry, fake) = try await synced(local: [try local(cinemeta), try local(subs)],
                                                      remote: [try cinemeta, localFiles, try subs])
        try AddonMockURLProtocol.set(kitsuURL, fixture: "kitsu_manifest")
        var changes = 0
        registry.onChange = { changes += 1 }
        registry.move(fromOffsets: [1], toOffset: 0)
        try await registry.add(manifestURL: kitsuURL)
        registry.setEnabled(registry.addons[0], false)
        XCTAssertEqual(changes, 2, "add and move notify; enable/disable is local-only")

        try await sync.sync()
        XCTAssertEqual(fake.remote.map(\.transportUrl), [subsURL, cinemetaURL, localFilesURL, kitsuURL])
        XCTAssertEqual(registry.addons.map(\.manifestURL), [subsURL, cinemetaURL, kitsuURL])
        XCTAssertFalse(registry.addons[0].enabled)
        XCTAssertEqual(changes, 2, "applying a sync doesn't re-trigger")
    }

    func testBothReorderedLocalWins() async throws {
        let (sync, registry, fake) = try await synced(local: [try local(cinemeta), try local(subs), try local(kitsu)],
                                                      remote: [try cinemeta, try subs, try kitsu])
        fake.remote = [try kitsu, try cinemeta, try subs, try comet]
        registry.move(fromOffsets: [0], toOffset: 3)
        try await sync.sync()
        XCTAssertEqual(registry.addons.map(\.manifestURL), [subsURL, cometURL, kitsuURL, cinemetaURL],
                       "local order wins; the remote-added addon lands after its remote predecessor")
        XCTAssertEqual(fake.remote.map(\.transportUrl), [subsURL, cometURL, kitsuURL, cinemetaURL])
    }

    func testLocalRemovalWinsAndRemoteRemovalApplies() async throws {
        let (sync, registry, fake) = try await synced(local: [try local(cinemeta), try local(subs), try local(kitsu)],
                                                      remote: [try cinemeta, try subs, try kitsu])
        fake.remote = [try cinemeta, try kitsu]
        registry.remove(try XCTUnwrap(registry.addons.first { $0.manifestURL == kitsuURL }))
        try await sync.sync()
        XCTAssertEqual(registry.addons.map(\.manifestURL), [cinemetaURL])
        XCTAssertEqual(fake.remote.map(\.transportUrl), [cinemetaURL])
    }

    func testRemovingProtectedAddonOnlyHidesItHere() async throws {
        let (sync, registry, fake) = try await synced(local: [try local(cinemeta), try local(subs)],
                                                      remote: [try cinemeta, localFiles, try subs])
        registry.remove(registry.addons[0])
        try await sync.sync()
        XCTAssertEqual(fake.remote.map(\.transportUrl), [cinemetaURL, localFilesURL, subsURL])
        XCTAssertEqual(registry.addons.map(\.manifestURL), [subsURL])
        try await sync.sync()
        XCTAssertEqual(registry.addons.map(\.manifestURL), [subsURL], "not reinstalled on the next sync")
        XCTAssertEqual(sync.accountOnlyAddonNames, ["Cinemeta", "Local Files"])
    }

    func testNewLocalAddonUsesRawManifest() async throws {
        let raw = try json("comet_manifest")
        let fake = FakeCollection([try cinemeta])
        let registry = AddonRegistry(client: AddonClient(session: AddonMockURLProtocol.session()),
                                     store: registryStore.addonStore, defaultManifestURLs: [])
        registry.applySynced([try local(comet)])
        let sync = AddonSync(account: StremioAccount(keychainKey: "test.addonSync.auth"), registry: registry,
                             api: fake.api, store: syncStore.syncStore,
                             credentials: { [unowned self] in self.creds }, fetchManifestJSON: { _ in raw })
        try await sync.performFirstSync(.merge)
        XCTAssertEqual(fake.remote.last?.manifest, raw)
    }

    func testUnauthorizedIsRethrown() async throws {
        let (sync, _, fake) = try await synced(local: [], remote: [try cinemeta])
        fake.error = .unauthorized
        do {
            try await sync.sync()
            XCTFail("expected unauthorized")
        } catch let e as StremioAPIError {
            XCTAssertEqual(e, .unauthorized)
        }
    }

    func testSignedOutIsNoOp() async throws {
        let (sync, _, fake) = try await synced(local: [], remote: [try cinemeta])
        let fetches = fake.fetches
        creds = nil
        try await sync.sync()
        XCTAssertEqual(fake.fetches, fetches)
    }
}
