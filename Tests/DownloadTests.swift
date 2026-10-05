import XCTest
@testable import DeStream

final class DownloadFilenameTests: XCTestCase {
    func testSanitizeRemovesIllegalCharacters() {
        XCTAssertEqual(DownloadFilename.sanitize("Star Wars: A New Hope.mkv"), "Star Wars - A New Hope.mkv")
        XCTAssertEqual(DownloadFilename.sanitize("a/b\\c*?\"<>|d.mp4"), "a b c d.mp4")
        XCTAssertEqual(DownloadFilename.sanitize("  ..hidden.mkv  "), "hidden.mkv")
        XCTAssertEqual(DownloadFilename.sanitize("line\nbreak.mkv"), "line break.mkv")
        XCTAssertNil(DownloadFilename.sanitize(" / ..  "))
    }

    func testSanitizeTruncatesKeepingExtension() throws {
        let long = String(repeating: "x", count: 400) + ".mkv"
        let s = try XCTUnwrap(DownloadFilename.sanitize(long))
        XCTAssertLessThanOrEqual(s.count, 200)
        XCTAssertTrue(s.hasSuffix(".mkv"))
    }

    func testHintWins() {
        let name = DownloadFilename.resolve(hint: "The.Shawshank.Redemption.1994.1080p.mkv", suggested: "other.mp4",
                                            url: nil, mimeType: nil, title: "The Shawshank Redemption", season: nil, episode: nil)
        XCTAssertEqual(name, "The.Shawshank.Redemption.1994.1080p.mkv")
    }

    func testHintWithoutVideoExtensionGetsOne() {
        let name = DownloadFilename.resolve(hint: "Movie.2020.1080p.x264", suggested: nil,
                                            url: URL(string: "https://x.test/play/abc.mp4"), mimeType: nil,
                                            title: "Movie", season: nil, episode: nil)
        XCTAssertEqual(name, "Movie.2020.1080p.x264.mp4")
    }

    func testSuggestedUsedOnlyWhenVideo() {
        XCTAssertEqual(DownloadFilename.resolve(hint: nil, suggested: "file.mp4", url: nil, mimeType: nil,
                                                title: "T", season: nil, episode: nil), "file.mp4")
        XCTAssertEqual(DownloadFilename.resolve(hint: nil, suggested: "Unknown", url: nil, mimeType: "video/mp4",
                                                title: "Some: Title", season: nil, episode: nil), "Some - Title.mp4")
    }

    func testGeneratedEpisodeName() {
        XCTAssertEqual(DownloadFilename.resolve(hint: nil, suggested: nil, url: URL(string: "https://x.test/playback/abc"),
                                                mimeType: nil, title: "Breaking Bad", season: 1, episode: 1), "S01E01.mkv")
    }

    func testEpisodeCodePrefixedWhenMissing() {
        XCTAssertEqual(DownloadFilename.resolve(hint: "Pilot.720p.mkv", suggested: nil, url: nil, mimeType: nil,
                                                title: "Breaking Bad", season: 1, episode: 2), "S01E02 - Pilot.720p.mkv")
        XCTAssertEqual(DownloadFilename.resolve(hint: "Breaking.Bad.s01e02.mkv", suggested: nil, url: nil, mimeType: nil,
                                                title: "Breaking Bad", season: 1, episode: 2), "Breaking.Bad.s01e02.mkv")
    }
}

final class DownloadValidationTests: XCTestCase {
    func testRejectsHTMLAndJSON() {
        XCTAssertEqual(DownloadValidation.check(statusCode: 200, mimeType: "text/html", length: 1_000_000_000), .nonVideo)
        XCTAssertEqual(DownloadValidation.check(statusCode: 200, mimeType: "application/json", length: -1), .nonVideo)
    }

    func testRejectsSmallUntypedResponses() {
        XCTAssertEqual(DownloadValidation.check(statusCode: 200, mimeType: "application/octet-stream", length: 300_000), .nonVideo)
        XCTAssertNil(DownloadValidation.check(statusCode: 200, mimeType: "application/octet-stream", length: 900_000_000))
        XCTAssertNil(DownloadValidation.check(statusCode: 200, mimeType: nil, length: -1))
    }

    func testSmallVideoAllowed() {
        XCTAssertNil(DownloadValidation.check(statusCode: 200, mimeType: "video/mp4", length: 1_000_000))
        XCTAssertNil(DownloadValidation.check(statusCode: 206, mimeType: "video/x-matroska", length: 10))
    }

    func testHTTPErrors() {
        XCTAssertEqual(DownloadValidation.check(statusCode: 404, mimeType: "video/mp4", length: 10_000_000), .http(404))
        XCTAssertTrue(DownloadValidation.Problem.http(403).isClientError)
        XCTAssertFalse(DownloadValidation.Problem.http(503).isClientError)
    }
}

final class DownloadSchedulerTests: XCTestCase {
    private func item(_ state: DownloadItem.State, _ offset: TimeInterval) -> DownloadItem {
        DownloadItem(id: UUID(), metaID: "tt1", metaType: "movie", titleName: "T", videoId: UUID().uuidString,
                     streamURL: "https://x.test", addonName: "A", state: state, bytesWritten: 0, bytesExpected: 0,
                     createdAt: Date(timeIntervalSince1970: offset))
    }

    func testStartsOldestQueuedUpToLimit() {
        let a = item(.queued, 3), b = item(.queued, 1), c = item(.queued, 2)
        XCTAssertEqual(DownloadScheduler.idsToStart([a, b, c], maxConcurrent: 2), [b.id, c.id])
    }

    func testActiveAndWaitingCountTowardsLimit() {
        let items = [item(.downloading, 0), item(.waiting, 1), item(.queued, 2)]
        XCTAssertEqual(DownloadScheduler.idsToStart(items, maxConcurrent: 2), [])
        XCTAssertEqual(DownloadScheduler.idsToStart(items, maxConcurrent: 3), [items[2].id])
    }

    func testPausedFailedCompletedIgnored() {
        let items = [item(.paused, 0), item(.failed, 1), item(.completed, 2), item(.queued, 3)]
        XCTAssertEqual(DownloadScheduler.idsToStart(items, maxConcurrent: 1), [items[3].id])
    }

    func testZeroLimitStillAllowsOne() {
        let q = item(.queued, 0)
        XCTAssertEqual(DownloadScheduler.idsToStart([q], maxConcurrent: 0), [q.id])
    }
}

final class DownloadStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadStoreTests-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testRoundTrip() throws {
        let store = DownloadStore(directory: dir)
        XCTAssertEqual(store.loadItems(), [])
        let items = [
            DownloadItem(id: UUID(), metaID: "tt0903747", metaType: "series", titleName: "Breaking Bad", videoId: "tt0903747:1:1",
                         season: 1, episode: 1, episodeTitle: "Pilot", streamURL: "https://x.test/a", addonName: "Comet",
                         filename: nil, state: .downloading, bytesWritten: 10, bytesExpected: 100, errorMessage: nil,
                         createdAt: Date(timeIntervalSince1970: 1_700_000_000), filenameHint: "x.mkv"),
            DownloadItem(id: UUID(), metaID: "tt0111161", metaType: "movie", titleName: "Shawshank", videoId: "tt0111161",
                         streamURL: "https://x.test/b", addonName: "Comet", filename: "S.mkv", state: .failed,
                         bytesWritten: 0, bytesExpected: 0, errorMessage: "nope", createdAt: Date(timeIntervalSince1970: 1_700_000_100)),
        ]
        try store.saveItems(items)
        XCTAssertEqual(store.loadItems(), items)
    }

    func testDecodesItemsWithoutNewOptionalFields() throws {
        let json = """
        [{"id":"7C1F5E5A-2D7B-4E4B-8D5A-1A2B3C4D5E6F","metaID":"tt1","metaType":"movie","titleName":"T","videoId":"tt1",
          "streamURL":"https://x.test","addonName":"A","state":"queued","bytesWritten":0,"bytesExpected":0,
          "createdAt":"2026-10-02T12:00:00Z"}]
        """
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: DownloadStore(directory: dir).itemsURL)
        XCTAssertEqual(DownloadStore(directory: dir).loadItems().first?.state, .queued)
    }

    func testResumeDataAndCleanUp() {
        let store = DownloadStore(directory: dir)
        let keep = UUID(), drop = UUID()
        store.saveResumeData(Data([1, 2, 3]), for: keep)
        store.saveResumeData(Data([4]), for: drop)
        XCTAssertEqual(store.resumeData(for: keep), Data([1, 2, 3]))
        store.cleanUp(keeping: [keep])
        XCTAssertNotNil(store.resumeData(for: keep))
        XCTAssertNil(store.resumeData(for: drop))
        store.deleteResumeData(for: keep)
        XCTAssertNil(store.resumeData(for: keep))
    }
}

final class DownloadRateTests: XCTestCase {
    func testMovingAverage() {
        var r = TransferRateEstimator()
        r.add(bytes: 0, at: 0)
        XCTAssertNil(r.bytesPerSecond)
        r.add(bytes: 1_000, at: 1)
        r.add(bytes: 3_000, at: 2)
        XCTAssertEqual(r.bytesPerSecond ?? 0, 1_500, accuracy: 0.1)
        XCTAssertEqual(r.eta(remaining: 3_000) ?? 0, 2, accuracy: 0.01)
        r.add(bytes: 13_000, at: 20)
        XCTAssertNil(r.bytesPerSecond, "old samples fall out of the window")
    }
}

/// End-to-end through URLSession with file:// sources (no network), plus an opt-in live HTTP test.
@MainActor
final class DownloadManagerTests: XCTestCase {
    private var base: URL!
    private var manager: DownloadManager?

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        manager?.invalidate()
        manager = nil
        try? FileManager.default.removeItem(at: base)
    }

    private var root: URL { base.appendingPathComponent("Library") }

    private func makeManager(maxConcurrent: Int = 2) -> DownloadManager {
        let defaults = UserDefaults(suiteName: "DownloadManagerTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.maxConcurrentDownloads = maxConcurrent
        let root = root
        let m = DownloadManager(settings: settings, libraryRoot: { root }, onItemCompleted: {},
                                storageDirectory: base.appendingPathComponent("State"), sessionFactory: .foreground,
                                allowsFileURLs: true)
        manager = m
        return m
    }

    private func meta(_ id: String = "tt0000001", type: String = "movie") -> MetaDetail {
        MetaDetail(id: id, type: type, name: "Test Title")
    }

    private func stream(_ url: URL, filename: String? = nil) -> AddonStream {
        var s = DeStream.Stream()
        s.url = url.absoluteString
        if let filename { s.behaviorHints = StreamBehaviorHints(filename: filename) }
        return AddonStream(id: url.absoluteString, addonName: "TestAddon", addonID: "test", stream: s)
    }

    private func waitUntilSettled(_ m: DownloadManager, timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !m.items.isEmpty, m.items.allSatisfy({ $0.state == .completed || $0.state == .failed || $0.state == .paused }) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Downloads did not finish: \(m.items.map(\.state))")
    }

    private func writeFixture(_ name: String, bytes: Int) throws -> URL {
        let url = base.appendingPathComponent("src").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    func testFileDownloadLandsInLibraryWithSidecar() async throws {
        let src = try writeFixture("clip.mp4", bytes: 6 * 1024 * 1024)
        let m = makeManager()
        m.restore()
        m.enqueue(meta: meta(), video: nil, stream: stream(src))
        try await waitUntilSettled(m)
        let item = try XCTUnwrap(m.items.first)
        XCTAssertEqual(item.state, .completed, item.errorMessage ?? "")
        let file = try XCTUnwrap(m.fileURL(for: item))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let sidecar = try XCTUnwrap(LibraryWriter.read(folder: LibraryWriter.folder(for: "tt0000001", root: root)))
        XCTAssertEqual(sidecar.items.first?.file, file.lastPathComponent)
        XCTAssertEqual(sidecar.items.first?.sizeBytes, 6 * 1024 * 1024)

        let reloaded = DownloadStore(directory: base.appendingPathComponent("State")).loadItems()
        XCTAssertEqual(reloaded.first?.state, .completed)
    }

    func testEpisodeGetsCodeAndFilenameHint() async throws {
        let src = try writeFixture("whatever.mp4", bytes: 6 * 1024 * 1024)
        let m = makeManager()
        m.restore()
        let video = Video(id: "tt0903747:1:1", title: "Pilot", season: 1, episode: 1)
        m.enqueue(meta: meta("tt0903747", type: "series"), video: video, stream: stream(src, filename: "Pilot.1080p.mp4"))
        try await waitUntilSettled(m)
        XCTAssertEqual(m.items.first?.state, .completed, m.items.first?.errorMessage ?? "")
        XCTAssertEqual(m.items.first?.filename, "S01E01 - Pilot.1080p.mp4")
    }

    func testNonVideoResponseFails() async throws {
        let src = base.appendingPathComponent("src/error.json")
        try FileManager.default.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"error":"not cached"}"#.utf8).write(to: src)
        let m = makeManager()
        m.restore()
        m.enqueue(meta: meta(), video: nil, stream: stream(src))
        try await waitUntilSettled(m)
        XCTAssertEqual(m.items.first?.state, .failed)
        XCTAssertEqual(m.items.first?.errorMessage, DownloadValidation.nonVideoMessage)
    }

    func testDuplicateEnqueueIgnoredAndQueueRespectsLimit() async throws {
        let m = makeManager(maxConcurrent: 1)
        let urls = try (0..<3).map { try writeFixture("v\($0).mp4", bytes: 6 * 1024 * 1024) }
        let video = { (n: Int) in Video(id: "tt0903747:1:\(n)", season: 1, episode: n) }
        m.enqueue(meta: meta("tt0903747", type: "series"), video: video(1), stream: stream(urls[0]))
        m.enqueue(meta: meta("tt0903747", type: "series"), video: video(1), stream: stream(urls[1]))
        m.enqueue(meta: meta("tt0903747", type: "series"), video: video(2), stream: stream(urls[2]))
        XCTAssertEqual(m.items.count, 2)
        XCTAssertTrue(m.items.allSatisfy { $0.state == .queued }, "nothing starts before restore()")
        m.restore()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertLessThanOrEqual(m.items.filter { DownloadScheduler.isActive($0.state) }.count, 1)
        try await waitUntilSettled(m)
        XCTAssertEqual(m.items.map(\.state), [.completed, .completed])
    }

    func testRestoreRestartsInterruptedItem() async throws {
        let src = try writeFixture("clip.mp4", bytes: 6 * 1024 * 1024)
        let state = base.appendingPathComponent("State")
        let interrupted = DownloadItem(id: UUID(), metaID: "tt0000001", metaType: "movie", titleName: "Test Title",
                                       videoId: "tt0000001", streamURL: src.absoluteString, addonName: "A", state: .downloading,
                                       bytesWritten: 123, bytesExpected: 6 * 1024 * 1024, createdAt: Date())
        try DownloadStore(directory: state).saveItems([interrupted])
        let m = makeManager()
        XCTAssertEqual(m.items.first?.state, .downloading)
        m.restore()
        try await waitUntilSettled(m)
        XCTAssertEqual(m.items.first?.state, .completed, m.items.first?.errorMessage ?? "")
    }

    func testPruneDropsCompletedEntryWhoseFileWasDeleted() async throws {
        let src = try writeFixture("clip.mp4", bytes: 6 * 1024 * 1024)
        let m = makeManager()
        m.restore()
        m.enqueue(meta: meta(), video: nil, stream: stream(src))
        try await waitUntilSettled(m)
        let item = try XCTUnwrap(m.items.first)
        let missing = await m.pruneMissingFiles()
        XCTAssertEqual(missing, [])
        XCTAssertEqual(m.items.count, 1, "file still there")

        try FileManager.default.removeItem(at: try XCTUnwrap(m.fileURL(for: item)))
        let stillMissing = await m.pruneMissingFiles()
        XCTAssertEqual(stillMissing, [])
        XCTAssertTrue(m.items.isEmpty)
        XCTAssertTrue(DownloadStore(directory: base.appendingPathComponent("State")).loadItems().isEmpty)
    }

    func testPruneKeepsEntriesWhenLibraryRootIsGone() async throws {
        let src = try writeFixture("clip.mp4", bytes: 6 * 1024 * 1024)
        let m = makeManager()
        m.restore()
        m.enqueue(meta: meta(), video: nil, stream: stream(src))
        try await waitUntilSettled(m)
        let item = try XCTUnwrap(m.items.first)
        try FileManager.default.removeItem(at: root)
        let missing = await m.pruneMissingFiles()
        XCTAssertEqual(missing, [item.id])
        XCTAssertEqual(m.items.map(\.id), [item.id])
    }

    func testCancelDownloadsForTitleAndForgetCompleted() async throws {
        let m = makeManager()
        let urls = try (0..<2).map { try writeFixture("e\($0).mp4", bytes: 6 * 1024 * 1024) }
        let video = { (n: Int) in Video(id: "tt0903747:1:\(n)", season: 1, episode: n) }
        m.enqueue(meta: meta("tt0903747", type: "series"), video: video(1), stream: stream(urls[0]))
        m.enqueue(meta: meta("tt0903747", type: "series"), video: video(2), stream: stream(urls[1]))
        m.enqueue(meta: meta("tt0000002"), video: nil, stream: stream(urls[0]))
        XCTAssertEqual(m.inProgressCount(forTitle: "tt0903747"), 2)
        await m.cancelDownloads(forTitle: "tt0903747")
        XCTAssertEqual(m.inProgressCount(forTitle: "tt0903747"), 0)
        XCTAssertEqual(m.items.map(\.metaID), ["tt0000002"])

        m.restore()
        try await waitUntilSettled(m)
        XCTAssertEqual(m.items.first?.state, .completed)
        m.forgetCompleted(metaID: "tt0000002", videoId: "other")
        XCTAssertEqual(m.items.count, 1)
        m.forgetCompleted(metaID: "tt0000002", videoId: "tt0000002")
        XCTAssertTrue(m.items.isEmpty)
    }

    /// Live HTTP smoke test. Run with: TEST_RUNNER_DESTREAM_NETWORK_TESTS=1 scripts/build.sh downloads test
    func testLiveHTTPDownload() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DESTREAM_NETWORK_TESTS"] == "1", "network tests disabled")
        let url = URL(string: "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4")!
        let m = makeManager()
        m.restore()
        var detail = meta("tt1254207")
        detail.name = "Big Buck Bunny"
        detail.poster = "https://images.metahub.space/poster/medium/tt1254207/img"
        m.enqueue(meta: detail, video: nil, stream: stream(url))
        try await waitUntilSettled(m, timeout: 120)
        let item = try XCTUnwrap(m.items.first)
        XCTAssertEqual(item.state, .completed, item.errorMessage ?? "")
        let folder = LibraryWriter.folder(for: "tt1254207", root: root)
        let sidecar = try XCTUnwrap(LibraryWriter.read(folder: folder))
        XCTAssertEqual(sidecar.name, "Big Buck Bunny")
        XCTAssertEqual(sidecar.items.first?.file, "Big_Buck_Bunny_360_10s_1MB.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Big_Buck_Bunny_360_10s_1MB.mp4").path))
        print("Live download landed in \(folder.path): \((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])")
    }

    func testLivePauseAndResumeWithResumeData() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DESTREAM_NETWORK_TESTS"] == "1", "network tests disabled")
        let url = URL(string: "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/1080/Big_Buck_Bunny_1080_10s_30MB.mp4")!
        let m = makeManager()
        m.restore()
        m.enqueue(meta: meta("tt1254207"), video: nil, stream: stream(url))
        let id = try XCTUnwrap(m.items.first?.id)
        let deadline = Date().addingTimeInterval(60)
        while (m.items.first?.bytesWritten ?? 0) < 1_000_000, m.items.first?.state != .completed, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try XCTSkipIf(m.items.first?.state == .completed, "finished before it could be paused")
        m.pause(id)
        XCTAssertEqual(m.items.first?.state, .paused)
        while m.store.resumeData(for: id) == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotNil(m.store.resumeData(for: id), "pause must keep resume data on disk")
        let pausedAt = m.items.first?.bytesWritten ?? 0
        m.resume(id)
        try await waitUntilSettled(m, timeout: 120)
        XCTAssertEqual(m.items.first?.state, .completed, m.items.first?.errorMessage ?? "")
        XCTAssertGreaterThan(m.items.first?.bytesWritten ?? 0, pausedAt)
        XCTAssertNil(m.store.resumeData(for: id))
    }
}

final class DownloadErrorClassifierTests: XCTestCase {
    func testOutOfSpaceErrors() {
        XCTAssertTrue(DownloadErrorClassifier.isOutOfSpace(URLError(.cannotWriteToFile)))
        XCTAssertTrue(DownloadErrorClassifier.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
        XCTAssertTrue(DownloadErrorClassifier.isOutOfSpace(CocoaError(.fileWriteOutOfSpace)))
        XCTAssertTrue(DownloadErrorClassifier.isOutOfSpace(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        XCTAssertTrue(DownloadErrorClassifier.isOutOfSpace(wrapped))
    }

    func testOtherErrorsAreNotOutOfSpace() {
        XCTAssertFalse(DownloadErrorClassifier.isOutOfSpace(URLError(.timedOut)))
        XCTAssertFalse(DownloadErrorClassifier.isOutOfSpace(CocoaError(.fileWriteNoPermission)))
        XCTAssertFalse(DownloadErrorClassifier.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
    }

    func testErrorInfoFlags() {
        let info = DownloadErrorInfo(URLError(.cannotWriteToFile))
        XCTAssertTrue(info.isOutOfSpace)
        XCTAssertFalse(info.isConnectivity)
        XCTAssertFalse(DownloadErrorInfo(URLError(.networkConnectionLost)).isOutOfSpace)
    }
}

final class DownloadSpaceCheckTests: XCTestCase {
    private let gb: Int64 = 1024 * 1024 * 1024
    private func vol(_ id: String, _ free: Int64) -> DownloadSpaceCheck.Volume { .init(id: id, name: id, free: free) }

    func testHeadroomIsAtLeast500MBOr5Percent() {
        XCTAssertEqual(DownloadSpaceCheck.headroom(for: gb), 500 * 1024 * 1024)
        XCTAssertEqual(DownloadSpaceCheck.headroom(for: 40 * gb), 2 * gb)
    }

    func testSingleVolumeNeedsOnlyRemainingPlusHeadroom() {
        let path = [vol("disk", 3 * gb), vol("disk", 3 * gb), vol("disk", 3 * gb)]
        XCTAssertNil(DownloadSpaceCheck.shortfall(remaining: 2 * gb, total: 8 * gb, path: path))
        let short = DownloadSpaceCheck.shortfall(remaining: 3 * gb, total: 8 * gb, path: path)
        XCTAssertEqual(short?.needed, 3 * gb + 500 * 1024 * 1024)
        XCTAssertEqual(short?.free, 3 * gb)
    }

    func testSeparateLibraryVolumeNeedsWholeFile() {
        let path = [vol("internal", 100 * gb), vol("internal", 100 * gb), vol("external", 5 * gb)]
        let short = DownloadSpaceCheck.shortfall(remaining: 1 * gb, total: 8 * gb, path: path)
        XCTAssertEqual(short?.volumeName, "external")
        XCTAssertEqual(short?.needed, 8 * gb + 500 * 1024 * 1024)
        XCTAssertNil(DownloadSpaceCheck.shortfall(remaining: 1 * gb, total: 4 * gb, path: path))
    }

    func testStagingVolumeChecked() {
        let path = [vol("internal", 1 * gb), vol("internal", 1 * gb), vol("external", 100 * gb)]
        XCTAssertEqual(DownloadSpaceCheck.shortfall(remaining: 4 * gb, total: 4 * gb, path: path)?.volumeName, "internal")
    }

    func testAlreadyStagedOnSameVolumeNeedsNothing() {
        XCTAssertNil(DownloadSpaceCheck.shortfall(remaining: 0, total: 8 * gb, path: [vol("disk", 1), vol("disk", 1)]))
        XCTAssertNotNil(DownloadSpaceCheck.shortfall(remaining: 0, total: 8 * gb, path: [vol("disk", 1), vol("ext", 1)]))
    }

    func testUnknownSizeSkipsCheck() {
        XCTAssertNil(DownloadSpaceCheck.shortfall(remaining: -1, total: -1, path: [vol("disk", 0)]))
    }
}

final class DownloadPruningTests: XCTestCase {
    private func item(_ state: DownloadItem.State) -> DownloadItem {
        DownloadItem(id: UUID(), metaID: "tt1", metaType: "movie", titleName: "T", videoId: UUID().uuidString,
                     streamURL: "", addonName: "A", filename: "f.mkv", state: state, bytesWritten: 0, bytesExpected: 0,
                     createdAt: Date())
    }

    func testPrunesOnlyCompletedWithMissingFile() {
        let present = item(.completed), gone = item(.completed), active = item(.downloading), failed = item(.failed)
        let ids = DownloadPruning.missingCompleted([present, gone, active, failed], rootStatus: .exists) { $0.id == present.id }
        XCTAssertEqual(ids, [gone.id])
    }

    func testNeverPrunesWhenLibraryRootUnreachable() {
        let gone = item(.completed)
        XCTAssertEqual(DownloadPruning.missingCompleted([gone], rootStatus: .unavailable) { _ in false }, [])
        XCTAssertEqual(DownloadPruning.missingCompleted([gone], rootStatus: .empty) { _ in false }, [])
    }

    func testUnmountedVolumeRootIsUnavailable() {
        let root = URL(fileURLWithPath: "/Volumes/DeStreamTestNoSuchDrive-\(UUID().uuidString)/DeStream")
        XCTAssertEqual(LibraryLocation.status(of: root), .unavailable)
    }
}
