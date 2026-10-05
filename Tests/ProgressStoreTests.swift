import XCTest
@testable import DeStream

@MainActor
final class ProgressStoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() async throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProgressStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("progress.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func request(_ videoId: String, metaID: String = "tt1", isLocal: Bool = false,
                         subtitle: String? = nil, posterURL: String? = "https://example.com/p.jpg",
                         backgroundURL: String? = nil) -> PlaybackRequest {
        PlaybackRequest(url: URL(string: "https://example.com/v.mkv")!, title: "Title", subtitle: subtitle,
                        metaID: metaID, metaType: "series", videoId: videoId, isLocal: isLocal,
                        filenameHint: nil, posterURL: posterURL, bingeGroup: nil, backgroundURL: backgroundURL)
    }

    func testPersistsAndReloads() throws {
        let store = ProgressStore(fileURL: fileURL)
        store.record(request("tt1:1:1"), seconds: 600, duration: 3000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let reloaded = ProgressStore(fileURL: fileURL)
        let entry = try XCTUnwrap(reloaded.entry(for: "tt1:1:1"))
        XCTAssertEqual(entry.seconds, 600)
        XCTAssertEqual(entry.duration, 3000)
        XCTAssertEqual(entry.posterURL, "https://example.com/p.jpg")
        XCTAssertEqual(entry.fraction, 0.2, accuracy: 0.0001)
    }

    func testResumePosition() {
        let store = ProgressStore(fileURL: fileURL)
        store.record(request("a"), seconds: 8, duration: 3000)
        XCTAssertNil(store.resumePosition(for: "a"), "under 10 s starts from the beginning")
        store.record(request("a"), seconds: 754, duration: 3000)
        XCTAssertEqual(store.resumePosition(for: "a"), 754)
        store.record(request("a"), seconds: 2900, duration: 3000)
        XCTAssertNil(store.resumePosition(for: "a"), "over 92% counts as watched")
        XCTAssertNil(store.resumePosition(for: "missing"))
    }

    func testFinishedEntriesAreMarkedWatched() throws {
        let store = ProgressStore(fileURL: fileURL)
        store.record(request("a"), seconds: 2800, duration: 3000)
        let entry = try XCTUnwrap(store.entry(for: "a"))
        XCTAssertTrue(entry.isFinished)
        XCTAssertEqual(entry.seconds, 3000)
        XCTAssertTrue(store.isWatched("a"))
    }

    func testContinueWatchingFiltersSortsAndDedupes() {
        let store = ProgressStore(fileURL: fileURL)
        let now = Date()
        store.record(request("m1", metaID: "m1"), seconds: 5, duration: 6000, at: now)                        // under 10 s: too early
        store.record(request("m2", metaID: "m2"), seconds: 3000, duration: 6000, at: now.addingTimeInterval(-60))
        store.record(request("m3", metaID: "m3"), seconds: 5900, duration: 6000, at: now)                     // finished
        store.record(request("s:1:1", metaID: "s"), seconds: 1000, duration: 3000, at: now.addingTimeInterval(-120))
        store.record(request("s:1:2", metaID: "s"), seconds: 1500, duration: 3000, at: now.addingTimeInterval(-10))
        store.record(request("nodur", metaID: "x"), seconds: 500, duration: nil, at: now)

        XCTAssertEqual(store.continueWatching.map(\.videoId), ["s:1:2", "m2"])
    }

    func testClear() {
        let store = ProgressStore(fileURL: fileURL)
        store.record(request("a"), seconds: 100, duration: 1000)
        store.clear("a")
        XCTAssertNil(store.entry(for: "a"))
        XCTAssertNil(ProgressStore(fileURL: fileURL).entry(for: "a"))
    }

    func testCorruptFileStartsEmpty() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        XCTAssertTrue(ProgressStore(fileURL: fileURL).entries.isEmpty)
    }

    func testTimeFormatting() {
        XCTAssertEqual(PlayerTime.format(754), "12:34")
        XCTAssertEqual(PlayerTime.format(3725), "1:02:05")
        XCTAssertEqual(PlayerTime.format(nil), "--:--")
    }

    // MARK: - Watch history

    func testRecordFillsEpisodeFields() throws {
        let store = ProgressStore(fileURL: fileURL)
        store.record(request("tt1:1:3", subtitle: "S01E03 · The Pilot · Part 2", backgroundURL: "https://example.com/b.jpg"),
                     seconds: 600, duration: 3000)
        let e = try XCTUnwrap(ProgressStore(fileURL: fileURL).entry(for: "tt1:1:3"))
        XCTAssertEqual(e.season, 1)
        XCTAssertEqual(e.episode, 3)
        XCTAssertEqual(e.episodeCode, "S01E03")
        XCTAssertEqual(e.episodeTitle, "The Pilot · Part 2")
        XCTAssertEqual(e.backgroundURL, "https://example.com/b.jpg")
        XCTAssertEqual(e.isLocal, false)
    }

    func testRequestsOptedOutOfHistoryAreNotRecorded() {
        let store = ProgressStore(fileURL: fileURL)
        var r = request("debug:x", metaID: "debug")
        r.skipsHistory = true
        store.record(r, seconds: 100, duration: 1000)
        XCTAssertNil(store.entry(for: "debug:x"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testEpisodeNumbersFromVideoIds() {
        XCTAssertTrue(ProgressStore.episodeNumbers(videoId: "tt1", metaID: "tt1") == (nil, nil))
        XCTAssertTrue(ProgressStore.episodeNumbers(videoId: "tt1:2:5", metaID: "tt1") == (2, 5))
        XCTAssertTrue(ProgressStore.episodeNumbers(videoId: "kitsu:42:7", metaID: "kitsu:42") == (nil, 7))
        XCTAssertTrue(ProgressStore.episodeNumbers(videoId: "tt9:3:4", metaID: "other") == (3, 4))
    }

    func testLocalArtworkDoesNotReplaceRemote() throws {
        let store = ProgressStore(fileURL: fileURL)
        store.record(request("a", backgroundURL: "https://example.com/b.jpg"), seconds: 600, duration: 3000)
        store.record(request("a", isLocal: true, posterURL: "file:///lib/poster.jpg", backgroundURL: "file:///lib/b.jpg"),
                     seconds: 700, duration: 3000)
        let e = try XCTUnwrap(store.entry(for: "a"))
        XCTAssertEqual(e.posterURL, "https://example.com/p.jpg")
        XCTAssertEqual(e.backgroundURL, "https://example.com/b.jpg")
    }

    func testMissingDurationKeepsPreviousDuration() throws {
        let store = ProgressStore(fileURL: fileURL)
        store.record(request("a"), seconds: 600, duration: 3000)
        store.record(request("a"), seconds: 700, duration: nil)
        XCTAssertEqual(try XCTUnwrap(store.entry(for: "a")).duration, 3000)
    }

    func testRemoveFromLatestHidesWholeTitleAndPersists() {
        let store = ProgressStore(fileURL: fileURL)
        let now = Date()
        store.record(request("s:1:1", metaID: "s"), seconds: 1000, duration: 3000, at: now.addingTimeInterval(-60))
        store.record(request("s:1:2", metaID: "s"), seconds: 1000, duration: 3000, at: now)
        store.record(request("m", metaID: "m"), seconds: 1000, duration: 3000, at: now.addingTimeInterval(-30))
        XCTAssertEqual(store.latestStreamed.map(\.metaID), ["s", "m"])

        store.removeFromContinueWatching(metaID: "s")
        XCTAssertEqual(store.latestStreamed.map(\.metaID), ["m"], "older episodes must not resurface")
        XCTAssertEqual(ProgressStore(fileURL: fileURL).latestStreamed.map(\.metaID), ["m"])
        XCTAssertEqual(store.entries(forMeta: "s").count, 2, "progress is kept for episode lists")
        XCTAssertEqual(store.resumePosition(for: "s:1:2"), 1000)
    }

    func testReplayUnhides() {
        let store = ProgressStore(fileURL: fileURL)
        store.record(request("m", metaID: "m"), seconds: 1000, duration: 3000)
        store.removeFromContinueWatching(metaID: "m")
        XCTAssertTrue(store.latestStreamed.isEmpty)
        store.record(request("m", metaID: "m"), seconds: 1100, duration: 3000)
        XCTAssertEqual(store.latestStreamed.map(\.videoId), ["m"])
        XCTAssertNil(store.entry(for: "m")?.hiddenFromContinueWatching)
    }

    func testMarkWatchedAndUnwatched() throws {
        let store = ProgressStore(fileURL: fileURL)
        store.markWatched(videoId: "tt1:1:1", metaID: "tt1", metaType: "series", title: "Show")
        let e = try XCTUnwrap(store.entry(for: "tt1:1:1"))
        XCTAssertTrue(store.isWatched("tt1:1:1"), "no duration still reads as watched")
        XCTAssertEqual(e.episode, 1)
        XCTAssertNil(store.resumePosition(for: "tt1:1:1"))

        store.record(request("tt1:1:2"), seconds: 1000, duration: 3000)
        store.markWatched(videoId: "tt1:1:2", metaID: "tt1", metaType: "series", title: "Show")
        XCTAssertEqual(store.entry(for: "tt1:1:2")?.seconds, 3000)
        XCTAssertTrue(store.isWatched("tt1:1:2"))
        XCTAssertTrue(store.latestStreamed.isEmpty, "watched titles leave the Latest row")

        store.markUnwatched(videoId: "tt1:1:2")
        XCTAssertFalse(store.isWatched("tt1:1:2"))
        XCTAssertNil(ProgressStore(fileURL: fileURL).entry(for: "tt1:1:2"))
        XCTAssertTrue(ProgressStore(fileURL: fileURL).isWatched("tt1:1:1"))
    }

    func testMarkWatchedOnEntryWithoutDuration() {
        let store = ProgressStore(fileURL: fileURL)
        store.record(request("a"), seconds: 500, duration: nil)
        XCTAssertFalse(store.isWatched("a"))
        store.markWatched(videoId: "a", metaID: "tt1", metaType: "series", title: "Show")
        XCTAssertTrue(store.isWatched("a"))
    }

    func testLatestStreamedFiltersLocal() {
        let store = ProgressStore(fileURL: fileURL)
        let now = Date()
        store.record(request("streamed", metaID: "streamed"), seconds: 1000, duration: 3000, at: now)
        store.record(request("local", metaID: "local", isLocal: true), seconds: 1000, duration: 3000, at: now)
        store.save(.init(videoId: "legacy", metaID: "legacy", metaType: "movie", title: "Legacy", posterURL: nil,
                         seconds: 1000, duration: 3000, updatedAt: now.addingTimeInterval(-60)))
        XCTAssertEqual(Set(store.continueWatching.map(\.metaID)), ["streamed", "local", "legacy"])
        XCTAssertEqual(Set(store.latestStreamed.map(\.metaID)), ["streamed", "legacy"])
        XCTAssertEqual(store.latestStreamed(localMetaIDs: ["legacy", "streamed"]).map(\.metaID), ["streamed"],
                       "explicit isLocal wins; legacy entries of saved titles count as local")
    }

    func testRemainingTextFormatting() {
        XCTAssertEqual(ProgressStore.remainingText(seconds: 600, duration: 600 + 72 * 60), "1 h 12 min left")
        XCTAssertEqual(ProgressStore.remainingText(seconds: 0, duration: 34 * 60), "34 min left")
        XCTAssertEqual(ProgressStore.remainingText(seconds: 0, duration: 2 * 3600), "2 h left")
        XCTAssertEqual(ProgressStore.remainingText(seconds: 2950, duration: 3000), "Under 1 min left")
        XCTAssertEqual(ProgressStore.remainingText(seconds: 0, duration: 59 * 60 + 40), "1 h left", "rounds to the nearest minute")
        XCTAssertEqual(ProgressStore.remainingText(seconds: -50, duration: 600), "10 min left", "negative position clamps to 0")
        XCTAssertNil(ProgressStore.remainingText(seconds: 100, duration: nil))
        XCTAssertNil(ProgressStore.remainingText(seconds: 100, duration: 0))
        XCTAssertNil(ProgressStore.remainingText(seconds: 100, duration: -5))
        XCTAssertNil(ProgressStore.remainingText(seconds: 100, duration: .nan))
        XCTAssertNil(ProgressStore.remainingText(seconds: 3000, duration: 3000))
        XCTAssertNil(ProgressStore.remainingText(seconds: 4000, duration: 3000))
    }

    func testDecodesLegacyFileWithoutNewFields() throws {
        let json = """
        [{"videoId":"tt1:1:2","metaID":"tt1","metaType":"series","title":"Show","posterURL":"https://example.com/p.jpg",
          "seconds":1200,"duration":3000,"updatedAt":"2026-01-02T10:00:00Z"},
         {"videoId":"tt2","metaID":"tt2","metaType":"movie","title":"Film","seconds":10,"updatedAt":"2026-01-01T10:00:00Z"}]
        """
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: fileURL)
        let store = ProgressStore(fileURL: fileURL)
        XCTAssertEqual(store.entries.count, 2)
        let e = try XCTUnwrap(store.entry(for: "tt1:1:2"))
        XCTAssertNil(e.isLocal)
        XCTAssertNil(e.hiddenFromContinueWatching)
        XCTAssertNil(e.episodeCode)
        XCTAssertEqual(store.latestStreamed.map(\.videoId), ["tt1:1:2"])
        XCTAssertNil(store.entry(for: "tt2")?.duration)
    }

    // MARK: - Next up

    private func series(_ count: (season: Int, episodes: Int)...) -> MetaDetail {
        var videos = [Video(id: "tt1:0:1", title: "Special", season: 0, episode: 1)]
        for (s, n) in count {
            for e in 1...n { videos.append(Video(id: "tt1:\(s):\(e)", title: "E\(e)", season: s, episode: e)) }
        }
        return MetaDetail(id: "tt1", type: "series", name: "Show", videos: videos.shuffled())
    }

    func testNextUpDefaultsToFirstEpisode() {
        let store = ProgressStore(fileURL: fileURL)
        XCTAssertEqual(store.nextUp(for: series((1, 3), (2, 2)))?.id, "tt1:1:1", "specials are skipped")
        XCTAssertNil(store.nextUp(for: MetaDetail(id: "m", type: "movie", name: "Film")))
    }

    func testNextUpPrefersInProgressEpisode() {
        let store = ProgressStore(fileURL: fileURL)
        let now = Date()
        store.markWatched(videoId: "tt1:1:1", metaID: "tt1", metaType: "series", title: "Show", duration: 3000)
        store.record(request("tt1:1:2"), seconds: 1000, duration: 3000, at: now.addingTimeInterval(10))
        XCTAssertEqual(store.nextUp(for: series((1, 3)))?.id, "tt1:1:2")
    }

    func testNextUpAfterLastWatched() {
        let store = ProgressStore(fileURL: fileURL)
        let now = Date()
        store.record(request("tt1:1:1"), seconds: 1000, duration: 3000, at: now.addingTimeInterval(-600))  // abandoned
        store.record(request("tt1:1:3"), seconds: 3000, duration: 3000, at: now)
        XCTAssertEqual(store.nextUp(for: series((1, 3), (2, 2)))?.id, "tt1:2:1", "rolls over into the next season")
    }

    func testUpNextCandidatesKeepSeriesWhoseLatestEpisodeIsFinished() {
        let store = ProgressStore(fileURL: fileURL)
        let now = Date()
        store.record(request("tt1:1:9"), seconds: 1000, duration: 3000, at: now.addingTimeInterval(-600))
        store.record(request("tt1:1:10"), seconds: 3000, duration: 3000, at: now)
        store.record(request("tt2:1:1", metaID: "tt2"), seconds: 1000, duration: 3000, at: now)
        XCTAssertEqual(store.upNextCandidates(localMetaIDs: []).map(\.videoId), ["tt1:1:10"])
        XCTAssertEqual(store.nextUp(for: series((1, 10), (2, 2)))?.id, "tt1:2:1")

        store.removeFromContinueWatching(metaID: "tt1")
        XCTAssertTrue(store.upNextCandidates(localMetaIDs: []).isEmpty)
    }

    func testNextUpWrapsWhenEverythingWatched() {
        let store = ProgressStore(fileURL: fileURL)
        for e in 1...2 { store.markWatched(videoId: "tt1:1:\(e)", metaID: "tt1", metaType: "series", title: "Show") }
        XCTAssertEqual(store.nextUp(for: series((1, 2)))?.id, "tt1:1:1")
    }
}
