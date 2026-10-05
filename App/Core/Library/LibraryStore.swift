import Foundation
import Observation

/// Scans the library folder and exposes saved titles. Needs no network. OWNER: Agent 5 (Library).
@MainActor @Observable
final class LibraryStore {
    private(set) var titles: [SavedTitle] = []
    /// False when the root is on an unmounted volume (shown as "unavailable", not "empty").
    private(set) var isAvailable: Bool = true
    private(set) var hasLoaded = false
    var root: URL

    /// How long progress updates are batched before being written to meta.json.
    var progressFlushInterval: Duration = .seconds(5)

    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var isWatching = false
    @ObservationIgnored private var reloadGeneration = 0
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var pendingProgress: [String: [String: (seconds: Double, duration: Double?)]] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    init(root: URL) { self.root = root }

    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let root = root
        let result = await Task.detached(priority: .userInitiated) { LibraryScanner.scan(root: root) }.value
        guard generation == reloadGeneration else { return }
        switch result {
        case .unavailable:
            isAvailable = false
            titles = []
        case .titles(let t):
            isAvailable = true
            titles = t
            SubtitleSaver.backfill(t)
        }
        hasLoaded = true
    }

    /// Switches to a new library root (e.g. after changing `libraryPathOverride`) and reloads.
    func setRoot(_ url: URL) async {
        await flushProgress()
        root = url
        if isWatching { installWatcher() }
        await reload()
    }

    func startWatching() {
        isWatching = true
        installWatcher()
    }

    func stopWatching() {
        isWatching = false
        watcher?.stop()
        watcher = nil
    }

    func title(id: String) -> SavedTitle? { titles.first { $0.id == id } }
    func isSaved(videoId: String) -> Bool { titles.contains { $0.meta.items.contains { $0.videoId == videoId } } }

    /// Permanently deletes the item's file and updates meta.json; removes the title folder when nothing playable remains.
    func delete(_ item: SidecarMeta.SidecarItem, in title: SavedTitle) async throws {
        let folder = title.folder
        let file = title.fileURL(for: item)
        dropPendingProgress(titleID: title.id, videoId: item.videoId)
        try await Task.detached {
            try LibraryWriter.deleteItem(videoId: item.videoId, file: file, folder: folder)
        }.value
        await reload()
    }

    /// Permanently deletes the title folder and everything in it.
    func delete(title: SavedTitle) async throws {
        let folder = title.folder
        dropPendingProgress(titleID: title.id, videoId: nil)
        try await Task.detached { try LibraryWriter.remove(folder) }.value
        await reload()
    }

    /// Cheap to call often: updates memory immediately and batches meta.json writes.
    func updateProgress(titleID: String, videoId: String, seconds: Double, duration: Double?) {
        guard seconds.isFinite, seconds >= 0 else { return }
        let duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if let t = titles.firstIndex(where: { $0.id == titleID }),
           let i = titles[t].meta.items.firstIndex(where: { $0.videoId == videoId }) {
            titles[t].meta.items[i].progressSeconds = seconds
            if let duration { titles[t].meta.items[i].durationSeconds = duration }
        }
        pendingProgress[titleID, default: [:]][videoId] = (seconds, duration)
        guard flushTask == nil else { return }
        let interval = progressFlushInterval
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            await self?.flushProgress()
        }
    }

    /// Writes any pending progress to disk now (e.g. when the player closes).
    func flushProgress() async {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingProgress.isEmpty else { return }
        let pending = pendingProgress
        pendingProgress = [:]
        let writes: [(URL, [String: (seconds: Double, duration: Double?)])] = pending.map { titleID, updates in
            (title(id: titleID)?.folder ?? LibraryWriter.folder(for: titleID, root: root), updates)
        }
        await Task.detached {
            for (folder, updates) in writes {
                _ = try? LibraryWriter.modify(folder: folder) { meta in
                    guard meta != nil else { return }
                    for i in meta!.items.indices {
                        guard let u = updates[meta!.items[i].videoId] else { continue }
                        meta!.items[i].progressSeconds = u.seconds
                        if let d = u.duration { meta!.items[i].durationSeconds = d }
                    }
                }
            }
        }.value
    }

    private func dropPendingProgress(titleID: String, videoId: String?) {
        if let videoId { pendingProgress[titleID]?[videoId] = nil } else { pendingProgress[titleID] = nil }
        if pendingProgress[titleID]?.isEmpty == true { pendingProgress[titleID] = nil }
    }

    private func installWatcher() {
        watcher?.stop()
        var paths = [root]
        let components = root.standardizedFileURL.pathComponents
        if components.count >= 3, components[1] == "Volumes" {
            paths.append(URL(fileURLWithPath: "/Volumes", isDirectory: true))
        } else {
            paths.append(root.deletingLastPathComponent())
        }
        watcher = FolderWatcher(paths: paths, latency: 1.0) { [weak self] in
            self?.scheduleReload()
        }
    }

    private func scheduleReload() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }
}

/// Pure, synchronous folder scan; runs off the main thread.
enum LibraryScanner {
    enum Result: Sendable, Equatable {
        case unavailable
        case titles([SavedTitle])
    }

    static func scan(root: URL) -> Result {
        switch LibraryLocation.status(of: root) {
        case .unavailable: return .unavailable
        case .empty: return .titles([])
        case .exists: break
        }
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return .unavailable }

        var titles: [SavedTitle] = []
        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let title = loadTitle(folder: folder) else { continue }
            titles.append(title)
        }
        titles.sort { ($0.meta.latestSavedAt, $1.meta.name) > ($1.meta.latestSavedAt, $0.meta.name) }
        return .titles(titles)
    }

    /// Decodes meta.json and keeps only items whose files exist. Returns nil when nothing playable remains.
    static func loadTitle(folder: URL) -> SavedTitle? {
        guard var meta = try? LibraryWriter.read(folder: folder) else { return nil }
        let fm = FileManager.default
        meta.items = meta.items.compactMap { item in
            guard SidecarMeta.isSafeRelativePath(item.file) else { return nil }
            let url = folder.appendingPathComponent(item.file)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  attrs[.type] as? FileAttributeType != .typeDirectory else { return nil }
            var item = item
            if item.sizeBytes == nil, let size = attrs[.size] as? NSNumber { item.sizeBytes = size.int64Value }
            item.subtitles = item.subtitles?.filter { sub in
                SidecarMeta.isSafeRelativePath(sub.file) && fm.fileExists(atPath: folder.appendingPathComponent(sub.file).path)
            }
            return item
        }
        guard !meta.items.isEmpty else { return nil }
        if let p = meta.poster, !(SidecarMeta.isSafeRelativePath(p) && fm.fileExists(atPath: folder.appendingPathComponent(p).path)) {
            meta.poster = nil
        }
        if let b = meta.backdrop, !(SidecarMeta.isSafeRelativePath(b) && fm.fileExists(atPath: folder.appendingPathComponent(b).path)) {
            meta.backdrop = nil
        }
        return SavedTitle(folder: folder, meta: meta)
    }
}
