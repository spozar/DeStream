import XCTest
@testable import DeStream

private struct FakeTMDB: TMDBService {
    var recs: [String: [MetaPreview]] = [:]
    var backdrops: [String: String] = [:]
    var fails = false

    func recommendations(imdbID: String, type: String, limit: Int) async throws -> [MetaPreview] {
        if fails { throw URLError(.notConnectedToInternet) }
        return Array((recs[imdbID] ?? []).prefix(limit))
    }

    func backdrop(imdbID: String, type: String) async throws -> String? {
        if fails { throw URLError(.notConnectedToInternet) }
        return backdrops[imdbID]
    }
}

@MainActor
final class RecommendationEngineTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!
    private var suiteName = ""
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("RecTests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "RecTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: Helpers

    private func item(_ id: String, type: String = "movie", daysAgo: Double, overall: Int64 = 0, duration: Int64 = 6_000_000,
                      timesWatched: Int = 0, removed: Bool = false, temp: Bool = true) -> StremioLibraryItem {
        let date = now.addingTimeInterval(-daysAgo * day)
        return StremioLibraryItem(id: id, name: "Name \(id)", type: type, poster: "https://img/\(id).jpg",
                                  removed: removed, temp: temp, ctime: date, mtime: date,
                                  state: .init(lastWatched: date, overallTimeWatched: overall,
                                               timesWatched: timesWatched, duration: duration))
    }

    private func entry(_ videoId: String, metaID: String, type: String = "movie", seconds: Double, duration: Double = 6000,
                       daysAgo: Double) -> ProgressStore.Entry {
        ProgressStore.Entry(videoId: videoId, metaID: metaID, metaType: type, title: "Local \(metaID)",
                            posterURL: "https://img/\(metaID).jpg", seconds: seconds, duration: duration,
                            updatedAt: now.addingTimeInterval(-daysAgo * day))
    }

    private func previews(_ ids: [String]) -> [MetaPreview] {
        ids.map { MetaPreview(id: $0, type: "movie", name: "Rec \($0)") }
    }

    private func range(_ prefix: String, _ count: Int) -> [String] {
        (1...count).map { "\(prefix)\($0)" }
    }

    private func make(history: Recommendations.History, hasKey: Bool = false, tmdb: FakeTMDB? = nil,
                      metas: [String: [String]] = [:], catalogs: [String: [MetaPreview]] = [:]) -> Recommendations {
        let now = now
        return Recommendations(
            history: { history },
            tmdbAvailable: { hasKey },
            makeTMDB: { tmdb },
            fetchMeta: { type, id in
                guard let genres = metas[id] else { throw AddonError.notFound }
                return MetaDetail(id: id, type: type, name: id, background: "https://bg/\(id).jpg", genres: genres)
            },
            fetchCatalog: { type, genre in
                guard let list = catalogs["\(type)/\(genre ?? "")"] else { throw AddonError.notFound }
                return list
            },
            cacheDirectory: dir, defaults: defaults, now: { now })
    }

    private func feed(_ recs: Recommendations) throws -> RecommendationFeed {
        guard case .loaded(let feed) = recs.phase else {
            return try XCTUnwrap(nil as RecommendationFeed?, "phase is \(recs.phase), expected loaded")
        }
        return feed
    }

    // MARK: Seeds

    func testSeedsWeightRecencyAndEngagementAndDedupe() {
        let items = [
            item("tt1", daysAgo: 1, overall: 6_000_000, timesWatched: 1),   // recent, completed
            item("tt2", daysAgo: 120, overall: 6_000_000, timesWatched: 1), // old, completed
            item("tt3", daysAgo: 1, overall: 300_000),                      // recent, barely watched
            item("tt4", daysAgo: 1),                                        // never watched
            item("kitsu:5", type: "series", daysAgo: 1, overall: 1_000),    // not IMDb
            item("tt6", type: "channel", daysAgo: 1, overall: 1_000),       // unsupported type
        ]
        let progress = [
            entry("tt1", metaID: "tt1", seconds: 6000, daysAgo: 0),         // same as tt1 → merged
            entry("tt7:1:1", metaID: "tt7", type: "series", seconds: 3000, daysAgo: 2),
            entry("tt7:1:2", metaID: "tt7", type: "series", seconds: 3000, daysAgo: 3),
        ]
        let seeds = Recommendations.computeSeeds(libraryItems: items, progress: progress, now: now)
        XCTAssertEqual(Set(seeds.map(\.metaID)), ["tt1", "tt2", "tt3", "tt7"])
        XCTAssertEqual(seeds.first?.metaID, "tt1")
        XCTAssertEqual(seeds.filter { $0.metaID == "tt1" }.count, 1)
        XCTAssertEqual(seeds.first?.name, "Name tt1", "Stremio name wins")
        XCTAssertEqual(seeds.first?.lastWatched, now, "latest watch date across sources")
        let weight = Dictionary(uniqueKeysWithValues: seeds.map { ($0.metaID, $0.weight) })
        XCTAssertGreaterThan(weight["tt1"]!, weight["tt3"]!, "engagement")
        XCTAssertGreaterThan(weight["tt3"]!, weight["tt2"]!, "recency decay over four half-lives")
        XCTAssertEqual(seeds.first { $0.metaID == "tt7" }?.type, "series")
        XCTAssertEqual(seeds.map(\.weight), seeds.map(\.weight).sorted(by: >))
    }

    func testIgnoredTitlesDontSeedButStayInHistory() async throws {
        let history = Recommendations.History(
            libraryItems: [item("tt1", daysAgo: 1, overall: 6_000_000), item("tt2", daysAgo: 2, overall: 6_000_000)],
            progress: [])
        let recs = make(history: history, catalogs: ["movie/": previews(range("ttP", 10))])
        recs.setCountsTowardSuggestions(false, metaID: "tt1")
        XCTAssertFalse(recs.countsTowardSuggestions("tt1"))
        XCTAssertEqual(recs.watchHistory().map(\.metaID), ["tt1", "tt2"], "history lists ignored titles too")

        await recs.load()
        XCTAssertEqual(recs.seeds.map(\.metaID), ["tt2"])
        XCTAssertEqual(make(history: history).ignoredSeedIDs, ["tt1"], "persisted")

        recs.setCountsTowardSuggestions(true, metaID: "tt1")
        await recs.load(force: true)
        XCTAssertEqual(Set(recs.seeds.map(\.metaID)), ["tt1", "tt2"])
    }

    func testRemoveFromHistoryClearsAndForgetsIgnore() {
        var cleared: [String] = []
        let recs = Recommendations(history: { .init(libraryItems: [], progress: []) },
                                   clearHistory: { cleared.append($0) },
                                   tmdbAvailable: { false }, makeTMDB: { nil },
                                   fetchMeta: { _, _ in throw AddonError.notFound },
                                   fetchCatalog: { _, _ in [] },
                                   cacheDirectory: dir, defaults: defaults, now: { [now] in now })
        recs.setCountsTowardSuggestions(false, metaID: "tt1")
        let version = recs.historyVersion
        recs.removeFromHistory(metaID: "tt1")
        XCTAssertEqual(cleared, ["tt1"])
        XCTAssertTrue(recs.ignoredSeedIDs.isEmpty)
        XCTAssertEqual(recs.historyVersion, version + 1)
    }

    func testSeedsAreCapped() {
        let items = (1...20).map { item("tt\($0)", daysAgo: Double($0), overall: 6_000_000) }
        XCTAssertEqual(Recommendations.computeSeeds(libraryItems: items, progress: [], now: now).count, 8)
    }

    func testExclusionsCoverWatchedStartedAndLibrary() {
        let items = [
            item("tt1", daysAgo: 1, overall: 1_000),                 // watched
            item("tt2", daysAgo: 1, temp: false),                    // bookmarked, unwatched
            item("tt3", daysAgo: 1, removed: true, temp: false),     // removed, unwatched
        ]
        let progress = [entry("tt4", metaID: "tt4", seconds: 5, daysAgo: 1)]
        XCTAssertEqual(Recommendations.exclusions(libraryItems: items, progress: progress), ["tt1", "tt2", "tt4"])
    }

    // MARK: TMDB

    func testTMDBRowsFilterDedupeAndTopPicks() {
        let seeds = [
            RecommendationSeed(metaID: "ttA", type: "movie", name: "A", lastWatched: now, weight: 2),
            RecommendationSeed(metaID: "ttB", type: "movie", name: "B", lastWatched: now, weight: 1),
            RecommendationSeed(metaID: "ttC", type: "movie", name: "C", lastWatched: now, weight: 0.5),
        ]
        let results = [
            previews(["ttShared", "ttX1", "ttX2", "ttX3", "ttX4", "ttB", "ttWatched"]),
            previews(["ttShared", "ttY1", "ttY2", "ttY3", "ttY4"]),
            previews(["ttShared", "ttZ1", "ttZ2"]),   // too few left after filtering
        ]
        let rows = Recommendations.tmdbRows(seeds: seeds, results: results, excluded: ["ttWatched"])
        XCTAssertEqual(rows.map(\.id), ["top", "because-ttA", "because-ttB"])
        XCTAssertEqual(rows[0].title, "Top Picks for You")
        XCTAssertEqual(rows[0].items.first?.id, "ttShared", "recommended by every seed")
        XCTAssertEqual(rows[1].title, "Because you watched A")
        let all = rows.flatMap(\.items).map(\.id)
        XCTAssertFalse(all.contains("ttWatched"))
        XCTAssertFalse(all.contains("ttB"), "seeds are never suggested")
        XCTAssertLessThanOrEqual(all.filter { $0 == "ttShared" }.count, 2)
    }

    func testTMDBLoadBuildsFeedAndEnrichesSeeds() async throws {
        let history = Recommendations.History(
            libraryItems: [item("tt1", daysAgo: 1, overall: 6_000_000), item("tt2", daysAgo: 2, overall: 6_000_000)],
            progress: [])
        let tmdb = FakeTMDB(recs: ["tt1": previews(range("ttA", 6)), "tt2": previews(range("ttB", 6))],
                            backdrops: ["tt1": "https://tmdb/bg1.jpg"])
        let recs = make(history: history, hasKey: true, tmdb: tmdb)
        XCTAssertEqual(recs.source, .tmdb, "defaults to TMDB when a key exists")
        await recs.load()
        let feed = try feed(recs)
        XCTAssertEqual(feed.source, .tmdb)
        XCTAssertEqual(feed.rows.map(\.id), ["top", "because-tt1", "because-tt2"])
        XCTAssertEqual(recs.seeds.first?.background, "https://tmdb/bg1.jpg")
        XCTAssertNil(recs.notice)
    }

    func testFallsBackToCinemetaWhenTMDBFails() async throws {
        let history = Recommendations.History(libraryItems: [item("tt1", daysAgo: 1, overall: 6_000_000)], progress: [])
        let recs = make(history: history, hasKey: true, tmdb: FakeTMDB(fails: true),
                        metas: ["tt1": ["Thriller", "Drama"]],
                        catalogs: ["movie/Thriller": previews(range("ttT", 6)), "movie/Drama": previews(range("ttD", 6))])
        await recs.load()
        let feed = try feed(recs)
        XCTAssertEqual(feed.source, .cinemeta)
        XCTAssertNotNil(recs.notice)
        XCTAssertEqual(feed.rows.first?.kind, .topPicks)
        XCTAssertEqual(Set(feed.rows.dropFirst().map(\.title)), ["Top Thriller Movies", "Top Drama Movies"])
        XCTAssertEqual(recs.seeds.first?.background, "https://bg/tt1.jpg")
    }

    // MARK: Cinemeta

    func testCinemetaRanksGenresAndFiltersExclusions() async throws {
        let history = Recommendations.History(
            libraryItems: [item("tt1", daysAgo: 1, overall: 6_000_000), item("tt2", type: "series", daysAgo: 1, overall: 6_000_000),
                           item("ttLib", daysAgo: 1, temp: false)],
            progress: [])
        let recs = make(history: history,
                        metas: ["tt1": ["Action"], "tt2": ["Comedy"]],
                        catalogs: ["movie/Action": previews(["ttLib", "tt2"] + range("ttM", 5)),
                                   "series/Comedy": previews(range("ttS", 5))])
        XCTAssertEqual(recs.source, .cinemeta)
        XCTAssertEqual(recs.availableSources, [.cinemeta])
        await recs.load()
        let feed = try feed(recs)
        XCTAssertTrue(feed.rows.dropFirst().map(\.title).contains("Top Comedy Series"))
        let ids = feed.rows.flatMap(\.items).map(\.id)
        XCTAssertFalse(ids.contains("ttLib"))
        XCTAssertFalse(ids.contains("tt2"))
    }

    func testNoHistoryAndFailure() async {
        let empty = make(history: .init(libraryItems: [], progress: []))
        await empty.load()
        XCTAssertEqual(empty.phase, .noHistory)

        let offline = make(history: .init(libraryItems: [item("tt1", daysAgo: 1, overall: 1_000)], progress: []))
        await offline.load()
        guard case .failed = offline.phase else { return XCTFail("expected failed, got \(offline.phase)") }
    }

    // MARK: Cache & dismissals

    func testCachedFeedIsServedWithoutNetwork() async throws {
        let history = Recommendations.History(libraryItems: [item("tt1", daysAgo: 1, overall: 6_000_000)], progress: [])
        let first = make(history: history, metas: ["tt1": ["Action"]],
                         catalogs: ["movie/Action": previews(range("ttM", 6))])
        await first.load()
        let original = try feed(first)

        let second = make(history: history)   // no network data at all
        await second.load()
        XCTAssertEqual(try feed(second), original)
    }

    func testDismissIsImmediateAndPersisted() async throws {
        let history = Recommendations.History(libraryItems: [item("tt1", daysAgo: 1, overall: 6_000_000)], progress: [])
        let catalogs = ["movie/Action": previews(range("ttM", 6))]
        let recs = make(history: history, metas: ["tt1": ["Action"]], catalogs: catalogs)
        await recs.load()
        recs.dismiss(metaID: "ttM1")
        XCTAssertFalse(try feed(recs).rows.flatMap(\.items).contains { $0.id == "ttM1" })

        let reopened = make(history: history, metas: ["tt1": ["Action"]], catalogs: catalogs)
        XCTAssertEqual(reopened.dismissedIDs, ["ttM1"])
        await reopened.load(force: true)
        XCTAssertFalse(try feed(reopened).rows.flatMap(\.items).contains { $0.id == "ttM1" })
    }

    func testSourceChoiceIsPersisted() {
        let history = Recommendations.History(libraryItems: [], progress: [])
        let recs = make(history: history, hasKey: true)
        recs.source = .cinemeta
        XCTAssertEqual(make(history: history, hasKey: true).source, .cinemeta)
        XCTAssertEqual(make(history: history, hasKey: false).effectiveSource, .cinemeta)
    }
}
