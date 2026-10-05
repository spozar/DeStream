import Foundation

enum LibraryError: LocalizedError, Equatable {
    case unsafePath(String)
    case libraryUnavailable

    var errorDescription: String? {
        switch self {
        case .unsafePath(let p): "Library paths must be relative to the title folder: \(p)"
        case .libraryUnavailable: "The library folder is not available."
        }
    }
}

/// Atomic read/modify/write of meta.json. Shared by DownloadManager and LibraryStore. OWNER: Agent 5 (Library).
enum LibraryWriter {
    static let posterFileName = "poster.jpg"
    static let backdropFileName = "backdrop.jpg"
    static let subtitleExtensions: Set<String> = ["srt", "vtt", "ass", "ssa", "sub"]

    /// Serializes every read-modify-write of any meta.json (downloads can finish simultaneously).
    private static let lock = NSRecursiveLock()

    static func folder(for metaID: String, root: URL) -> URL {
        root.appendingPathComponent(metaID.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_"), isDirectory: true)
    }

    static func metaURL(in folder: URL) -> URL { folder.appendingPathComponent(SidecarMeta.fileName) }

    static func read(folder: URL) throws -> SidecarMeta? {
        let url = metaURL(in: folder)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try SidecarMeta.decode(Data(contentsOf: url))
    }

    /// Write via temp file in the same folder + rename, so a crash never leaves a partial meta.json.
    static func write(_ meta: SidecarMeta, folder: URL) throws {
        let meta = try normalized(meta, folder: folder)
        let data = try meta.encoded()
        try lock.withLock {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try atomicWrite(data, to: metaURL(in: folder))
        }
    }

    /// Locked read-modify-write. `body` receives nil when no meta.json exists yet; leave it nil to skip writing.
    @discardableResult
    static func modify(folder: URL, _ body: (inout SidecarMeta?) throws -> Void) throws -> SidecarMeta? {
        try lock.withLock {
            var meta = try read(folder: folder)
            try body(&meta)
            if let meta { try write(meta, folder: folder) }
            return meta
        }
    }

    /// Creates/updates the title's meta.json from online metadata and downloads poster/backdrop if missing.
    /// Image failures never fail the call.
    static func prepareTitle(_ meta: MetaDetail, root: URL) async throws -> URL {
        try LibraryLocation.ensureRoot(root)
        let folder = folder(for: meta.id, root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let posterURL = folder.appendingPathComponent(posterFileName)
        let backdropURL = folder.appendingPathComponent(backdropFileName)
        async let posterOK = fetchImageIfMissing(meta.poster, to: posterURL)
        async let backdropOK = fetchImageIfMissing(meta.background, to: backdropURL)
        let (hasPoster, hasBackdrop) = await (posterOK, backdropOK)

        try modify(folder: folder) { existing in
            var updated = existing ?? SidecarMeta(id: meta.id, type: meta.type, name: meta.name, items: [])
            updated.schemaVersion = SidecarMeta.currentSchemaVersion
            updated.id = meta.id
            updated.type = meta.type
            updated.name = meta.name
            updated.year = meta.displayYear ?? updated.year
            updated.description = meta.description ?? updated.description
            if !meta.allGenres.isEmpty { updated.genres = meta.allGenres }
            if hasPoster { updated.poster = posterFileName }
            if hasBackdrop { updated.backdrop = backdropFileName }
            existing = updated
        }
        return folder
    }

    /// Adds or replaces an item in meta.json (by videoId).
    static func upsertItem(_ item: SidecarMeta.SidecarItem, folder: URL) throws {
        try modify(folder: folder) { meta in
            var m = meta ?? SidecarMeta(id: folder.lastPathComponent, type: item.season == nil ? "movie" : "series",
                                        name: folder.lastPathComponent, items: [])
            if let i = m.items.firstIndex(where: { $0.videoId == item.videoId }) {
                var item = item
                if item.subtitles == nil, m.items[i].file == item.file { item.subtitles = m.items[i].subtitles }
                m.items[i] = item
            } else {
                m.items.append(item)
            }
            meta = m
        }
    }

    /// Records the subtitle files saved for an item, unless its video was replaced by another file meanwhile.
    static func setSubtitles(_ subtitles: [SidecarMeta.SidecarSubtitle], videoId: String, file: String, folder: URL) throws {
        try modify(folder: folder) { meta in
            guard let i = meta?.items.firstIndex(where: { $0.videoId == videoId && $0.file == file }) else { return }
            meta!.items[i].subtitles = subtitles
        }
    }

    /// Removes an item from meta.json. Returns the remaining meta (nil if there was none).
    @discardableResult
    static func removeItem(videoId: String, folder: URL) throws -> SidecarMeta? {
        try modify(folder: folder) { meta in meta?.items.removeAll { $0.videoId == videoId } }
    }

    /// Permanently deletes a file or folder (never via the Trash). Missing files are ignored.
    static func remove(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Permanently deletes an item's file and drops it from meta.json. When no playable item remains,
    /// the whole title folder (sidecar, artwork, leftovers) goes too. Returns true if the folder was removed.
    @discardableResult
    static func deleteItem(videoId: String, file: URL, folder: URL) throws -> Bool {
        try lock.withLock {
            try remove(file)
            let item = (try? read(folder: folder))?.items.first { $0.videoId == videoId }
            for sub in item?.subtitles ?? [] where SidecarMeta.isSafeRelativePath(sub.file) {
                try? remove(folder.appendingPathComponent(sub.file))
            }
            let remaining = try removeItem(videoId: videoId, folder: folder)
            let hasPlayable = remaining?.items.contains { item in
                SidecarMeta.isSafeRelativePath(item.file)
                    && FileManager.default.fileExists(atPath: folder.appendingPathComponent(item.file).path)
            } ?? false
            guard !hasPlayable else { return false }
            try remove(folder)
            return true
        }
    }

    /// Deletes a title folder that holds only sidecar files (meta.json without playable items, artwork,
    /// subtitles, temp files), e.g. after a cancelled download. Folders with any other file are left alone.
    static func removeFolderIfUnused(_ folder: URL) {
        lock.withLock {
            let fm = FileManager.default
            guard let contents = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
            if let meta = try? read(folder: folder), meta.items.contains(where: { item in
                SidecarMeta.isSafeRelativePath(item.file) && fm.fileExists(atPath: folder.appendingPathComponent(item.file).path)
            }) { return }
            let sidecars: Set<String> = [SidecarMeta.fileName, posterFileName, backdropFileName, ".DS_Store"]
            let onlySidecars = contents.allSatisfy { name in
                sidecars.contains(name) || (name.hasPrefix(".") && name.hasSuffix(".tmp"))
                    || subtitleExtensions.contains((name as NSString).pathExtension.lowercased())
            }
            if onlySidecars { try? fm.removeItem(at: folder) }
        }
    }

    // MARK: - Helpers

    /// Converts absolute paths that point inside `folder` into relative ones; rejects anything else.
    static func normalized(_ meta: SidecarMeta, folder: URL) throws -> SidecarMeta {
        var m = meta
        m.poster = try m.poster.map { try relativePath($0, folder: folder) }
        m.backdrop = try m.backdrop.map { try relativePath($0, folder: folder) }
        for i in m.items.indices {
            m.items[i].file = try relativePath(m.items[i].file, folder: folder)
            if let subs = m.items[i].subtitles {
                m.items[i].subtitles = try subs.map { sub in
                    var sub = sub
                    sub.file = try relativePath(sub.file, folder: folder)
                    return sub
                }
            }
        }
        return m
    }

    static func relativePath(_ path: String, folder: URL) throws -> String {
        if SidecarMeta.isSafeRelativePath(path) { return path }
        guard path.hasPrefix("/") else { throw LibraryError.unsafePath(path) }
        let file = URL(fileURLWithPath: path)
        let pairs = [
            (folder.standardizedFileURL.path, file.standardizedFileURL.path),
            (folder.resolvingSymlinksInPath().path,
             file.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(file.lastPathComponent).path),
        ]
        for (base, candidate) in pairs {
            let prefix = base.hasSuffix("/") ? base : base + "/"
            guard candidate.hasPrefix(prefix) else { continue }
            let rel = String(candidate.dropFirst(prefix.count))
            if SidecarMeta.isSafeRelativePath(rel) { return rel }
        }
        throw LibraryError.unsafePath(path)
    }

    static func atomicWrite(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        if rename(tmp.path, url.path) != 0 {
            let err = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: tmp)
            throw err
        }
    }

    private static func fetchImageIfMissing(_ remote: String?, to dest: URL) async -> Bool {
        if FileManager.default.fileExists(atPath: dest.path) { return true }
        guard let remote, let url = URL(string: remote), ["http", "https"].contains(url.scheme?.lowercased()) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else { return false }
            try atomicWrite(data, to: dest)
            return true
        } catch {
            return false
        }
    }
}
