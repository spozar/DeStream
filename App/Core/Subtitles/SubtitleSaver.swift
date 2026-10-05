import Foundation

/// Saves addon subtitles in the preferred languages next to downloaded videos, so they also play offline.
/// Files are named `<video name>.<lang>.srt` (`.<lang>.2.srt` for the second one) and recorded in meta.json.
@MainActor
enum SubtitleSaver {
    /// Off in unit tests, so library and download tests never reach the network.
    static var isEnabled = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    /// Installed addons; read from the same Keychain store AddonRegistry persists to.
    static var addonsProvider: @MainActor () -> [Addon] = { storedAddons() }
    static var languagesProvider: @MainActor () -> [String] = { AppSettings().trackPreferences.subtitleLanguages }
    static let perLanguage = 2
    /// How long an item whose subtitles couldn't be fetched (e.g. offline) waits before the library retries it.
    static let retryInterval: TimeInterval = 600

    private static var inFlight: Set<String> = []
    private static var lastAttempt: [String: Date] = [:]
    private static var backfillTask: Task<Void, Never>?

    /// Called when a download has landed in the library. Runs in the background; never fails the download.
    static func saveSubtitles(videoId: String, type: String, file: String, folder: URL, languages: [String]? = nil) {
        guard isEnabled else { return }
        let languages = languages ?? languagesProvider()
        let key = key(folder: folder, videoId: videoId)
        guard !languages.isEmpty, !inFlight.contains(key) else { return }
        let addons = addonsProvider().filter { $0.manifest.supports(resource: "subtitles", type: type, id: videoId) }
        guard !addons.isEmpty else { return }
        inFlight.insert(key)
        lastAttempt[key] = Date()
        Task.detached(priority: .utility) {
            _ = await fetchAndStore(addons: addons, type: type, videoId: videoId, file: file, folder: folder, languages: languages)
            await MainActor.run { _ = inFlight.remove(key) }
        }
    }

    /// Fetches subtitles for saved items that never got any (e.g. downloaded while offline), one item at a time.
    static func backfill(_ titles: [SavedTitle]) {
        guard isEnabled, backfillTask == nil else { return }
        let now = Date()
        let pending = titles.flatMap { title in
            title.meta.items.compactMap { item -> (SavedTitle, SidecarMeta.SidecarItem)? in
                let key = key(folder: title.folder, videoId: item.videoId)
                guard item.subtitles == nil, !inFlight.contains(key),
                      lastAttempt[key].map({ now.timeIntervalSince($0) > retryInterval }) ?? true else { return nil }
                return (title, item)
            }
        }
        guard !pending.isEmpty else { return }
        let languages = languagesProvider()
        guard !languages.isEmpty else { return }
        let all = addonsProvider()
        backfillTask = Task {
            for (title, item) in pending {
                let key = key(folder: title.folder, videoId: item.videoId)
                guard !inFlight.contains(key) else { continue }
                let addons = all.filter { $0.manifest.supports(resource: "subtitles", type: title.meta.type, id: item.videoId) }
                guard !addons.isEmpty else { continue }
                inFlight.insert(key)
                lastAttempt[key] = Date()
                let answered = await fetchAndStore(addons: addons, type: title.meta.type, videoId: item.videoId,
                                                   file: item.file, folder: title.folder, languages: languages)
                inFlight.remove(key)
                // Offline: the rest would fail the same way.
                if !answered { break }
            }
            backfillTask = nil
        }
    }

    private static func key(folder: URL, videoId: String) -> String { folder.standardizedFileURL.path + "|" + videoId }

    private static func storedAddons() -> [Addon] {
        guard let data = try? AddonStore.keychain().load(),
              let addons = try? JSONDecoder().decode([Addon].self, from: data) else { return [] }
        return addons.filter(\.enabled).sorted { $0.order < $1.order }
    }

    /// Returns false when no addon could be reached, so the item is retried later.
    nonisolated static func fetchAndStore(addons: [Addon], type: String, videoId: String, file: String, folder: URL,
                                          languages: [String]) async -> Bool {
        let video = folder.appendingPathComponent(file)
        let local = OpenSubtitlesHash.hash(fileAt: video)
        let fingerprint = VideoFingerprint(hash: local?.hash, size: local?.size, filename: video.lastPathComponent)
        let result = await AddonSubtitles.fetch(addons: addons, type: type, id: videoId, languages: languages,
                                                fingerprint: fingerprint, perLanguage: perLanguage)
        guard result.answered else { return false }
        let saved = await store(result.subtitles, videoFile: file, folder: folder, download: download)
        if saved.isEmpty && !result.subtitles.isEmpty { return false }
        let previous = (try? LibraryWriter.read(folder: folder))?.items.first { $0.videoId == videoId }?.subtitles ?? []
        let kept = Set(saved.map(\.file))
        for old in previous where !kept.contains(old.file) && SidecarMeta.isSafeRelativePath(old.file) {
            try? LibraryWriter.remove(folder.appendingPathComponent(old.file))
        }
        do {
            try LibraryWriter.setSubtitles(saved, videoId: videoId, file: file, folder: folder)
        } catch {
            return false
        }
        return true
    }

    /// Downloads each subtitle and writes it next to the video. Failed downloads are skipped.
    nonisolated static func store(_ subtitles: [ExternalSubtitle], videoFile: String, folder: URL,
                                  download: (URL) async -> Data?) async -> [SidecarMeta.SidecarSubtitle] {
        var saved: [SidecarMeta.SidecarSubtitle] = []
        var countPerLanguage: [String: Int] = [:]
        for sub in subtitles {
            guard let language = LanguageCodes.canonical(sub.language),
                  let data = await download(sub.url), let ext = fileExtension(for: data, fileName: sub.fileName) else { continue }
            let index = countPerLanguage[language, default: 0] + 1
            let name = fileName(videoFile: videoFile, language: language, index: index, ext: ext)
            do {
                try LibraryWriter.atomicWrite(data, to: folder.appendingPathComponent(name))
            } catch {
                continue
            }
            countPerLanguage[language] = index
            saved.append(SidecarMeta.SidecarSubtitle(file: name, language: language, source: sub.source,
                                                     isHashMatch: sub.isHashMatch ? true : nil))
        }
        return saved
    }

    /// `Show.S01E01.mkv` → `Show.S01E01.en.srt`, then `Show.S01E01.en.2.srt`. Stays in the video's subfolder.
    nonisolated static func fileName(videoFile: String, language: String, index: Int, ext: String) -> String {
        let base = (videoFile as NSString).deletingPathExtension
        return index <= 1 ? "\(base).\(language).\(ext)" : "\(base).\(language).\(index).\(ext)"
    }

    /// The subtitle format from its content, then its name; nil for anything that isn't a subtitle (e.g. an HTML error page).
    nonisolated static func fileExtension(for data: Data, fileName: String?) -> String? {
        let head = String(decoding: data.prefix(512), as: UTF8.self)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        guard !head.isEmpty, !head.hasPrefix("<"), !head.hasPrefix("{\"") else { return nil }
        if head.hasPrefix("WEBVTT") { return "vtt" }
        if head.hasPrefix("[Script Info]") { return "ass" }
        let named = (fileName.map { ($0 as NSString).pathExtension.lowercased() }) ?? ""
        return LibraryWriter.subtitleExtensions.contains(named) && named != "vtt" && named != "ass" ? named : "srt"
    }

    nonisolated private static func download(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              !data.isEmpty, data.count < 10_000_000 else { return nil }
        return data
    }
}
