import XCTest
@testable import DeStream

enum CoreFixtures {
    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: ModelDecodingTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "Fixtures/\(name)", withExtension: "json")
            ?? bundle.url(forResource: name, withExtension: "json"), "missing fixture \(name)")
        return try Data(contentsOf: url)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: data(name))
    }
}

final class ModelDecodingTests: XCTestCase {
    func testCinemetaManifest() throws {
        let m = try CoreFixtures.decode(Manifest.self, "cinemeta_manifest")
        XCTAssertEqual(m.id, "com.linvo.cinemeta")
        XCTAssertEqual(m.name, "Cinemeta")
        XCTAssertEqual(m.resources.map(\.name), ["catalog", "meta", "addon_catalog"])
        XCTAssertEqual(m.catalogs.count, 8)

        let top = try XCTUnwrap(m.catalogs.first { $0.stableID == "movie/top" })
        XCTAssertTrue(top.supportsSearch)
        XCTAssertTrue(top.supportsSkip)
        XCTAssertTrue(top.requiredExtras.isEmpty)
        let year = try XCTUnwrap(m.catalogs.first { $0.stableID == "movie/year" })
        XCTAssertFalse(year.supportsSearch)
        XCTAssertTrue(year.requiredExtras.contains("genre"))
        XCTAssertEqual(year.extra?.first?.options?.first, "2026")
    }

    func testCometManifest() throws {
        let m = try CoreFixtures.decode(Manifest.self, "comet_manifest")
        XCTAssertEqual(m.id, "comet.elfhosted.com")
        XCTAssertTrue(m.catalogs.isEmpty)
        XCTAssertEqual(m.behaviorHints?.configurable, true)
        XCTAssertTrue(m.supports(resource: "stream", type: "series", id: "tt0903747:1:1"))
        XCTAssertTrue(m.supports(resource: "stream", type: "movie", id: "kitsu:1"))
        XCTAssertFalse(m.supports(resource: "stream", type: "movie", id: "yt:abc"))
        XCTAssertFalse(m.supports(resource: "stream", type: "anime", id: "tt1"), "resource types override manifest types")
        XCTAssertFalse(m.supports(resource: "meta", type: "movie"))
    }

    func testManifestSupportsWithGlobalPrefixes() throws {
        let m = try CoreFixtures.decode(Manifest.self, "cinemeta_manifest")
        XCTAssertTrue(m.supports(resource: "meta", type: "series", id: "tt0903747"))
        XCTAssertTrue(m.supports(resource: "meta", type: "movie"))
        XCTAssertFalse(m.supports(resource: "meta", type: "series", id: "kitsu:1"))
        XCTAssertFalse(m.supports(resource: "meta", type: "channel"))
        XCTAssertFalse(m.supports(resource: "stream", type: "movie"))
    }

    func testManifestMinimalAndNoPrefixes() throws {
        let json = #"{"id":"x","name":"X","resources":["stream"],"types":["movie"]}"#
        let m = try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))
        XCTAssertEqual(m.version, "0")
        XCTAssertTrue(m.supports(resource: "stream", type: "movie", id: "anything:1"))
    }

    func testManifestRoundTrip() throws {
        let m = try CoreFixtures.decode(Manifest.self, "cinemeta_manifest")
        let again = try JSONDecoder().decode(Manifest.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(m, again)
    }

    func testCatalogExtras() throws {
        let m = try CoreFixtures.decode(Manifest.self, "catalog_extras_manifest")
        XCTAssertEqual(m.catalogs.map(\.id), ["trending", "by-year", "search-only", "legacy", "required-no-options",
                                               "calendar", "required-twice"], "invalid catalogs are dropped, not fatal")
        let c = Dictionary(uniqueKeysWithValues: m.catalogs.map { ($0.id, $0) })

        let trending = try XCTUnwrap(c["trending"])
        XCTAssertEqual(trending.genreOptions, ["Action", "Sci-Fi"])
        XCTAssertTrue(trending.supportsGenre && trending.supportsSkip && !trending.supportsSearch)
        XCTAssertTrue(trending.isBrowsable && trending.isDiscoverable)
        XCTAssertEqual(trending.extraOrder, ["genre", "skip"])

        let year = try XCTUnwrap(c["by-year"])
        XCTAssertEqual(year.genreOptions, ["2026", "2025", "2024.5"], "numeric options become strings, null is dropped")
        XCTAssertTrue(year.requiresGenre)
        XCTAssertEqual(year.requiredExtras, ["genre"])
        XCTAssertFalse(year.isBrowsable)
        XCTAssertTrue(year.isDiscoverable)
        XCTAssertEqual(year.extraOrder, ["skip", "genre"])

        let search = try XCTUnwrap(c["search-only"])
        XCTAssertTrue(search.supportsSearch)
        XCTAssertFalse(search.isBrowsable)
        XCTAssertFalse(search.isDiscoverable)

        let legacy = try XCTUnwrap(c["legacy"])
        XCTAssertEqual(legacy.genreOptions, ["Drama", "Comedy"])
        XCTAssertTrue(legacy.supportsGenre && legacy.isDiscoverable)

        XCTAssertFalse(try XCTUnwrap(c["required-no-options"]).isDiscoverable, "required genre with nothing to pick")
        let calendar = try XCTUnwrap(c["calendar"])
        XCTAssertFalse(calendar.isBrowsable || calendar.isDiscoverable)
        XCTAssertEqual(calendar.extra?.first?.optionsLimit, 100)
        XCTAssertEqual(calendar.displayName, "calendar")
        XCTAssertEqual(try XCTUnwrap(c["required-twice"]).requiredExtras, ["genre"])
    }

    func testCinemetaCatalogExtras() throws {
        let m = try CoreFixtures.decode(Manifest.self, "cinemeta_manifest")
        let discoverable = m.catalogs.filter(\.isDiscoverable).map(\.stableID)
        XCTAssertEqual(discoverable, ["movie/top", "series/top", "movie/year", "series/year", "movie/imdbRating", "series/imdbRating"])
        XCTAssertEqual(m.catalogs.filter(\.isBrowsable).count, 4)
        let year = try XCTUnwrap(m.catalogs.first { $0.stableID == "movie/year" })
        XCTAssertTrue(year.requiresGenre)
        XCTAssertEqual(year.genreOptions.first, "2026")
        XCTAssertEqual(m.catalogs.first { $0.stableID == "movie/top" }?.extraOrder, ["genre", "search", "skip"])
    }

    func testCatalogExtrasRoundTrip() throws {
        let m = try CoreFixtures.decode(Manifest.self, "catalog_extras_manifest")
        XCTAssertEqual(try JSONDecoder().decode(Manifest.self, from: JSONEncoder().encode(m)), m)
    }

    func testCatalogTop() throws {
        let r = try CoreFixtures.decode(CatalogResponse.self, "cinemeta_catalog_movie_top")
        XCTAssertEqual(r.metas.count, 50)
        XCTAssertTrue(r.metas.allSatisfy { $0.type == "movie" && !$0.id.isEmpty && $0.poster != nil })
    }

    func testSearch() throws {
        let r = try CoreFixtures.decode(CatalogResponse.self, "cinemeta_search_series")
        XCTAssertEqual(r.metas.count, 5)
        XCTAssertEqual(r.metas.first?.id, "tt0903747")
        XCTAssertEqual(r.metas.first?.releaseInfo, "2008-2013")
    }

    func testMetaMovie() throws {
        let meta = try CoreFixtures.decode(MetaResponse.self, "cinemeta_meta_movie_tt0111161").meta
        XCTAssertEqual(meta.id, "tt0111161")
        XCTAssertEqual(meta.name, "The Shawshank Redemption")
        XCTAssertEqual(meta.allGenres, ["Drama"])
        XCTAssertEqual(meta.displayYear, "1994")
        XCTAssertEqual(meta.runtime, "142 min")
        XCTAssertEqual(meta.imdbRating, "9.3")
    }

    func testMetaSeries() throws {
        let meta = try CoreFixtures.decode(MetaResponse.self, "cinemeta_meta_series_tt0903747").meta
        XCTAssertEqual(meta.type, "series")
        XCTAssertEqual(meta.videos?.count, 67)
        XCTAssertEqual(meta.seasons, [1, 2, 3, 4, 5, 0])
        let s1 = meta.episodes(season: 1)
        XCTAssertEqual(s1.count, 7)
        XCTAssertEqual(s1.first?.id, "tt0903747:1:1")
        XCTAssertEqual(s1.first?.displayTitle, "Pilot")
        XCTAssertEqual(s1.first?.episodeCode, "S01E01")
        XCTAssertEqual(s1.first?.released, "2008-01-21T05:00:00.000Z")
        XCTAssertNotNil(s1.first?.thumbnail)
        XCTAssertNotNil(meta.background)
        XCTAssertNotNil(meta.logo)
    }

    func testVideoNumberFallbackAndLossyFields() throws {
        let json = #"{"id":"tt1:2:3","name":"Ep","season":"2","number":3,"released":12345}"#
        let v = try JSONDecoder().decode(Video.self, from: Data(json.utf8))
        XCTAssertEqual(v.season, 2)
        XCTAssertEqual(v.episode, 3)
        XCTAssertNil(v.released)
        XCTAssertEqual(v.displayTitle, "Ep")
    }

    func testMetaToleratesNumbersAndBadVideos() throws {
        let json = #"{"meta":{"id":"x","type":"series","name":"X","year":2020,"imdbRating":8.1,"genres":["A",1],"videos":[{"id":"x:1:1","season":1,"episode":1},{"title":"no id"}]}}"#
        let meta = try JSONDecoder().decode(MetaResponse.self, from: Data(json.utf8)).meta
        XCTAssertEqual(meta.year, "2020")
        XCTAssertEqual(meta.imdbRating, "8.1")
        XCTAssertEqual(meta.genres, ["A"])
        XCTAssertEqual(meta.videos?.map(\.id), ["x:1:1"])
    }

    func testLossyCatalog() throws {
        let json = #"{"metas":[{"id":"a","type":"movie","name":"A","imdbRating":7.5},{"id":"b"},null,{"id":"c","type":"movie","name":"C"}]}"#
        let r = try JSONDecoder().decode(CatalogResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.metas.map(\.id), ["a", "c"])
        XCTAssertEqual(r.metas.first?.imdbRating, "7.5")
        XCTAssertEqual(try JSONDecoder().decode(CatalogResponse.self, from: Data(#"{"metas":[]}"#.utf8)).metas.count, 0)
        XCTAssertEqual(try JSONDecoder().decode(CatalogResponse.self, from: Data(#"{}"#.utf8)).metas.count, 0)
        XCTAssertEqual(try JSONDecoder().decode(StreamResponse.self, from: Data(#"{"streams":[]}"#.utf8)).streams.count, 0)
    }

    func testCometStreams() throws {
        let streams = try CoreFixtures.decode(StreamResponse.self, "comet_streams_sample").streams
        XCTAssertEqual(streams.count, 4, "broken entries are dropped")
        XCTAssertEqual(streams.map(\.isCached), [false, true, true, false])

        let cached = streams[1]
        XCTAssertEqual(cached.name, "[TB⚡] Comet 1080p")
        XCTAssertTrue(cached.details.contains("💾 2.3 GB"))
        XCTAssertEqual(cached.filename, "Breaking.Bad.S01E01.1080p.BluRay.x264-SAMPLE.mkv")
        XCTAssertEqual(cached.behaviorHints?.bingeGroup, "comet|2222222222222222222222222222222222222222")
        XCTAssertEqual(cached.behaviorHints?.videoSize, 2_469_606_195)
        XCTAssertEqual(cached.playableURL?.host, "comet.elfhosted.com")
        XCTAssertEqual(cached.containerExtension, "mkv")
        XCTAssertEqual(streams[2].containerExtension, "mp4")

        let torrent = streams[3]
        XCTAssertNil(torrent.playableURL)
        XCTAssertEqual(torrent.fileIdx, 0)
        XCTAssertEqual(torrent.behaviorHints?.videoSize, 367_001_600)
    }

    func testIsCachedMarkers() {
        func s(_ name: String, _ title: String? = nil) -> DeStream.Stream { DeStream.Stream(url: "https://x/y", name: name, title: title) }
        XCTAssertTrue(s("[TB⚡] Comet 1080p").isCached)
        XCTAssertTrue(s("[RD+] Torrentio").isCached)
        XCTAssertTrue(s("Torrentio", "[TB+] 4k").isCached)
        XCTAssertFalse(s("[TB⬇️] Comet 2160p").isCached)
        XCTAssertFalse(s("[RD download] Torrentio").isCached)
        XCTAssertFalse(s("Some HTTP addon").isCached)
    }

    func testPlayableURLRejectsNonHTTP() {
        XCTAssertNotNil(DeStream.Stream(url: "https://a.b/c.mp4").playableURL)
        XCTAssertNotNil(DeStream.Stream(url: "HTTP://a.b/c.mp4").playableURL)
        XCTAssertNil(DeStream.Stream(url: "file:///etc/passwd").playableURL)
        XCTAssertNil(DeStream.Stream(url: "javascript:alert(1)").playableURL)
        XCTAssertNil(DeStream.Stream(url: "magnet:?xt=urn:btih:abc").playableURL)
        XCTAssertNil(DeStream.Stream(infoHash: "abc").playableURL)
    }

    func testStreamWithoutSourceIsRejected() {
        XCTAssertThrowsError(try JSONDecoder().decode(DeStream.Stream.self, from: Data(#"{"name":"x"}"#.utf8)))
    }
}

final class AddonModelTests: XCTestCase {
    private func addon(_ url: String) throws -> Addon {
        Addon(id: UUID(), manifestURL: url, manifest: try CoreFixtures.decode(Manifest.self, "comet_manifest"), enabled: true, order: 0)
    }

    func testBaseURL() throws {
        XCTAssertEqual(try addon("https://v3-cinemeta.strem.io/manifest.json").baseURL?.absoluteString, "https://v3-cinemeta.strem.io")
        XCTAssertEqual(try addon("stremio://comet.example.com/c0nf1g/manifest.json").baseURL?.absoluteString, "https://comet.example.com/c0nf1g")
        XCTAssertEqual(try addon("  https://a.example/b/manifest.json \n").baseURL?.absoluteString, "https://a.example/b")
        XCTAssertEqual(try addon("https://a.example/b/configure").baseURL?.absoluteString, "https://a.example/b")
    }

    func testNormalizeManifestURL() {
        XCTAssertEqual(Addon.normalizeManifestURL("stremio://x.example/abc/manifest.json"), "https://x.example/abc/manifest.json")
        XCTAssertEqual(Addon.normalizeManifestURL("https://comet.example/SECRET/configure"), "https://comet.example/SECRET/manifest.json")
        XCTAssertEqual(Addon.normalizeManifestURL("https://comet.example/SECRET/configure/"), "https://comet.example/SECRET/manifest.json")
        XCTAssertEqual(Addon.normalizeManifestURL("https://comet.example/configure"), "https://comet.example/manifest.json")
        XCTAssertEqual(Addon.normalizeManifestURL(" https://v3-cinemeta.strem.io/manifest.json "), "https://v3-cinemeta.strem.io/manifest.json")
    }

    func testRedact() throws {
        let secret = "eyJ0b3Jib3hLZXkiOiJTRUNSRVQifQ"
        let redacted = Addon.redact("https://comet.elfhosted.com/\(secret)/manifest.json")
        XCTAssertEqual(redacted, "https://comet.elfhosted.com/…")
        XCTAssertFalse(redacted.contains(secret))
        XCTAssertEqual(Addon.redact("not a url"), "<addon>")
        XCTAssertEqual(Addon.redact("https://user:pw@host.example/x"), "https://host.example/…")
        XCTAssertFalse(try addon("https://comet.elfhosted.com/\(secret)/manifest.json").redactedURL.contains(secret))
    }
}

@MainActor
final class SearchGroupingTests: XCTestCase {
    private func meta(_ id: String, _ type: String, _ name: String) -> MetaPreview { MetaPreview(id: id, type: type, name: name) }

    func testDedupesByIdAndGroupsByType() {
        let cinemeta = [meta("tt1", "series", "Batman Beyond"), meta("tt2", "movie", "The Batman"), meta("tt3", "movie", "Batman")]
        let other = [meta("tt3", "movie", "Batman (dup)"), meta("kitsu:1", "anime", "Batman Ninja"), meta("tt4", "movie", "Batman Begins")]
        let groups = SearchView.group([cinemeta, other], query: "batman")
        XCTAssertEqual(groups.map(\.type), ["movie", "series", "anime"])
        XCTAssertEqual(groups[0].items.map(\.id), ["tt3", "tt4", "tt2"], "exact, then prefix, then other matches")
        XCTAssertEqual(groups[0].items.first?.name, "Batman", "first occurrence wins")
        XCTAssertEqual(groups.flatMap(\.items).count, 5)
    }
}
