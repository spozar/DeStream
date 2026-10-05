import XCTest
@testable import DeStream

final class LibraryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = bundle.url(forResource: "Fixtures/library/\(name)", withExtension: "json")
            ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/library")
        return try Data(contentsOf: XCTUnwrap(url, "missing fixture \(name)"))
    }

    private func date(_ s: String) -> Date { try! Date(s, strategy: .iso8601) }

    private func item(_ videoId: String, season: Int? = nil, episode: Int? = nil, file: String,
                      savedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> SidecarMeta.SidecarItem {
        SidecarMeta.SidecarItem(videoId: videoId, season: season, episode: episode, title: nil, file: file,
                                sizeBytes: nil, savedAt: savedAt, progressSeconds: nil, durationSeconds: nil)
    }

    @discardableResult
    private func makeTitle(_ id: String, type: String = "series", items: [SidecarMeta.SidecarItem],
                           createFiles: Bool = true) throws -> URL {
        let folder = LibraryWriter.folder(for: id, root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if createFiles {
            for i in items { try Data("video".utf8).write(to: folder.appendingPathComponent(i.file)) }
        }
        try LibraryWriter.write(SidecarMeta(id: id, type: type, name: id.uppercased(), items: items), folder: folder)
        return folder
    }

    private func jsonObject(_ data: Data) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    // MARK: - SidecarMeta

    func testDecodesPlanSchema() throws {
        let meta = try SidecarMeta.decode(fixture("meta_series"))
        XCTAssertEqual(meta.schemaVersion, 1)
        XCTAssertEqual(meta.id, "tt0903747")
        XCTAssertEqual(meta.type, "series")
        XCTAssertEqual(meta.year, "2008")
        XCTAssertEqual(meta.genres, ["Drama"])
        XCTAssertEqual(meta.poster, "poster.jpg")
        XCTAssertEqual(meta.backdrop, "backdrop.jpg")
        let item = try XCTUnwrap(meta.items.first)
        XCTAssertEqual(item.videoId, "tt0903747:1:1")
        XCTAssertEqual(item.season, 1)
        XCTAssertEqual(item.episode, 1)
        XCTAssertEqual(item.file, "S01E01.mkv")
        XCTAssertEqual(item.sizeBytes, 1_234_567_890)
        XCTAssertEqual(item.savedAt, date("2026-10-02T12:00:00Z"))
        XCTAssertEqual(item.progressSeconds, 1834)
        XCTAssertEqual(item.durationSeconds, 3480)
    }

    func testEncodeRoundTripMatchesPlanJSON() throws {
        let data = try fixture("meta_series")
        let meta = try SidecarMeta.decode(data)
        let encoded = try meta.encoded()
        XCTAssertEqual(try jsonObject(encoded), try jsonObject(data))
        XCTAssertEqual(try SidecarMeta.decode(encoded), meta)

        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(text.contains("\"savedAt\" : \"2026-10-02T12:00:00Z\""), text)
        XCTAssertTrue(text.contains("\n"), "pretty printed")
        let keys = text.components(separatedBy: "\n").filter { $0.hasPrefix("  \"") }.map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(keys, keys.sorted(), "sorted keys")
    }

    func testDecodingToleratesUnknownAndMissingFields() throws {
        let meta = try SidecarMeta.decode(fixture("meta_movie_minimal"))
        XCTAssertEqual(meta.schemaVersion, 1)
        XCTAssertNil(meta.year)
        XCTAssertNil(meta.poster)
        XCTAssertEqual(meta.items.count, 1, "malformed item dropped, valid item kept")
        XCTAssertNil(meta.items[0].season)
        XCTAssertEqual(meta.items[0].savedAt.timeIntervalSince1970,
                       date("2026-10-01T08:30:00Z").timeIntervalSince1970 + 0.123, accuracy: 0.001)
    }

    // MARK: - LibraryWriter

    func testRelativePathEnforcement() throws {
        let folder = LibraryWriter.folder(for: "tt1", root: root)
        var meta = SidecarMeta(id: "tt1", type: "movie", name: "One", items: [item("tt1", file: "/etc/passwd")])
        XCTAssertThrowsError(try LibraryWriter.write(meta, folder: folder)) {
            XCTAssertEqual($0 as? LibraryError, .unsafePath("/etc/passwd"))
        }
        meta.items = [item("tt1", file: "../escape.mkv")]
        XCTAssertThrowsError(try LibraryWriter.write(meta, folder: folder))

        meta.items = [item("tt1", file: folder.appendingPathComponent("Movie.mkv").path)]
        meta.poster = folder.appendingPathComponent("poster.jpg").path
        try LibraryWriter.write(meta, folder: folder)
        let stored = try XCTUnwrap(LibraryWriter.read(folder: folder))
        XCTAssertEqual(stored.items.first?.file, "Movie.mkv")
        XCTAssertEqual(stored.poster, "poster.jpg")
        let raw = try String(contentsOf: LibraryWriter.metaURL(in: folder), encoding: .utf8)
        XCTAssertFalse(raw.contains(root.path), "no absolute paths on disk")
    }

    func testFolderNameSanitizesIDs() {
        XCTAssertEqual(LibraryWriter.folder(for: "kitsu:123/x", root: root).lastPathComponent, "kitsu_123_x")
    }

    func testAtomicWriteReplacesAndLeavesNoTempFiles() throws {
        let folder = LibraryWriter.folder(for: "tt2", root: root)
        var meta = SidecarMeta(id: "tt2", type: "movie", name: "First", items: [])
        try LibraryWriter.write(meta, folder: folder)
        meta.name = "Second"
        try LibraryWriter.write(meta, folder: folder)
        XCTAssertEqual(try LibraryWriter.read(folder: folder)?.name, "Second")
        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(contents, ["meta.json"])
    }

    func testReadMissingReturnsNil() throws {
        XCTAssertNil(try LibraryWriter.read(folder: root.appendingPathComponent("nope")))
    }

    func testUpsertInsertsAndReplacesByVideoId() throws {
        let folder = LibraryWriter.folder(for: "tt3", root: root)
        try LibraryWriter.write(SidecarMeta(id: "tt3", type: "series", name: "Three", year: "2001", items: []), folder: folder)
        try LibraryWriter.upsertItem(item("tt3:1:1", season: 1, episode: 1, file: "S01E01.mkv"), folder: folder)
        try LibraryWriter.upsertItem(item("tt3:1:2", season: 1, episode: 2, file: "S01E02.mkv"), folder: folder)
        try LibraryWriter.upsertItem(item("tt3:1:1", season: 1, episode: 1, file: "S01E01.v2.mkv"), folder: folder)
        let meta = try XCTUnwrap(LibraryWriter.read(folder: folder))
        XCTAssertEqual(meta.items.map(\.videoId), ["tt3:1:1", "tt3:1:2"])
        XCTAssertEqual(meta.items[0].file, "S01E01.v2.mkv")
        XCTAssertEqual(meta.year, "2001", "title metadata preserved")
    }

    func testConcurrentUpsertsAreSerialized() throws {
        let folder = LibraryWriter.folder(for: "tt4", root: root)
        try LibraryWriter.write(SidecarMeta(id: "tt4", type: "series", name: "Four", items: []), folder: folder)
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            try? LibraryWriter.upsertItem(
                SidecarMeta.SidecarItem(videoId: "tt4:1:\(i)", season: 1, episode: i, title: nil, file: "E\(i).mkv",
                                        sizeBytes: nil, savedAt: Date(), progressSeconds: nil, durationSeconds: nil),
                folder: folder)
        }
        XCTAssertEqual(try LibraryWriter.read(folder: folder)?.items.count, 40)
    }

    func testPrepareTitleMergesAndKeepsItems() async throws {
        let json = """
        {"id":"tt5","type":"series","name":"Five","releaseInfo":"2010–2012","description":"Desc","genres":["Drama","Crime"]}
        """
        let detail = try JSONDecoder().decode(MetaDetail.self, from: Data(json.utf8))
        let folder = try await LibraryWriter.prepareTitle(detail, root: root)
        XCTAssertEqual(folder, LibraryWriter.folder(for: "tt5", root: root))
        try LibraryWriter.upsertItem(item("tt5:1:1", season: 1, episode: 1, file: "S01E01.mkv"), folder: folder)

        _ = try await LibraryWriter.prepareTitle(detail, root: root)
        let meta = try XCTUnwrap(LibraryWriter.read(folder: folder))
        XCTAssertEqual(meta.name, "Five")
        XCTAssertEqual(meta.description, "Desc")
        XCTAssertEqual(meta.genres, ["Drama", "Crime"])
        XCTAssertEqual(meta.year, "2010–2012")
        XCTAssertEqual(meta.items.count, 1, "existing items kept")
        XCTAssertNil(meta.poster, "no image downloaded, no poster referenced")
    }

    func testPrepareTitleUsesExistingLocalImages() async throws {
        let folder = LibraryWriter.folder(for: "tt6", root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8]).write(to: folder.appendingPathComponent("poster.jpg"))
        let detail = try JSONDecoder().decode(MetaDetail.self, from: Data(#"{"id":"tt6","type":"movie","name":"Six","poster":"not a url"}"#.utf8))
        _ = try await LibraryWriter.prepareTitle(detail, root: root)
        let meta = try XCTUnwrap(LibraryWriter.read(folder: folder))
        XCTAssertEqual(meta.poster, "poster.jpg")
        XCTAssertNil(meta.backdrop)
    }

    // MARK: - Scanning

    func testScanFindsTitlesSortedByMostRecentAndPrunesMissingFiles() throws {
        try makeTitle("tt_old", type: "movie", items: [item("tt_old", file: "Old.mkv", savedAt: date("2026-01-01T00:00:00Z"))])
        let newFolder = try makeTitle("tt_new", items: [
            item("tt_new:1:1", season: 1, episode: 1, file: "S01E01.mkv", savedAt: date("2026-09-01T00:00:00Z")),
            item("tt_new:1:2", season: 1, episode: 2, file: "S01E02.mkv", savedAt: date("2026-09-02T00:00:00Z")),
        ])
        try FileManager.default.removeItem(at: newFolder.appendingPathComponent("S01E02.mkv"))
        try makeTitle("tt_gone", items: [item("tt_gone:1:1", file: "missing.mkv")], createFiles: false)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("no_meta"), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: root.appendingPathComponent("stray.txt"))

        guard case .titles(let titles) = LibraryScanner.scan(root: root) else { return XCTFail("expected titles") }
        XCTAssertEqual(titles.map(\.id), ["tt_new", "tt_old"])
        XCTAssertEqual(titles[0].meta.items.map(\.videoId), ["tt_new:1:1"], "missing file pruned")
        XCTAssertEqual(titles[0].meta.items[0].sizeBytes, 5, "size filled from file")
        XCTAssertEqual(titles[0].itemsSubtitle, "1 episode")
        XCTAssertEqual(titles[1].itemsSubtitle, "Movie")
        XCTAssertNil(titles[0].posterURL, "poster without file is dropped")
    }

    func testScanAvailability() throws {
        XCTAssertEqual(LibraryScanner.scan(root: root.appendingPathComponent("not-created-yet")), .titles([]))
        let file = root.appendingPathComponent("file-not-folder")
        try Data().write(to: file)
        XCTAssertEqual(LibraryScanner.scan(root: file), .unavailable)
        XCTAssertEqual(LibraryLocation.status(of: URL(fileURLWithPath: "/Volumes/DeStreamTestMissingDrive-\(UUID().uuidString)/Lib")), .unavailable)
    }

    // MARK: - LibraryStore

    @MainActor
    func testStoreReloadAndAvailability() async throws {
        try makeTitle("tt7", type: "movie", items: [item("tt7", file: "Seven.mkv")])
        let store = LibraryStore(root: root)
        await store.reload()
        XCTAssertTrue(store.isAvailable)
        XCTAssertEqual(store.titles.map(\.id), ["tt7"])
        XCTAssertTrue(store.isSaved(videoId: "tt7"))
        XCTAssertNotNil(store.title(id: "tt7"))

        let other = root.appendingPathComponent("elsewhere", isDirectory: true)
        await store.setRoot(other)
        XCTAssertEqual(store.root, other)
        XCTAssertTrue(store.titles.isEmpty)
        XCTAssertTrue(store.isAvailable)

        await store.setRoot(URL(fileURLWithPath: "/Volumes/DeStreamTestMissingDrive-\(UUID().uuidString)/Lib"))
        XCTAssertFalse(store.isAvailable)
    }

    @MainActor
    func testDeleteItemUpdatesMetaAndRemovesEmptyFolder() async throws {
        let folder = try makeTitle("tt8", items: [
            item("tt8:1:1", season: 1, episode: 1, file: "S01E01.mkv"),
            item("tt8:1:2", season: 1, episode: 2, file: "S01E02.mkv"),
        ])
        let store = LibraryStore(root: root)
        await store.reload()
        var title = try XCTUnwrap(store.title(id: "tt8"))

        try await store.delete(title.meta.items[0], in: title)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("S01E01.mkv").path))
        XCTAssertEqual(try LibraryWriter.read(folder: folder)?.items.map(\.videoId), ["tt8:1:2"])
        title = try XCTUnwrap(store.title(id: "tt8"))
        XCTAssertEqual(title.meta.items.count, 1)

        try await store.delete(title.meta.items[0], in: title)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "empty title folder removed")
        XCTAssertNil(store.title(id: "tt8"))
    }

    @MainActor
    func testDeletingLastPlayableItemRemovesFolderDespiteStaleEntries() async throws {
        let folder = try makeTitle("tt11", items: [item("tt11:1:1", season: 1, episode: 1, file: "S01E01.mkv")])
        try LibraryWriter.upsertItem(item("tt11:1:2", season: 1, episode: 2, file: "Missing.mkv"), folder: folder)
        try Data("jpg".utf8).write(to: folder.appendingPathComponent(LibraryWriter.posterFileName))
        let store = LibraryStore(root: root)
        await store.reload()
        let title = try XCTUnwrap(store.title(id: "tt11"))
        XCTAssertEqual(title.meta.items.count, 1)

        try await store.delete(title.meta.items[0], in: title)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "folder with poster and stale meta removed")
    }

    func testRemoveFolderIfUnusedKeepsFoldersWithOtherFiles() throws {
        let empty = try makeTitle("tt12", items: [])
        try Data("jpg".utf8).write(to: empty.appendingPathComponent(LibraryWriter.posterFileName))
        LibraryWriter.removeFolderIfUnused(empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))

        let withVideo = try makeTitle("tt13", type: "movie", items: [item("tt13", file: "Movie.mkv")])
        LibraryWriter.removeFolderIfUnused(withVideo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: withVideo.path))

        let withStray = try makeTitle("tt14", items: [])
        try Data("x".utf8).write(to: withStray.appendingPathComponent("notes.txt"))
        LibraryWriter.removeFolderIfUnused(withStray)
        XCTAssertTrue(FileManager.default.fileExists(atPath: withStray.path))
    }

    @MainActor
    func testDeleteTitleRemovesFolder() async throws {
        let folder = try makeTitle("tt9", type: "movie", items: [item("tt9", file: "Nine.mkv")])
        let store = LibraryStore(root: root)
        await store.reload()
        try await store.delete(title: XCTUnwrap(store.title(id: "tt9")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(store.titles.isEmpty)
    }

    @MainActor
    func testUpdateProgressIsBatchedAndPersisted() async throws {
        let folder = try makeTitle("tt10", type: "movie", items: [item("tt10", file: "Ten.mkv")])
        let store = LibraryStore(root: root)
        store.progressFlushInterval = .seconds(60)
        await store.reload()
        for s in stride(from: 1.0, through: 100, by: 1) {
            store.updateProgress(titleID: "tt10", videoId: "tt10", seconds: s, duration: 200)
        }
        XCTAssertEqual(store.title(id: "tt10")?.meta.items[0].progressSeconds, 100, "memory updated immediately")
        XCTAssertNil(try LibraryWriter.read(folder: folder)?.items[0].progressSeconds, "disk write is deferred")

        await store.flushProgress()
        let stored = try XCTUnwrap(LibraryWriter.read(folder: folder)?.items.first)
        XCTAssertEqual(stored.progressSeconds, 100)
        XCTAssertEqual(stored.durationSeconds, 200)
        XCTAssertEqual(stored.progressFraction ?? 0, 0.5, accuracy: 0.0001)
    }
}
