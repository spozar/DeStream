import XCTest
@testable import DeStream

private actor MockLibraryAPI: StremioLibraryAPI {
    var remote: [String: StremioLibraryItem] = [:]
    var pushed: [[StremioLibraryItem]] = []
    var pulledIDs: [[String]] = []
    var failUnauthorized = false

    func seed(_ items: [StremioLibraryItem]) { for item in items { remote[item.id] = item } }
    func setFailUnauthorized(_ value: Bool) { failUnauthorized = value }

    func libraryMeta(authKey: String) async throws -> [StremioItemMeta] {
        if failUnauthorized { throw StremioAPIError.unauthorized }
        return remote.values.map { StremioItemMeta(id: $0.id, mtime: $0.mtime) }
    }

    func libraryItems(ids: [String]?, authKey: String) async throws -> [StremioLibraryItem] {
        pulledIDs.append(ids ?? [])
        return (ids ?? Array(remote.keys)).compactMap { remote[$0] }
    }

    func putLibraryItems(_ items: [StremioLibraryItem], authKey: String) async throws {
        pushed.append(items)
        for item in items { remote[item.id] = item }
    }
}

@MainActor
final class LibrarySyncTests: XCTestCase {
    private var dir: URL!
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)
    private var signedIn = true

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("LibrarySyncTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func make(_ api: MockLibraryAPI, progress: ProgressStore? = nil) -> (LibrarySync, ProgressStore) {
        let progress = progress ?? ProgressStore(fileURL: dir.appendingPathComponent("progress.json"))
        let account = StremioAccount(keychainKey: "destream.tests.\(UUID().uuidString)",
                                     defaults: UserDefaults(suiteName: "LibrarySyncTests-\(UUID().uuidString)")!)
        let sync = LibrarySync(account: account, progress: progress, api: api,
                               fileURL: dir.appendingPathComponent("stremio-library.json"),
                               credentials: { [unowned self] in signedIn ? ("user1", "key") : nil },
                               now: { [unowned self] in clock })
        return (sync, progress)
    }

    private func request(_ videoId: String, metaID: String, type: String = "series") -> PlaybackRequest {
        PlaybackRequest(url: URL(string: "https://example.com/v.mkv")!, title: "Show", subtitle: nil,
                        metaID: metaID, metaType: type, videoId: videoId, isLocal: false,
                        filenameHint: nil, posterURL: "https://example.com/p.jpg", bingeGroup: nil)
    }

    private func remoteItem(_ id: String, type: String = "series", mtime: Date, videoId: String?, offset: Int64,
                            duration: Int64 = 3_000_000, removed: Bool = false, temp: Bool = false) -> StremioLibraryItem {
        StremioLibraryItem(id: id, name: "Remote \(id)", type: type, poster: "https://example.com/r.jpg",
                           removed: removed, temp: temp, ctime: mtime, mtime: mtime,
                           state: .init(lastWatched: mtime, timeOffset: offset, duration: duration, videoId: videoId))
    }

    // MARK: Remote → local

    func testRemoteProgressBecomesContinueWatchingEntry() async throws {
        let api = MockLibraryAPI()
        await api.seed([remoteItem("tt1", mtime: clock, videoId: "tt1:2:3", offset: 600_000)])
        let (sync, progress) = make(api)
        try await sync.sync()

        let entry = try XCTUnwrap(progress.entry(for: "tt1:2:3"))
        XCTAssertEqual(entry.seconds, 600)
        XCTAssertEqual(entry.duration, 3000)
        XCTAssertEqual(entry.metaID, "tt1")
        XCTAssertEqual(entry.season, 2)
        XCTAssertEqual(entry.episode, 3)
        XCTAssertEqual(entry.title, "Remote tt1")
        XCTAssertEqual(entry.updatedAt, clock)
        XCTAssertEqual(progress.continueWatching.map(\.videoId), ["tt1:2:3"])
        XCTAssertNotNil(sync.items["tt1"])
        XCTAssertNotNil(sync.lastSyncedAt)
    }

    func testRemoteItemOutsideContinueWatchingIsHidden() async throws {
        let api = MockLibraryAPI()
        await api.seed([remoteItem("tt2", type: "movie", mtime: clock, videoId: "tt2", offset: 600_000, removed: true)])
        let (sync, progress) = make(api)
        try await sync.sync()
        XCTAssertEqual(progress.entry(for: "tt2")?.hiddenFromContinueWatching, true)
        XCTAssertTrue(progress.continueWatching.isEmpty)
    }

    func testRemoteDismissHidesLocalEntry() async throws {
        let api = MockLibraryAPI()
        let (sync, progress) = make(api)
        progress.record(request("tt3", metaID: "tt3", type: "movie"), seconds: 600, duration: 3000, at: clock)
        try await sync.sync()
        XCTAssertEqual(progress.continueWatching.count, 1)

        clock += 60
        var dismissed = try XCTUnwrap(sync.items["tt3"])
        dismissed.state.timeOffset = 0
        dismissed.mtime = clock
        await api.seed([dismissed])
        clock += 1
        try await sync.sync()
        XCTAssertTrue(progress.continueWatching.isEmpty)
    }

    func testOlderRemoteProgressDoesNotOverwriteNewerLocal() async throws {
        let api = MockLibraryAPI()
        let (sync, progress) = make(api)
        await api.seed([remoteItem("tt4", mtime: clock - 3600, videoId: "tt4:1:1", offset: 100_000)])
        progress.record(request("tt4:1:1", metaID: "tt4"), seconds: 900, duration: 3000, at: clock)
        try await sync.sync()

        XCTAssertEqual(progress.entry(for: "tt4:1:1")?.seconds, 900)
        let pushed = await api.remote["tt4"]
        XCTAssertEqual(pushed?.state.timeOffset, 900_000)
    }

    func testNewerRemoteWinsOverOlderLocal() async throws {
        let api = MockLibraryAPI()
        let (sync, progress) = make(api)
        progress.record(request("tt5:1:1", metaID: "tt5"), seconds: 300, duration: 3000, at: clock)
        try await sync.sync()

        clock += 3600
        await api.seed([remoteItem("tt5", mtime: clock, videoId: "tt5:1:2", offset: 1_200_000)])
        clock += 1
        try await sync.sync()
        XCTAssertEqual(progress.entry(for: "tt5:1:2")?.seconds, 1200)
        XCTAssertEqual(sync.items["tt5"]?.state.videoId, "tt5:1:2")
        XCTAssertEqual(progress.continueWatching.first?.videoId, "tt5:1:2")
    }

    func testWatchedBitfieldAppliesWhenEpisodesRegistered() async throws {
        let api = MockLibraryAPI()
        let videos = ["tt6:1:1", "tt6:1:2", "tt6:1:3"]
        var item = remoteItem("tt6", mtime: clock, videoId: nil, offset: 0)
        item.state.watched = WatchedBitfield.encode(watched: ["tt6:1:1", "tt6:1:2"], videoIDs: videos)
        await api.seed([item])
        let (sync, progress) = make(api)
        try await sync.sync()

        XCTAssertEqual(sync.watchedVideoIDs(metaID: "tt6", videoIDs: videos), ["tt6:1:1", "tt6:1:2"])
        XCTAssertFalse(progress.isWatched("tt6:1:1"))
        sync.registerVideos(metaID: "tt6", videoIDs: videos)
        XCTAssertTrue(progress.isWatched("tt6:1:1"))
        XCTAssertTrue(progress.isWatched("tt6:1:2"))
        XCTAssertFalse(progress.isWatched("tt6:1:3"))
    }

    // MARK: Local → remote

    func testPlaybackCreatesTempItemLikeStremioCore() async throws {
        let api = MockLibraryAPI()
        let (sync, progress) = make(api)
        var changes = 0
        sync.onLocalChange = { changes += 1 }

        progress.record(request("tt7:1:1", metaID: "tt7"), seconds: 60, duration: 3000, at: clock)
        clock += 30
        progress.record(request("tt7:1:1", metaID: "tt7"), seconds: 90, duration: 3000, at: clock)
        XCTAssertEqual(changes, 2)

        let item = try XCTUnwrap(sync.items["tt7"])
        XCTAssertTrue(item.temp)
        XCTAssertTrue(item.removed)
        XCTAssertFalse(sync.isInLibrary("tt7"))
        XCTAssertTrue(LibrarySync.isInContinueWatching(item))
        XCTAssertEqual(item.state.videoId, "tt7:1:1")
        XCTAssertEqual(item.state.timeOffset, 90_000)
        XCTAssertEqual(item.state.duration, 3_000_000)
        XCTAssertEqual(item.state.timeWatched, 30_000)
        XCTAssertEqual(item.state.lastWatched, clock)
        XCTAssertEqual(item.mtime, clock)
        XCTAssertEqual(item.name, "Show")
        XCTAssertEqual(item.poster, "https://example.com/p.jpg")

        try await sync.sync()
        let pushed = await api.pushed
        XCTAssertEqual(pushed.flatMap { $0 }.map(\.id), ["tt7"])
        try await sync.sync()
        let pushedAgain = await api.pushed
        XCTAssertEqual(pushedAgain.count, 1, "Unchanged items are not pushed again")
    }

    func testForwardSeekDoesNotCountAsWatchedTime() {
        let (sync, progress) = make(MockLibraryAPI())
        progress.record(request("tt8", metaID: "tt8", type: "movie"), seconds: 10, duration: 6000, at: clock)
        clock += 5
        progress.record(request("tt8", metaID: "tt8", type: "movie"), seconds: 3000, duration: 6000, at: clock)
        let state = sync.items["tt8"]?.state
        XCTAssertEqual(state?.timeOffset, 3_000_000)
        XCTAssertEqual(state?.timeWatched, 7_000)
        XCTAssertEqual(state?.flaggedWatched, 0)
    }

    func testFinishingEpisodeFlagsWatchedAndAdvancesPointer() {
        let (sync, progress) = make(MockLibraryAPI())
        let videos = ["tt9:1:1", "tt9:1:2"]
        sync.registerVideos(metaID: "tt9", videoIDs: videos)
        progress.record(request("tt9:1:1", metaID: "tt9"), seconds: 1, duration: 100, at: clock)
        for t in [21.0, 41, 61, 81, 95] {
            clock += 20
            progress.record(request("tt9:1:1", metaID: "tt9"), seconds: t, duration: 100, at: clock)
        }
        let item = try! XCTUnwrap(sync.items["tt9"])
        XCTAssertEqual(item.state.timesWatched, 1)
        XCTAssertEqual(item.state.videoId, "tt9:1:2")
        XCTAssertEqual(item.state.timeOffset, 1)
        XCTAssertTrue(item.temp, "Watching never adds to the library")
        XCTAssertTrue(item.removed)
        XCTAssertTrue(LibrarySync.isInContinueWatching(item), "Next episode stays in Continue Watching")
        XCTAssertEqual(sync.watchedVideoIDs(metaID: "tt9", videoIDs: videos), ["tt9:1:1"])
    }

    func testMarkWatchedAndUnwatchedMovie() {
        let (sync, progress) = make(MockLibraryAPI())
        progress.markWatched(videoId: "tt10", metaID: "tt10", metaType: "movie", title: "Movie")
        XCTAssertEqual(sync.items["tt10"]?.state.timesWatched, 1)
        XCTAssertEqual(sync.items["tt10"]?.state.timeOffset, 0)
        progress.markUnwatched(videoId: "tt10")
        XCTAssertEqual(sync.items["tt10"]?.state.timesWatched, 0)
    }

    func testEpisodeWatchedBeforeEpisodeListIsKnownIsFlushedLater() {
        let (sync, progress) = make(MockLibraryAPI())
        let videos = ["tt11:1:1", "tt11:1:2"]
        progress.markWatched(videoId: "tt11:1:2", metaID: "tt11", metaType: "series", title: "Show")
        XCTAssertNil(sync.items["tt11"]?.state.watched)
        XCTAssertEqual(sync.watchedVideoIDs(metaID: "tt11", videoIDs: videos), ["tt11:1:2"])
        sync.registerVideos(metaID: "tt11", videoIDs: videos)
        let field = try! XCTUnwrap(sync.items["tt11"]?.state.watched)
        XCTAssertEqual(WatchedBitfield.decode(field, videoIDs: videos), ["tt11:1:2"])
    }

    func testUnmarkingClearsAccountWatchedBit() async throws {
        let api = MockLibraryAPI()
        let videos = ["tt15:1:1", "tt15:1:2"]
        var item = remoteItem("tt15", mtime: clock, videoId: nil, offset: 0)
        item.state.watched = WatchedBitfield.encode(watched: Set(videos), videoIDs: videos)
        await api.seed([item])
        let (sync, progress) = make(api)
        try await sync.sync()
        clock += 1

        // No local entry yet (episode list never registered): the bit is still cleared.
        progress.markUnwatched(videoId: "tt15:1:1")
        XCTAssertEqual(sync.watchedVideoIDs(metaID: "tt15", videoIDs: videos), ["tt15:1:2"])

        sync.registerVideos(metaID: "tt15", videoIDs: videos)
        XCTAssertFalse(progress.isWatched("tt15:1:1"))
        XCTAssertTrue(progress.isWatched("tt15:1:2"))
        clock += 1
        progress.markUnwatched(videoId: "tt15:1:2")
        XCTAssertTrue(sync.watchedVideoIDs(metaID: "tt15", videoIDs: videos).isEmpty)

        try await sync.sync()
        let remoteField = await api.remote["tt15"]?.state.watched
        let pushed = try XCTUnwrap(remoteField)
        XCTAssertTrue(WatchedBitfield.decode(pushed, videoIDs: videos).isEmpty)
    }

    func testRemoveFromContinueWatchingRewinds() {
        let (sync, progress) = make(MockLibraryAPI())
        progress.record(request("tt12:1:1", metaID: "tt12"), seconds: 600, duration: 3000, at: clock)
        clock += 1
        progress.removeFromContinueWatching(metaID: "tt12")
        let item = try! XCTUnwrap(sync.items["tt12"])
        XCTAssertEqual(item.state.timeOffset, 0)
        XCTAssertFalse(LibrarySync.isInContinueWatching(item))
    }

    func testClearHistoryResetsStateAndPushes() async throws {
        let api = MockLibraryAPI()
        let (sync, progress) = make(api)
        progress.record(request("tt13:1:1", metaID: "tt13"), seconds: 600, duration: 3000, at: clock)
        sync.addToLibrary(id: "tt14", type: "movie", name: "Kept", poster: nil)
        progress.record(request("tt14", metaID: "tt14", type: "movie"), seconds: 600, duration: 3000, at: clock)
        clock += 1

        for id in ["tt13", "tt14"] {
            progress.clearHistory(metaID: id)
            sync.clearHistory(metaID: id)
        }
        XCTAssertTrue(progress.entries(forMeta: "tt13").isEmpty)
        let temp = try XCTUnwrap(sync.items["tt13"])
        XCTAssertTrue(temp.removed)
        XCTAssertNil(temp.state.lastWatched)
        XCTAssertEqual(temp.state.timeWatched, 0)
        XCTAssertTrue(sync.isInLibrary("tt14"), "bookmarked titles stay in the library")
        XCTAssertNil(sync.items["tt14"]?.state.lastWatched)

        try await sync.sync()
        let pushed = await api.pushed.flatMap { $0 }
        XCTAssertTrue(pushed.contains { $0.id == "tt13" && $0.state.lastWatched == nil })
    }

    // MARK: Bookmarks

    func testAddAndRemoveBookmark() async throws {
        let api = MockLibraryAPI()
        let (sync, progress) = make(api)
        progress.record(request("tt13", metaID: "tt13", type: "movie"), seconds: 60, duration: 3000, at: clock)
        clock += 1
        sync.addToLibrary(id: "tt13", type: "movie", name: "Movie", poster: "https://example.com/m.jpg")
        XCTAssertTrue(sync.isInLibrary("tt13"))
        XCTAssertEqual(sync.libraryItems.map(\.id), ["tt13"])
        XCTAssertEqual(sync.items["tt13"]?.state.timeOffset, 60_000, "Adding keeps watch state")

        try await sync.sync()
        let added = await api.remote["tt13"]
        XCTAssertEqual(added?.removed, false)
        XCTAssertEqual(added?.temp, false)

        clock += 1
        sync.removeFromLibrary(id: "tt13")
        XCTAssertFalse(sync.isInLibrary("tt13"))
        XCTAssertTrue(sync.libraryItems.isEmpty)
        try await sync.sync()
        let removed = await api.remote["tt13"]
        XCTAssertEqual(removed?.removed, true)
        XCTAssertEqual(removed?.temp, false)
    }

    // MARK: Session

    func testSignedOutIsLocalOnlyAndPersists() async throws {
        let api = MockLibraryAPI()
        signedIn = false
        let (sync, progress) = make(api)
        sync.addToLibrary(id: "tt14", type: "movie", name: "Movie", poster: nil)
        try await sync.sync()
        let calls = await api.pushed.count
        XCTAssertEqual(calls, 0)

        let (reloaded, _) = make(api, progress: progress)
        XCTAssertTrue(reloaded.isInLibrary("tt14"))

        signedIn = true
        try await reloaded.sync()
        let remote = await api.remote["tt14"]
        XCTAssertNotNil(remote, "Signed-out items merge into the account on first sync")

        reloaded.reset()
        XCTAssertTrue(reloaded.items.isEmpty)
        let (afterReset, _) = make(api, progress: progress)
        XCTAssertTrue(afterReset.items.isEmpty)
    }

    func testUnauthorizedIsRethrown() async {
        let api = MockLibraryAPI()
        await api.setFailUnauthorized(true)
        let (sync, _) = make(api)
        do {
            try await sync.sync()
            XCTFail("Expected unauthorized")
        } catch {
            XCTAssertEqual(error as? StremioAPIError, .unauthorized)
        }
    }

    func testSeriesVideoIDParsing() {
        XCTAssertTrue(LibrarySync.isMovie(videoID: "tt1", metaID: "tt1"))
        XCTAssertFalse(LibrarySync.isMovie(videoID: "tt1:1:2", metaID: "tt1"))
        XCTAssertTrue(ProgressStore.episodeNumbers(videoId: "tt1:1:2", metaID: "tt1") == (1, 2))
        XCTAssertTrue(ProgressStore.episodeNumbers(videoId: "kitsu:42:7", metaID: "kitsu:42") == (nil, 7))
    }

    func testBitfieldOrderMatchesStremioCore() {
        var meta = MetaDetail(id: "tt1", type: "series", name: "Show")
        meta.videos = [Video(id: "tt1:2:1", season: 2, episode: 1), Video(id: "tt1:0:1", season: 0, episode: 1),
                       Video(id: "tt1:1:2", season: 1, episode: 2), Video(id: "tt1:1:1", season: 1, episode: 1),
                       Video(id: "extra")]
        XCTAssertEqual(LibrarySync.bitfieldVideoIDs(meta), ["extra", "tt1:0:1", "tt1:1:1", "tt1:1:2", "tt1:2:1"])
    }
}
