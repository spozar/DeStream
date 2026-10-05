import Foundation

/// Pure helpers used by DownloadManager (unit-tested in Tests/DownloadTests.swift).

enum DownloadFilename {
    static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "m2ts", "wmv", "flv", "mpg", "mpeg"]
    private static let maxLength = 200

    static func episodeCode(season: Int?, episode: Int?) -> String? {
        guard let season, let episode else { return nil }
        return String(format: "S%02dE%02d", season, episode)
    }

    /// Makes a string safe as a single path component on APFS/HFS+/FAT, or nil if nothing usable remains.
    static func sanitize(_ name: String) -> String? {
        var s = ""
        for ch in name {
            switch ch {
            case ":": s += " -"
            case "/", "\\", "*", "?", "\"", "<", ">", "|": s += " "
            default:
                if ch.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { s += " " } else { s.append(ch) }
            }
        }
        s = s.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        guard !s.isEmpty else { return nil }
        if s.count > maxLength {
            let ext = (s as NSString).pathExtension
            let base = (s as NSString).deletingPathExtension
            let keep = maxLength - (ext.isEmpty ? 0 : ext.count + 1)
            s = String(base.prefix(keep)).trimmingCharacters(in: CharacterSet(charactersIn: " .")) + (ext.isEmpty ? "" : ".\(ext)")
        }
        return s
    }

    static func fileExtension(url: URL?, mimeType: String?) -> String {
        if let ext = url?.pathExtension.lowercased(), videoExtensions.contains(ext) { return ext }
        switch mimeType?.lowercased() {
        case "video/mp4": return "mp4"
        case "video/x-m4v": return "m4v"
        case "video/quicktime": return "mov"
        case "video/webm": return "webm"
        case "video/x-msvideo": return "avi"
        case "video/mp2t": return "ts"
        default: return "mkv"
        }
    }

    /// behaviorHints.filename → response.suggestedFilename → generated `S01E01.ext` / `Title.ext`.
    /// Series files always carry their SxxEyy code so episodes never collide.
    static func resolve(hint: String?, suggested: String?, url: URL?, mimeType: String?,
                        title: String, season: Int?, episode: Int?) -> String {
        let ext = fileExtension(url: url, mimeType: mimeType)
        var name: String?
        if let hint = hint.flatMap(sanitize) {
            name = videoExtensions.contains((hint as NSString).pathExtension.lowercased()) ? hint : "\(hint).\(ext)"
        } else if let s = suggested.flatMap(sanitize), videoExtensions.contains((s as NSString).pathExtension.lowercased()) {
            name = s
        }
        let code = episodeCode(season: season, episode: episode)
        guard let name else {
            if let code { return "\(code).\(ext)" }
            return "\(sanitize(title) ?? "Video").\(ext)"
        }
        if let code, !name.uppercased().contains(code) {
            return sanitize("\(code) - \(name)") ?? name
        }
        return name
    }
}

enum DownloadValidation {
    static let minimumVideoBytes: Int64 = 5 * 1024 * 1024
    static let nonVideoMessage = "The addon didn't send a video file; the torrent probably isn't cached on TorBox yet. Try again later or pick another stream."

    enum Problem: Error, Equatable {
        case http(Int)
        case nonVideo

        var message: String {
            switch self {
            case .http(let code) where code == 401 || code == 403:
                "The server refused the download (HTTP \(code)); the link may have expired. Try again, or pick another stream."
            case .http(let code) where code == 404 || code == 410:
                "The file is no longer available (HTTP \(code)). Pick another stream."
            case .http(let code) where code >= 500:
                "The server had a problem (HTTP \(code)). Try again in a moment."
            case .http(let code): "The server returned HTTP \(code)."
            case .nonVideo: DownloadValidation.nonVideoMessage
            }
        }

        var isClientError: Bool { if case .http(let c) = self { (400..<500).contains(c) } else { false } }
    }

    /// `length` < 0 means unknown. Small files are only accepted when the server says they're video/*.
    static func check(statusCode: Int?, mimeType: String?, length: Int64) -> Problem? {
        if let statusCode, !(200..<300).contains(statusCode) { return .http(statusCode) }
        let mime = mimeType?.lowercased() ?? ""
        if mime.hasPrefix("text/") || mime.contains("json") || mime.contains("html") { return .nonVideo }
        if mime.hasPrefix("video/") { return nil }
        if length >= 0, length < minimumVideoBytes { return .nonVideo }
        return nil
    }
}

enum DownloadScheduler {
    static func isActive(_ state: DownloadItem.State) -> Bool { state == .downloading || state == .waiting }

    /// Oldest queued items that fit into the free slots.
    static func idsToStart(_ items: [DownloadItem], maxConcurrent: Int) -> [UUID] {
        let active = items.filter { isActive($0.state) }.count
        let slots = max(0, max(1, maxConcurrent) - active)
        return items.filter { $0.state == .queued }.sorted { $0.createdAt < $1.createdAt }.prefix(slots).map(\.id)
    }
}

/// Moving-average transfer rate over the last few seconds.
struct TransferRateEstimator: Sendable, Hashable {
    private struct Sample: Sendable, Hashable { var time: TimeInterval; var bytes: Int64 }
    private var samples: [Sample] = []
    var window: TimeInterval = 8

    mutating func add(bytes: Int64, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if let last = samples.last, bytes < last.bytes { samples.removeAll() }
        samples.append(Sample(time: time, bytes: bytes))
        samples.removeAll { time - $0.time > window }
    }

    var bytesPerSecond: Double? {
        guard let first = samples.first, let last = samples.last, last.time - first.time >= 1 else { return nil }
        return Double(last.bytes - first.bytes) / (last.time - first.time)
    }

    func eta(remaining: Int64) -> TimeInterval? {
        guard let rate = bytesPerSecond, rate > 0, remaining > 0 else { return nil }
        return Double(remaining) / rate
    }
}

/// Queue + resume data on disk: <dir>/downloads.json, <dir>/resume/<id>.data, <dir>/staging/.
struct DownloadStore: Sendable {
    let directory: URL

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeStream", isDirectory: true)
    }

    var itemsURL: URL { directory.appendingPathComponent("downloads.json") }
    var resumeDirectory: URL { directory.appendingPathComponent("resume", isDirectory: true) }
    var stagingDirectory: URL { directory.appendingPathComponent("staging", isDirectory: true) }

    /// Stream URLs can embed the debrid key (Comet config), so the real store keeps them in the
    /// Keychain and writes them blank to downloads.json. Test stores in temp dirs keep them inline.
    var keepsURLsInKeychain: Bool { directory.standardizedFileURL == Self.defaultDirectory.standardizedFileURL }
    private static let urlsKeychainKey = "downloadStreamURLs"

    func loadItems() -> [DownloadItem] {
        guard let data = try? Data(contentsOf: itemsURL) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        var items = (try? d.decode([DownloadItem].self, from: data)) ?? []
        if keepsURLsInKeychain, let blob = Keychain.get(Self.urlsKeychainKey),
           let urls = try? JSONDecoder().decode([String: String].self, from: blob) {
            for i in items.indices where items[i].streamURL.isEmpty {
                items[i].streamURL = urls[items[i].id.uuidString] ?? ""
            }
        }
        return items
    }

    func saveItems(_ items: [DownloadItem]) throws {
        var items = items
        if keepsURLsInKeychain {
            let urls = Dictionary(items.map { ($0.id.uuidString, $0.streamURL) }, uniquingKeysWith: { a, _ in a })
            let urlEncoder = JSONEncoder()
            urlEncoder.outputFormatting = .sortedKeys
            let blob = try urlEncoder.encode(urls)
            if Keychain.get(Self.urlsKeychainKey) != blob { try Keychain.set(blob, for: Self.urlsKeychainKey) }
            for i in items.indices { items[i].streamURL = "" }
        }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try e.encode(items)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: itemsURL, options: .atomic)
    }

    func resumeURL(for id: UUID) -> URL { resumeDirectory.appendingPathComponent("\(id.uuidString).data") }

    func resumeData(for id: UUID) -> Data? { try? Data(contentsOf: resumeURL(for: id)) }

    func saveResumeData(_ data: Data, for id: UUID) {
        try? FileManager.default.createDirectory(at: resumeDirectory, withIntermediateDirectories: true)
        try? data.write(to: resumeURL(for: id), options: .atomic)
    }

    func deleteResumeData(for id: UUID) { try? FileManager.default.removeItem(at: resumeURL(for: id)) }

    /// Removes staged files and resume data that no longer belong to a known item.
    func cleanUp(keeping ids: Set<UUID>) {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: resumeDirectory, includingPropertiesForKeys: nil)) ?? [] {
            if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), ids.contains(id) { continue }
            try? fm.removeItem(at: url)
        }
        for url in (try? fm.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil)) ?? [] {
            if let id = UUID(uuidString: String(url.lastPathComponent.prefix(36))), ids.contains(id) { continue }
            try? fm.removeItem(at: url)
        }
    }
}

/// Moves a finished file into its title folder and records it in meta.json. Runs off the main actor.
enum DownloadInstaller {
    static func install(staged: URL, folder: URL, filename: String, item: SidecarMeta.SidecarItem,
                        fallbackMeta: SidecarMeta, root: URL) throws {
        let fm = FileManager.default
        try LibraryLocation.ensureRoot(root)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let previous = try? LibraryWriter.read(folder: folder)
        try LibraryWriter.modify(folder: folder) { meta in
            if meta == nil { meta = fallbackMeta }
        }
        let dest = folder.appendingPathComponent(filename)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        do {
            try fm.moveItem(at: staged, to: dest)
        } catch {
            // A cross-volume move copies first; don't leave a truncated copy behind.
            if fm.fileExists(atPath: staged.path) { try? fm.removeItem(at: dest) }
            throw error
        }
        if let old = previous?.items.first(where: { $0.videoId == item.videoId }), old.file != filename,
           SidecarMeta.isSafeRelativePath(old.file) {
            try? fm.removeItem(at: folder.appendingPathComponent(old.file))
        }
        try LibraryWriter.upsertItem(item, folder: folder)
    }
}

enum DownloadErrorClassifier {
    /// True for "disk full" anywhere in the error or its underlying errors.
    static func isOutOfSpace(_ error: Error) -> Bool {
        let ns = error as NSError
        switch ns.domain {
        case NSURLErrorDomain where ns.code == NSURLErrorCannotWriteToFile: return true
        case NSPOSIXErrorDomain where ns.code == Int(ENOSPC) || ns.code == Int(EDQUOT): return true
        case NSCocoaErrorDomain where ns.code == NSFileWriteOutOfSpaceError: return true
        default: break
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error, isOutOfSpace(underlying) { return true }
        if let many = ns.userInfo[NSMultipleUnderlyingErrorsKey] as? [Error], many.contains(where: isOutOfSpace) { return true }
        return false
    }
}

/// Free-space requirements for the volumes a download passes through (URLSession temp → staging → library).
enum DownloadSpaceCheck {
    struct Volume: Sendable, Equatable {
        var id: String
        var name: String?
        var free: Int64
    }

    struct Shortfall: Sendable, Equatable {
        var needed: Int64
        var free: Int64
        var volumeName: String?

        var message: String {
            let f = ByteCountFormatter()
            f.countStyle = .file
            let place = volumeName.map { " on “\($0)”" } ?? ""
            return "Not enough free space\(place): needs \(f.string(fromByteCount: needed)), only \(f.string(fromByteCount: free)) available."
        }
    }

    static func headroom(for total: Int64) -> Int64 { max(500 * 1024 * 1024, total / 20) }

    /// `path` lists the volume of each stage in order. The first volume only needs the bytes still to come;
    /// every later, different volume receives a full copy of the file.
    static func shortfall(remaining: Int64, total: Int64, path: [Volume]) -> Shortfall? {
        guard total > 0 else { return nil }
        var seen: Set<String> = []
        for (i, volume) in path.enumerated() where seen.insert(volume.id).inserted {
            let incoming = i == 0 ? max(0, remaining) : total
            guard incoming > 0 else { continue }
            let needed = incoming + headroom(for: total)
            if volume.free < needed { return Shortfall(needed: needed, free: volume.free, volumeName: volume.name) }
        }
        return nil
    }
}

enum DownloadPruning {
    /// Completed items whose file is gone. Empty unless the library root is reachable, so an unplugged
    /// drive never wipes the list.
    static func missingCompleted(_ items: [DownloadItem], rootStatus: LibraryLocation.Status,
                                 fileExists: (DownloadItem) -> Bool) -> [UUID] {
        guard rootStatus == .exists else { return [] }
        return items.filter { $0.state == .completed && !fileExists($0) }.map(\.id)
    }
}
