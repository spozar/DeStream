import XCTest
@testable import DeStream

final class SubtitleTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubtitleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func pattern(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    private func item(_ videoId: String, file: String, subtitles: [SidecarMeta.SidecarSubtitle]? = nil) -> SidecarMeta.SidecarItem {
        SidecarMeta.SidecarItem(videoId: videoId, season: nil, episode: nil, title: nil, file: file, sizeBytes: nil,
                                savedAt: Date(timeIntervalSince1970: 1_700_000_000), subtitles: subtitles)
    }

    // MARK: - Hash

    /// Expected values computed independently (Python struct.unpack('<Q') over the same bytes).
    func testHashOfGeneratedFileMatchesKnownValue() throws {
        let url = dir.appendingPathComponent("video.mkv")
        try pattern(200_003).write(to: url)
        let result = try XCTUnwrap(OpenSubtitlesHash.hash(fileAt: url))
        XCTAssertEqual(result.hash, "003f7fc000436d43")
        XCTAssertEqual(result.size, 200_003)
    }

    func testHashOfFileSmallerThanOneChunk() throws {
        let url = dir.appendingPathComponent("tiny.mkv")
        try pattern(1000).write(to: url)
        XCTAssertEqual(OpenSubtitlesHash.hash(fileAt: url)?.hash, "d894500bc783425e")
    }

    func testHashFromChunksMatchesFileHash() throws {
        let data = pattern(300_000)
        let url = dir.appendingPathComponent("v.mp4")
        try data.write(to: url)
        let chunks = OpenSubtitlesHash.hash(size: 300_000, head: data.prefix(65_536), tail: data.suffix(65_536))
        XCTAssertEqual(chunks, OpenSubtitlesHash.hash(fileAt: url)?.hash)
    }

    func testHashOfMissingOrEmptyFileIsNil() throws {
        XCTAssertNil(OpenSubtitlesHash.hash(fileAt: dir.appendingPathComponent("missing.mkv")))
        let empty = dir.appendingPathComponent("empty.mkv")
        try Data().write(to: empty)
        XCTAssertNil(OpenSubtitlesHash.hash(fileAt: empty))
    }

    func testContentRangeTotal() {
        XCTAssertEqual(OpenSubtitlesHash.totalSize(contentRange: "bytes 0-65535/1234567"), 1_234_567)
        XCTAssertNil(OpenSubtitlesHash.totalSize(contentRange: "bytes 0-65535/*"))
        XCTAssertNil(OpenSubtitlesHash.totalSize(contentRange: nil))
    }

    // MARK: - Request URL

    func testSubtitleURLWithHashExtras() throws {
        let base = try XCTUnwrap(URL(string: "https://opensubtitles-v3.strem.io"))
        let fp = VideoFingerprint(hash: "8e245d9679d31e12", size: 12_909_756, filename: "The Movie (1994) [1080p].mkv")
        XCTAssertEqual(AddonSubtitles.requestURL(base: base, type: "movie", id: "tt0111161", fingerprint: fp)?.absoluteString,
                       "https://opensubtitles-v3.strem.io/subtitles/movie/tt0111161/videoHash=8e245d9679d31e12&videoSize=12909756&filename=The%20Movie%20(1994)%20%5B1080p%5D.mkv.json")
    }

    func testSubtitleURLWithoutHash() throws {
        let base = try XCTUnwrap(URL(string: "https://opensubtitles-v3.strem.io/"))
        XCTAssertEqual(AddonSubtitles.requestURL(base: base, type: "series", id: "tt0903747:1:2", fingerprint: nil)?.absoluteString,
                       "https://opensubtitles-v3.strem.io/subtitles/series/tt0903747:1:2.json")
        let nameOnly = VideoFingerprint(hash: nil, size: nil, filename: "a.mkv")
        XCTAssertEqual(AddonSubtitles.requestURL(base: base, type: "movie", id: "tt1", fingerprint: nameOnly)?.absoluteString,
                       "https://opensubtitles-v3.strem.io/subtitles/movie/tt1/filename=a.mkv.json")
    }

    // MARK: - Picking

    func testResponseDecodingAndHashMatchesFirst() throws {
        let json = """
        {"subtitles":[
          {"id":"1","url":"https://s/1","lang":"eng","m":"i","subtitleFileName":"a.srt"},
          {"id":"2","url":"https://s/2","lang":"eng","m":"h"},
          {"id":"3","url":"https://s/3","lang":"swe","m":5},
          {"id":"4","url":"https://s/4","lang":"eng","m":"i"}
        ]}
        """
        let decoded = try JSONDecoder().decode(SubtitlesResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.subtitles.count, 4)
        XCTAssertEqual(decoded.subtitles[1].m, "h")
        XCTAssertEqual(decoded.subtitles[0].subtitleFileName, "a.srt")
        let subs = decoded.subtitles.map {
            ExternalSubtitle(url: URL(string: $0.url!)!, language: $0.lang, source: nil, isHashMatch: $0.m == "h")
        }
        let picked = AddonSubtitles.pick(subs, languages: ["en", "sv"], perLanguage: 2)
        XCTAssertEqual(picked.map(\.url.absoluteString), ["https://s/2", "https://s/1", "https://s/3"])
    }

    // MARK: - Saving

    func testFileNamesAndExtensions() {
        XCTAssertEqual(SubtitleSaver.fileName(videoFile: "Show.S01E01.mkv", language: "en", index: 1, ext: "srt"), "Show.S01E01.en.srt")
        XCTAssertEqual(SubtitleSaver.fileName(videoFile: "Season 1/Ep.mp4", language: "sv", index: 2, ext: "vtt"), "Season 1/Ep.sv.2.vtt")
        XCTAssertEqual(SubtitleSaver.fileExtension(for: Data("1\n00:00:01,000 --> 00:00:02,000\nHi".utf8), fileName: nil), "srt")
        XCTAssertEqual(SubtitleSaver.fileExtension(for: Data("\u{FEFF}WEBVTT\n\n".utf8), fileName: "x.srt"), "vtt")
        XCTAssertEqual(SubtitleSaver.fileExtension(for: Data("[Script Info]\nTitle: x".utf8), fileName: nil), "ass")
        XCTAssertEqual(SubtitleSaver.fileExtension(for: Data("{1}{2}Hi".utf8), fileName: "x.sub"), "sub")
        XCTAssertNil(SubtitleSaver.fileExtension(for: Data("<html>error</html>".utf8), fileName: "x.srt"))
        XCTAssertNil(SubtitleSaver.fileExtension(for: Data(), fileName: "x.srt"))
    }

    func testStoreWritesFilesNextToVideoWithRelativePaths() async throws {
        let srt = Data("1\n00:00:01,000 --> 00:00:02,000\nHello\n".utf8)
        let subs = [
            ExternalSubtitle(url: URL(string: "https://s/1")!, language: "eng", source: "OpenSubtitles v3", isHashMatch: true),
            ExternalSubtitle(url: URL(string: "https://s/2")!, language: "eng", source: "OpenSubtitles v3"),
            ExternalSubtitle(url: URL(string: "https://s/bad")!, language: "swe", source: "OpenSubtitles v3"),
            ExternalSubtitle(url: URL(string: "https://s/3")!, language: "swe", source: "OpenSubtitles v3"),
        ]
        let saved = await SubtitleSaver.store(subs, videoFile: "Movie.mkv", folder: dir) { url in
            url.lastPathComponent == "bad" ? nil : srt
        }
        XCTAssertEqual(saved.map(\.file), ["Movie.en.srt", "Movie.en.2.srt", "Movie.sv.srt"])
        XCTAssertEqual(saved.map(\.language), ["en", "en", "sv"])
        XCTAssertEqual(saved.first?.isHashMatch, true)
        for s in saved {
            XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(s.file)), srt)
        }
    }

    // MARK: - Sidecar & library

    func testSidecarRoundTripsSubtitles() throws {
        let sub = SidecarMeta.SidecarSubtitle(file: "Movie.en.srt", language: "en", source: "OpenSubtitles v3", isHashMatch: true)
        let meta = SidecarMeta(id: "tt1", type: "movie", name: "Movie", items: [item("tt1", file: "Movie.mkv", subtitles: [sub])])
        let decoded = try SidecarMeta.decode(meta.encoded())
        XCTAssertEqual(decoded.items.first?.subtitles, [sub])
        let legacy = try SidecarMeta.decode(SidecarMeta(id: "tt1", type: "movie", name: "M", items: [item("tt1", file: "M.mkv")]).encoded())
        XCTAssertNil(legacy.items.first?.subtitles)
    }

    func testAbsoluteSubtitlePathIsStoredRelative() throws {
        let folder = dir.appendingPathComponent("tt1")
        let abs = folder.appendingPathComponent("Movie.en.srt").path
        let meta = SidecarMeta(id: "tt1", type: "movie", name: "Movie",
                               items: [item("tt1", file: "Movie.mkv", subtitles: [.init(file: abs, language: "en")])])
        try LibraryWriter.write(meta, folder: folder)
        XCTAssertEqual(try LibraryWriter.read(folder: folder)?.items.first?.subtitles?.first?.file, "Movie.en.srt")
        let outside = SidecarMeta(id: "tt1", type: "movie", name: "Movie",
                                  items: [item("tt1", file: "Movie.mkv", subtitles: [.init(file: "/etc/x.srt", language: "en")])])
        XCTAssertThrowsError(try LibraryWriter.write(outside, folder: folder))
    }

    func testSetSubtitlesAndUpsertKeepsThem() throws {
        let folder = dir.appendingPathComponent("tt1")
        try LibraryWriter.upsertItem(item("tt1", file: "Movie.mkv"), folder: folder)
        let sub = SidecarMeta.SidecarSubtitle(file: "Movie.en.srt", language: "en")
        try LibraryWriter.setSubtitles([sub], videoId: "tt1", file: "Movie.mkv", folder: folder)
        try LibraryWriter.setSubtitles([], videoId: "tt1", file: "Other.mkv", folder: folder)
        XCTAssertEqual(try LibraryWriter.read(folder: folder)?.items.first?.subtitles, [sub])
        try LibraryWriter.upsertItem(item("tt1", file: "Movie.mkv"), folder: folder)
        XCTAssertEqual(try LibraryWriter.read(folder: folder)?.items.first?.subtitles, [sub])
        try LibraryWriter.upsertItem(item("tt1", file: "Movie.mp4"), folder: folder)
        XCTAssertNil(try LibraryWriter.read(folder: folder)?.items.first?.subtitles)
    }

    func testDeleteItemRemovesItsSubtitleFiles() throws {
        let folder = dir.appendingPathComponent("tt2")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["E1.mkv", "E1.en.srt", "E2.mkv", "E2.en.srt"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        let meta = SidecarMeta(id: "tt2", type: "series", name: "Show", items: [
            item("tt2:1:1", file: "E1.mkv", subtitles: [.init(file: "E1.en.srt", language: "en")]),
            item("tt2:1:2", file: "E2.mkv", subtitles: [.init(file: "E2.en.srt", language: "en")]),
        ])
        try LibraryWriter.write(meta, folder: folder)
        let removed = try LibraryWriter.deleteItem(videoId: "tt2:1:1", file: folder.appendingPathComponent("E1.mkv"), folder: folder)
        XCTAssertFalse(removed)
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent("E1.en.srt").path))
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("E2.en.srt").path))
        XCTAssertTrue(try LibraryWriter.deleteItem(videoId: "tt2:1:2", file: folder.appendingPathComponent("E2.mkv"), folder: folder))
        XCTAssertFalse(fm.fileExists(atPath: folder.path))
    }

    func testFolderWithOnlySubtitleLeftoversIsRemovable() throws {
        let folder = dir.appendingPathComponent("tt3")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try LibraryWriter.write(SidecarMeta(id: "tt3", type: "movie", name: "M", items: []), folder: folder)
        try Data("x".utf8).write(to: folder.appendingPathComponent("M.en.srt"))
        try Data("x".utf8).write(to: folder.appendingPathComponent("M.sv.2.vtt"))
        LibraryWriter.removeFolderIfUnused(folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testScannerDropsMissingSubtitlesAndExposesLocalTracks() throws {
        let folder = dir.appendingPathComponent("tt4")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("v".utf8).write(to: folder.appendingPathComponent("M.mkv"))
        try Data("s".utf8).write(to: folder.appendingPathComponent("M.en.srt"))
        let meta = SidecarMeta(id: "tt4", type: "movie", name: "M", items: [
            item("tt4", file: "M.mkv", subtitles: [.init(file: "M.en.srt", language: "en", source: "OS"),
                                                   .init(file: "M.sv.srt", language: "sv")]),
        ])
        try LibraryWriter.write(meta, folder: folder)
        let title = try XCTUnwrap(LibraryScanner.loadTitle(folder: folder))
        let saved = try XCTUnwrap(title.meta.items.first)
        XCTAssertEqual(saved.subtitles?.map(\.file), ["M.en.srt"])
        let tracks = title.externalSubtitles(for: saved)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertTrue(tracks[0].url.isFileURL)
        XCTAssertEqual(tracks[0].url.lastPathComponent, "M.en.srt")
        XCTAssertEqual(tracks[0].language, "en")
    }
}
