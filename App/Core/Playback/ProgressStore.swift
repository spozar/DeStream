import Foundation
import Observation

/// Watch progress keyed by videoId, for both online and saved playback. OWNER: Agent 3 (Player).
/// Persisted as JSON in Application Support/DeStream/progress.json.
@MainActor @Observable
final class ProgressStore {
    struct Entry: Codable, Hashable, Sendable {
        var videoId: String
        var metaID: String
        var metaType: String
        var title: String
        var posterURL: String?
        var seconds: Double
        var duration: Double?
        var updatedAt: Date
        /// Optional extras (added later; older progress.json files decode without them).
        var isLocal: Bool?
        var season: Int?
        var episode: Int?
        var episodeTitle: String?
        var backgroundURL: String?
        /// Set when the user removes the title from Continue Watching; cleared by the next playback.
        var hiddenFromContinueWatching: Bool?

        var fraction: Double {
            guard let duration, duration.isFinite, duration > 0, seconds.isFinite else { return 0 }
            return min(1, max(0, seconds / duration))
        }
        var isFinished: Bool { fraction >= ProgressStore.finishedFraction }
        /// Needs a known duration, so Latest can always show the time left.
        var isStarted: Bool {
            guard let duration, duration > 0 else { return false }
            return seconds >= ProgressStore.startedSeconds || fraction >= ProgressStore.startedFraction
        }
        var remainingSeconds: Double? { duration.map { max(0, $0 - seconds) } }
        var remainingText: String? { ProgressStore.remainingText(seconds: seconds, duration: duration) }
        var episodeCode: String? {
            guard let season, let episode else { return nil }
            return String(format: "S%02dE%02d", season, episode)
        }
    }

    /// An entry counts as started once 10 seconds have been watched or 3% reached, whichever comes first.
    nonisolated static let startedFraction = 0.03
    nonisolated static let startedSeconds: Double = 10
    /// At or above this fraction a video counts as watched.
    nonisolated static let finishedFraction = 0.92
    /// Minimum position before offering to resume.
    nonisolated static let minimumResumeSeconds: Double = 10

    /// What a user action did to an entry; reported through `onEntryChanged`.
    enum ChangeKind: Sendable {
        /// Playback position recorded by the player.
        case played
        case markedWatched
        /// The entry was removed (marked unwatched / progress cleared); the value is the entry as it was.
        case markedUnwatched
        /// The title was removed from Continue Watching; the value is the title's most recent entry.
        case hiddenFromContinueWatching
    }

    private(set) var entries: [String: Entry] = [:]
    @ObservationIgnored private let fileURL: URL
    /// Called after user-driven changes (record/markWatched/markUnwatched/removeFromContinueWatching),
    /// not for `save`/`clear` or changes made inside `applyingRemoteChanges`.
    @ObservationIgnored var onEntryChanged: ((Entry, ChangeKind) -> Void)?
    /// Called when `markUnwatched` targets a video with no stored entry (e.g. one shown watched only from sync state).
    @ObservationIgnored var onUnknownVideoUnwatched: ((String) -> Void)?
    @ObservationIgnored private var isApplyingRemote = false

    convenience init() {
        self.init(fileURL: Self.defaultFileURL)
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? Self.decoder.decode([Entry].self, from: data) {
            entries = Dictionary(decoded.map { ($0.videoId, $0) }, uniquingKeysWith: { $0.updatedAt > $1.updatedAt ? $0 : $1 })
        }
    }

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DeStream", isDirectory: true).appendingPathComponent("progress.json")
    }

    func entry(for videoId: String) -> Entry? { entries[videoId] }

    /// Stores the entry. Finished videos (>= 92%) are kept with seconds == duration so they read as watched.
    func save(_ entry: Entry) {
        var entry = entry
        if entry.isFinished, let duration = entry.duration { entry.seconds = duration }
        entries[entry.videoId] = entry
        persist()
    }

    func clear(_ videoId: String) {
        guard entries.removeValue(forKey: videoId) != nil else { return }
        persist()
    }

    /// Runs `body` without reporting its changes through `onEntryChanged` (used when applying synced state).
    func applyingRemoteChanges(_ body: () -> Void) {
        let wasApplying = isApplyingRemote
        isApplyingRemote = true
        defer { isApplyingRemote = wasApplying }
        body()
    }

    /// Sets or clears the Continue Watching hidden flag on every entry of a title without reporting it.
    func setHiddenFromContinueWatching(_ hidden: Bool, metaID: String) {
        var changed = false
        for (id, e) in entries where e.metaID == metaID && (e.hiddenFromContinueWatching == true) != hidden {
            entries[id]?.hiddenFromContinueWatching = hidden ? true : nil
            changed = true
        }
        if changed { persist() }
    }

    private func notify(_ entry: Entry?, _ kind: ChangeKind) {
        guard !isApplyingRemote, let entry else { return }
        onEntryChanged?(entry, kind)
    }

    /// Records the current position for a playback request. Un-hides the entry if it was removed from Continue Watching.
    func record(_ request: PlaybackRequest, seconds: Double, duration: Double?, at date: Date = .now) {
        guard request.skipsHistory != true else { return }
        let (season, episode) = Self.episodeNumbers(videoId: request.videoId, metaID: request.metaID)
        let previous = entries[request.videoId]
        save(Entry(videoId: request.videoId, metaID: request.metaID, metaType: request.metaType,
                   title: request.title,
                   posterURL: Self.preferRemote(request.posterURL, previous?.posterURL),
                   seconds: max(0, seconds), duration: duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? previous?.duration,
                   updatedAt: date,
                   isLocal: request.isLocal, season: season ?? previous?.season, episode: episode ?? previous?.episode,
                   episodeTitle: Self.episodeTitle(from: request.subtitle) ?? previous?.episodeTitle,
                   backgroundURL: Self.preferRemote(request.backgroundURL, previous?.backgroundURL),
                   hiddenFromContinueWatching: nil))
        notify(entries[request.videoId], .played)
    }

    /// Season/episode from a Stremio video id: "tt123:1:2" → (1, 2); "kitsu:42:7" (meta "kitsu:42") → (nil, 7).
    nonisolated static func episodeNumbers(videoId: String, metaID: String) -> (season: Int?, episode: Int?) {
        let rest: [Substring]
        if videoId.hasPrefix(metaID + ":") {
            rest = videoId.dropFirst(metaID.count + 1).split(separator: ":")
        } else {
            let parts = videoId.split(separator: ":")
            guard parts.count >= 3 else { return (nil, nil) }
            rest = Array(parts.suffix(2))
        }
        switch rest.count {
        case 1: return (nil, Int(rest[0]))
        case 2:
            guard let s = Int(rest[0]), let e = Int(rest[1]) else { return (nil, nil) }
            return (s, e)
        default: return (nil, nil)
        }
    }

    /// Local playback passes file:// artwork; keep a previously stored remote URL instead so cards survive library moves.
    private static func preferRemote(_ new: String?, _ old: String?) -> String? {
        guard let new else { return old }
        if new.hasPrefix("file:"), let old, !old.hasPrefix("file:") { return old }
        return new
    }

    /// Subtitles look like "S01E02 · Title"; keep just the title part.
    private static func episodeTitle(from subtitle: String?) -> String? {
        guard let subtitle else { return nil }
        let parts = subtitle.components(separatedBy: " · ")
        return parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : nil
    }

    /// Hides every entry of a title from Continue Watching / Latest (progress is kept for episode lists).
    func removeFromContinueWatching(metaID: String) {
        var changed = false
        for (id, e) in entries where e.metaID == metaID && e.hiddenFromContinueWatching != true {
            entries[id]?.hiddenFromContinueWatching = true
            changed = true
        }
        if changed {
            persist()
            notify(entries.values.filter { $0.metaID == metaID }.max { $0.updatedAt < $1.updatedAt }, .hiddenFromContinueWatching)
        }
    }

    /// Deletes every entry of a title without reporting it (the caller resets the synced state itself).
    func clearHistory(metaID: String) {
        let before = entries.count
        entries = entries.filter { $0.value.metaID != metaID }
        if entries.count != before { persist() }
    }

    /// Marks a video as fully watched. Without a known duration a 1-second placeholder is stored so it reads as finished.
    func markWatched(videoId: String, metaID: String, metaType: String, title: String, duration: Double? = nil,
                     posterURL: String? = nil, episodeTitle: String? = nil) {
        let known = [duration, entries[videoId]?.duration].compactMap { $0 }.first { $0.isFinite && $0 > 0 }
        let d = known ?? 1
        let (season, episode) = Self.episodeNumbers(videoId: videoId, metaID: metaID)
        var e = entries[videoId] ?? Entry(videoId: videoId, metaID: metaID, metaType: metaType, title: title,
                                          posterURL: posterURL, seconds: d, duration: d, updatedAt: .now,
                                          season: season, episode: episode, episodeTitle: episodeTitle)
        e.duration = d
        e.seconds = d
        e.updatedAt = .now
        save(e)
        notify(entries[videoId], .markedWatched)
    }

    func markUnwatched(videoId: String) {
        guard let removed = entries[videoId] else {
            if !isApplyingRemote { onUnknownVideoUnwatched?(videoId) }
            return
        }
        clear(videoId)
        notify(removed, .markedUnwatched)
    }

    /// All entries for a title (any state), keyed by videoId.
    func entries(forMeta metaID: String) -> [String: Entry] {
        entries.filter { $0.value.metaID == metaID }
    }

    /// "1 h 12 min left", "34 min left", "Under 1 min left". Nil without a usable duration or when nothing is left.
    /// Minutes are rounded to the nearest whole minute.
    nonisolated static func remainingText(seconds: Double, duration: Double?) -> String? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        let position = seconds.isFinite ? min(max(0, seconds), duration) : 0
        let left = duration - position
        guard left > 0 else { return nil }
        if left < 60 { return "Under 1 min left" }
        let minutes = Int((left / 60).rounded())
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) min left" }
        return m == 0 ? "\(h) h left" : "\(h) h \(m) min left"
    }

    /// Position to offer resuming from, or nil to start at the beginning.
    func resumePosition(for videoId: String) -> Double? {
        guard let entry = entries[videoId], entry.seconds > Self.minimumResumeSeconds, !entry.isFinished else { return nil }
        if let duration = entry.duration, entry.seconds >= duration { return nil }
        return entry.seconds
    }

    func isWatched(_ videoId: String) -> Bool { entries[videoId]?.isFinished ?? false }

    /// In-progress entries (3%–92%), newest first, one per title (its most recent video). Includes local playback.
    var continueWatching: [Entry] {
        var seen = Set<String>()
        return entries.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .filter { $0.hiddenFromContinueWatching != true }
            .filter { $0.isStarted && !$0.isFinished }
            .filter { seen.insert($0.metaID).inserted }
    }

    /// The Home "Latest" row: Continue Watching for streamed (non-downloaded) playback only.
    /// A title whose most recent playback was local is left out (it lives in Downloads/Saved).
    /// Entries recorded before `isLocal` existed count as streamed; use `latestStreamed(localMetaIDs:)` to refine that.
    var latestStreamed: [Entry] { latestStreamed(localMetaIDs: []) }

    /// Like `latestStreamed`, but legacy entries (isLocal == nil) whose title is in `localMetaIDs`
    /// (e.g. `LibraryStore` titles) are treated as local.
    func latestStreamed(localMetaIDs: Set<String>) -> [Entry] {
        continueWatching.filter { e in
            if let isLocal = e.isLocal { return !isLocal }
            return !localMetaIDs.contains(e.metaID)
        }
    }

    /// Streamed series whose most recently played episode is finished, newest first. Home resolves the episode
    /// after it (`nextUp(for:)`) and shows that instead, so finishing an episode doesn't drop the show.
    func upNextCandidates(localMetaIDs: Set<String>) -> [Entry] {
        var seen = Set<String>()
        return entries.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .filter { seen.insert($0.metaID).inserted }
            .filter { $0.metaType == "series" && $0.isFinished && $0.hiddenFromContinueWatching != true }
            .filter { e in
                if let isLocal = e.isLocal { return !isLocal }
                return !localMetaIDs.contains(e.metaID)
            }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Self.encoder.encode(entries.values.sorted { $0.updatedAt > $1.updatedAt })
            try data.write(to: fileURL, options: .atomic)
        } catch {
            #if DEBUG
            print("[ProgressStore] save failed: \(error.localizedDescription)")
            #endif
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
