import Foundation
import Observation

/// The parts of `StremioAPI` library sync needs; a seam so tests run without the network.
protocol StremioLibraryAPI: Sendable {
    func libraryMeta(authKey: String) async throws -> [StremioItemMeta]
    func libraryItems(ids: [String]?, authKey: String) async throws -> [StremioLibraryItem]
    func putLibraryItems(_ items: [StremioLibraryItem], authKey: String) async throws
}

extension StremioAPI: StremioLibraryAPI {}

/// Syncs the Stremio library (bookmarks, watch progress, watched episodes) with `ProgressStore`. OWNER: Stremio Agent 3 (Library sync).
///
/// Local playback/watched changes are written into `items` the way stremio-core's player does, then pushed on the next
/// `sync()`; `onLocalChange` fires after each local change so the coordinator can schedule a debounced sync.
/// Items persist in Application Support/DeStream/stremio-library.json, so the library works offline and signed out
/// (signed-out items merge into the account on the first sync after signing in). Call `reset()` on sign-out.
@MainActor @Observable
final class LibrarySync {
    typealias Credentials = (userID: String, authKey: String)

    @ObservationIgnored let account: StremioAccount
    @ObservationIgnored let progress: ProgressStore

    /// Account library items by id (includes removed/temp ones, as on the server).
    private(set) var items: [String: StremioLibraryItem] = [:]
    private(set) var lastSyncedAt: Date?

    /// Called after every local change that needs pushing (wire to `SyncCoordinator.scheduleSync()`).
    @ObservationIgnored var onLocalChange: (() -> Void)?

    @ObservationIgnored private let api: any StremioLibraryAPI
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let credentials: @MainActor () -> Credentials?
    @ObservationIgnored private let now: () -> Date

    /// Account the stored items belong to; nil while they were only collected signed out.
    @ObservationIgnored private var ownerID: String?
    @ObservationIgnored private var dirty: Set<String> = []
    /// Episode watched flags set before the title's episode list was known: metaID → videoId → watched.
    @ObservationIgnored private var pendingWatched: [String: [String: Bool]] = [:]
    /// Episode lists in stremio-core bitfield order, registered by the UI when a meta loads.
    @ObservationIgnored private var videoIDsByMeta: [String: [String]] = [:]
    /// Wall-clock time of the last recorded position per video, to cap counted watch time across seeks.
    @ObservationIgnored private var lastRecordedAt: [String: Date] = [:]
    /// metaID → episode the pointer advanced away from after its credits, so its trailing records are ignored.
    @ObservationIgnored private var advancedFrom: [String: String] = [:]
    @ObservationIgnored private var syncTask: Task<Void, Error>?

    /// stremio-core's `WATCHED_THRESHOLD_COEF` (time watched / duration) and `CREDITS_THRESHOLD_COEF` (position / duration).
    nonisolated static let watchedThreshold = 0.7
    nonisolated static let creditsThreshold = 0.9
    nonisolated private static let pullChunkSize = 100

    convenience init(account: StremioAccount, progress: ProgressStore) {
        self.init(account: account, progress: progress, api: account.api, fileURL: Self.defaultFileURL,
                  credentials: { account.user.flatMap { user in account.authKey.map { (user.id, $0) } } })
    }

    init(account: StremioAccount, progress: ProgressStore, api: any StremioLibraryAPI, fileURL: URL,
         credentials: @escaping @MainActor () -> Credentials?, now: @escaping () -> Date = Date.init) {
        self.account = account
        self.progress = progress
        self.api = api
        self.fileURL = fileURL
        self.credentials = credentials
        self.now = now
        load()
        progress.onEntryChanged = { [weak self] entry, kind in self?.handleLocalChange(entry, kind) }
        progress.onUnknownVideoUnwatched = { [weak self] videoID in self?.handleUnwatched(videoID: videoID) }
    }

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DeStream", isDirectory: true).appendingPathComponent("stremio-library.json")
    }

    // MARK: - Library

    /// Titles explicitly in the library (not removed, not temp), most recently changed first.
    var libraryItems: [StremioLibraryItem] {
        items.values.filter { !$0.removed && !$0.temp }.sorted { $0.mtime > $1.mtime }
    }

    func isInLibrary(_ metaID: String) -> Bool {
        guard let item = items[metaID] else { return false }
        return !item.removed && !item.temp
    }

    func addToLibrary(id: String, type: String, name: String, poster: String?) {
        var item = items[id] ?? newItem(id: id, type: type, name: name, poster: poster)
        item.name = name
        item.type = type
        if let poster = Self.remotePoster(poster) { item.poster = poster }
        item.removed = false
        item.temp = false
        commit(item)
    }

    func removeFromLibrary(id: String) {
        guard var item = items[id] else { return }
        item.removed = true
        item.temp = false
        commit(item)
    }

    /// Forgets a title's watch state on the account: progress, last watched and watched episodes. Stremio keeps no
    /// separate history, so this is what "remove from history" means; titles only known from watching disappear.
    func clearHistory(metaID: String) {
        pendingWatched[metaID] = nil
        advancedFrom[metaID] = nil
        guard var item = items[metaID] else { return }
        item.state = StremioLibraryItem.State(noNotif: item.state.noNotif)
        if item.temp { item.removed = true }
        commit(item)
    }

    // MARK: - Watched episodes

    /// Video ids of `metaID` marked watched on the account. `videoIDs` is the title's episode list in
    /// stremio-core order (see `bitfieldVideoIDs(_:)`).
    func watchedVideoIDs(metaID: String, videoIDs: [String]) -> Set<String> {
        var watched = items[metaID]?.state.watched.map { WatchedBitfield.decode($0, videoIDs: videoIDs) } ?? []
        for (videoID, isWatched) in pendingWatched[metaID] ?? [:] {
            if isWatched { watched.insert(videoID) } else { watched.remove(videoID) }
        }
        return watched
    }

    /// Video ids in the order stremio-core builds the watched bitfield from: season, then episode, then release date
    /// (videos without season/episode first). Includes specials.
    nonisolated static func bitfieldVideoIDs(_ meta: MetaDetail) -> [String] {
        (meta.videos ?? []).enumerated().sorted { a, b in
            func key(_ v: Video) -> (Int, Int) {
                guard let s = v.season, let e = v.episode else { return (Int.min, Int.min) }
                return (s, e)
            }
            let ka = key(a.element), kb = key(b.element)
            if ka != kb { return ka < kb }
            let ra = a.element.released ?? "", rb = b.element.released ?? ""
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element.id)
    }

    /// Call when a series' meta has loaded: remembers its episode list (needed to write watched flags), flushes flags
    /// set before it was known, and marks episodes watched on the account as watched in `ProgressStore`.
    func registerVideos(for meta: MetaDetail) {
        registerVideos(metaID: meta.id, videoIDs: Self.bitfieldVideoIDs(meta))
    }

    func registerVideos(metaID: String, videoIDs: [String]) {
        guard !videoIDs.isEmpty else { return }
        videoIDsByMeta[metaID] = videoIDs
        if let pending = pendingWatched[metaID], var item = items[metaID] {
            let watched = watchedVideoIDs(metaID: metaID, videoIDs: videoIDs)
            pendingWatched[metaID] = nil
            if !pending.isEmpty {
                item.state.watched = WatchedBitfield.encode(watched: watched, videoIDs: videoIDs)
                commit(item)
            }
        }
        if let item = items[metaID] { applyWatchedEpisodes(item, videoIDs: videoIDs) }
    }

    // MARK: - Sync

    /// Pull remote changes into `ProgressStore`/`items` and push local changes. No-op when signed out.
    /// Per item, the newer `_mtime` wins. Throws `StremioAPIError.unauthorized` after signing the account out.
    func sync() async throws {
        while let running = syncTask { _ = try? await running.value }
        let task = Task {
            defer { syncTask = nil }
            try await performSync()
        }
        syncTask = task
        try await task.value
    }

    /// Forgets all account library state (memory and disk). Call on sign-out; `ProgressStore` history is kept.
    func reset() {
        items = [:]
        lastSyncedAt = nil
        ownerID = nil
        dirty = []
        pendingWatched = [:]
        advancedFrom = [:]
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func performSync() async throws {
        guard let creds = credentials() else {
            if ownerID != nil { reset() }
            return
        }
        if let ownerID, ownerID != creds.userID { reset() }
        ownerID = creds.userID
        defer { persist() }
        do {
            let metas = try await api.libraryMeta(authKey: creds.authKey)
            let remoteMtimes = Dictionary(metas.map { ($0.id, $0.mtime) }, uniquingKeysWith: { max($0, $1) })

            let pullIDs = metas.filter { meta in
                guard let local = items[meta.id] else { return true }
                return Self.isNewer(meta.mtime, than: local.mtime)
            }.map(\.id)
            for chunk in stride(from: 0, to: pullIDs.count, by: Self.pullChunkSize) {
                let ids = Array(pullIDs[chunk..<min(chunk + Self.pullChunkSize, pullIDs.count)])
                let pulled = try await api.libraryItems(ids: ids, authKey: creds.authKey)
                for remote in pulled { merge(remote) }
            }

            let nowDate = now()
            let push = items.values.filter { item in
                guard Self.shouldSync(item, now: nowDate) else { return false }
                guard let remote = remoteMtimes[item.id] else { return true }
                return dirty.contains(item.id) || Self.isNewer(item.mtime, than: remote)
            }
            if !push.isEmpty {
                try await api.putLibraryItems(push, authKey: creds.authKey)
                for item in push where items[item.id]?.mtime == item.mtime { dirty.remove(item.id) }
            }
            dirty = dirty.filter { items[$0].map { Self.shouldSync($0, now: nowDate) } ?? false }
            lastSyncedAt = nowDate
        } catch StremioAPIError.unauthorized {
            account.handleUnauthorized()
            throw StremioAPIError.unauthorized
        }
    }

    /// Takes a pulled item unless the local copy changed after it, and applies it to `ProgressStore`.
    private func merge(_ remote: StremioLibraryItem) {
        if let local = items[remote.id], Self.isNewer(local.mtime, than: remote.mtime) { return }
        items[remote.id] = remote
        dirty.remove(remote.id)
        applyToProgress(remote)
    }

    // MARK: - Remote → ProgressStore

    private func applyToProgress(_ item: StremioLibraryItem) {
        let state = item.state
        let inContinueWatching = Self.isInContinueWatching(item)
        let newestLocal = progress.entries(forMeta: item.id).values.map(\.updatedAt).max()
        let when = state.lastWatched ?? item.mtime
        let poster = Self.remotePoster(item.poster)

        progress.applyingRemoteChanges {
            // timeOffset 1 is stremio-core's "next episode" pointer, not real progress.
            if let videoID = state.videoId, state.timeOffset > 1000, state.duration > 0 {
                let existing = progress.entry(for: videoID)
                if existing.map({ Self.isNewer(when, than: $0.updatedAt) }) ?? true {
                    let (season, episode) = ProgressStore.episodeNumbers(videoId: videoID, metaID: item.id)
                    progress.save(ProgressStore.Entry(
                        videoId: videoID, metaID: item.id, metaType: item.type, title: item.name,
                        posterURL: poster ?? existing?.posterURL,
                        seconds: Double(state.timeOffset) / 1000, duration: Double(state.duration) / 1000,
                        updatedAt: when, isLocal: existing?.isLocal ?? false,
                        season: season ?? existing?.season, episode: episode ?? existing?.episode,
                        episodeTitle: existing?.episodeTitle, backgroundURL: existing?.backgroundURL,
                        hiddenFromContinueWatching: inContinueWatching ? nil : true))
                }
            }
            // Dismissing from Continue Watching in Stremio rewinds the item (timeOffset = 0).
            if newestLocal.map({ Self.isNewer(item.mtime, than: $0) }) ?? false {
                progress.setHiddenFromContinueWatching(!inContinueWatching, metaID: item.id)
            }
            if Self.isMovieLike(item) { applyMovieWatched(item) }
        }
        if let videoIDs = videoIDsByMeta[item.id] { applyWatchedEpisodes(item, videoIDs: videoIDs) }
    }

    private func applyMovieWatched(_ item: StremioLibraryItem) {
        let local = progress.entry(for: item.id)
        guard local.map({ Self.isNewer(item.mtime, than: $0.updatedAt) }) ?? true else { return }
        if item.state.timesWatched > 0, item.state.timeOffset == 0, local?.isFinished != true {
            saveWatched(videoID: item.id, item: item, existing: local)
        } else if item.state.timesWatched == 0, local?.isFinished == true {
            progress.clear(item.id)
        }
    }

    /// Adds account-watched episodes to `ProgressStore`. Unwatching on the account is not mirrored, so a stale or
    /// misaligned bitfield can never erase local history.
    private func applyWatchedEpisodes(_ item: StremioLibraryItem, videoIDs: [String]) {
        let watched = watchedVideoIDs(metaID: item.id, videoIDs: videoIDs)
        progress.applyingRemoteChanges {
            for videoID in watched where !progress.isWatched(videoID) {
                let existing = progress.entry(for: videoID)
                guard existing.map({ Self.isNewer(item.mtime, than: $0.updatedAt) }) ?? true else { continue }
                saveWatched(videoID: videoID, item: item, existing: existing)
            }
        }
    }

    private func saveWatched(videoID: String, item: StremioLibraryItem, existing: ProgressStore.Entry?) {
        let duration = existing?.duration ?? (videoID == item.state.videoId && item.state.duration > 0
            ? Double(item.state.duration) / 1000 : 1)
        let (season, episode) = ProgressStore.episodeNumbers(videoId: videoID, metaID: item.id)
        let date = min(item.state.lastWatched ?? item.mtime, item.mtime)
        progress.save(ProgressStore.Entry(
            videoId: videoID, metaID: item.id, metaType: item.type, title: item.name,
            posterURL: existing?.posterURL ?? Self.remotePoster(item.poster), seconds: duration, duration: duration,
            updatedAt: existing.map { max($0.updatedAt, date) } ?? date, isLocal: existing?.isLocal,
            season: season ?? existing?.season, episode: episode ?? existing?.episode,
            episodeTitle: existing?.episodeTitle, backgroundURL: existing?.backgroundURL,
            hiddenFromContinueWatching: existing?.hiddenFromContinueWatching))
    }

    // MARK: - ProgressStore → library items (mirrors stremio-core)

    private func handleLocalChange(_ entry: ProgressStore.Entry, _ kind: ProgressStore.ChangeKind) {
        let existing = items[entry.metaID]
        switch kind {
        case .played, .markedWatched: break
        case .markedUnwatched, .hiddenFromContinueWatching: guard existing != nil else { return }
        }
        var item = existing ?? newItem(id: entry.metaID, type: entry.metaType, name: entry.title, poster: entry.posterURL)
        if item.poster == nil { item.poster = Self.remotePoster(entry.posterURL) }

        switch kind {
        case .played: applyPlayback(entry, to: &item)
        case .markedWatched: setWatched(true, videoID: entry.videoId, item: &item)
        case .markedUnwatched:
            setWatched(false, videoID: entry.videoId, item: &item)
            if item.state.videoId == entry.videoId { item.state.timeOffset = 0 }
        case .hiddenFromContinueWatching:
            // stremio-core `RewindLibraryItem`
            item.state.timeOffset = 0
        }
        commit(item)
    }

    /// Unwatching a video that only the account knew as watched: find its title by id prefix ("tt1:1:2" → "tt1").
    private func handleUnwatched(videoID: String) {
        let owner = items.keys.filter { videoID == $0 || videoID.hasPrefix($0 + ":") }.max { $0.count < $1.count }
        guard let owner, var item = items[owner] else { return }
        setWatched(false, videoID: videoID, item: &item)
        if item.state.videoId == videoID { item.state.timeOffset = 0 }
        commit(item)
    }

    /// stremio-core `Player` `TimeChanged`, plus the end-of-playback credits reset.
    private func applyPlayback(_ entry: ProgressStore.Entry, to item: inout StremioLibraryItem) {
        let date = now()
        let time = Self.milliseconds(entry.seconds)
        let duration = Self.milliseconds(entry.duration ?? 0)
        let videoID = entry.videoId
        if advancedFrom[item.id] == videoID, entry.fraction >= Self.creditsThreshold { return }
        advancedFrom[item.id] = nil

        var state = item.state
        state.lastWatched = date
        if state.videoId != videoID {
            state.videoId = videoID
            state.overallTimeWatched += state.timeWatched
            state.timeWatched = 0
            state.flaggedWatched = 0
            state.timeOffset = time
            state.duration = duration
        } else {
            // stremio-core relies on separate seek actions; cap by wall-clock time so a seek is not counted as watched.
            let elapsed = lastRecordedAt[videoID].map { Self.milliseconds(date.timeIntervalSince($0) + 2) } ?? 30_000
            let watched = min(max(0, time - state.timeOffset), elapsed)
            state.timeWatched += watched
            state.overallTimeWatched += watched
            state.timeOffset = time
            if duration > 0 { state.duration = duration }
        }
        lastRecordedAt[videoID] = date

        let reachedThreshold = state.duration > 0
            && (Double(state.timeWatched) > Double(state.duration) * Self.watchedThreshold || entry.isFinished)
        if state.flaggedWatched == 0, reachedThreshold {
            state.flaggedWatched = 1
            state.timesWatched += 1
            item.state = state
            if !Self.isMovie(videoID: videoID, metaID: item.id) { setBit(true, videoID: videoID, item: &item) }
            state = item.state
        }

        if state.duration > 0, Double(state.timeOffset) > Double(state.duration) * Self.creditsThreshold {
            state.timeOffset = 0
            if let next = nextVideo(after: videoID, metaID: item.id) {
                advancedFrom[item.id] = videoID
                state.videoId = next
                state.overallTimeWatched += state.timeWatched
                state.timeWatched = 0
                state.flaggedWatched = 0
                state.timeOffset = 1
            }
        }
        item.state = state

        if item.temp, item.state.timesWatched == 0 { item.removed = true }
        if item.removed { item.temp = true }
    }

    /// stremio-core `mark_as_watched` for movies, `mark_video_as_watched` for episodes.
    private func setWatched(_ watched: Bool, videoID: String, item: inout StremioLibraryItem) {
        if Self.isMovie(videoID: videoID, metaID: item.id) {
            if watched {
                item.state.timesWatched += 1
                item.state.lastWatched = now()
                item.state.timeOffset = 0
            } else {
                item.state.timesWatched = 0
            }
            return
        }
        setBit(watched, videoID: videoID, item: &item)
        guard watched else { return }
        if item.state.lastWatched == nil { item.state.lastWatched = now() }
        if item.state.videoId == videoID {
            item.state.timeOffset = 0
            if let next = nextVideo(after: videoID, metaID: item.id) {
                item.state.videoId = next
                item.state.overallTimeWatched += item.state.timeWatched
                item.state.timeWatched = 0
                item.state.flaggedWatched = 0
                item.state.timeOffset = 1
            }
        }
    }

    private func setBit(_ watched: Bool, videoID: String, item: inout StremioLibraryItem) {
        guard let videoIDs = videoIDsByMeta[item.id] else {
            pendingWatched[item.id, default: [:]][videoID] = watched
            return
        }
        var set = watchedVideoIDs(metaID: item.id, videoIDs: videoIDs)
        pendingWatched[item.id] = nil
        if watched { set.insert(videoID) } else { set.remove(videoID) }
        item.state.watched = WatchedBitfield.encode(watched: set, videoIDs: videoIDs)
    }

    private func nextVideo(after videoID: String, metaID: String) -> String? {
        guard let ids = videoIDsByMeta[metaID], let i = ids.firstIndex(of: videoID), i + 1 < ids.count else { return nil }
        return ids[i + 1]
    }

    // MARK: - Helpers

    /// stremio-core `LibraryItem::from(MetaItemPreview)`: a temp item that is not in the library.
    private func newItem(id: String, type: String, name: String, poster: String?) -> StremioLibraryItem {
        let date = now()
        return StremioLibraryItem(id: id, name: name, type: type, poster: Self.remotePoster(poster), posterShape: "poster",
                                  removed: true, temp: true, ctime: date, mtime: date,
                                  state: .init(lastWatched: date))
    }

    /// Stores a locally changed item with a fresh `_mtime` (ms precision, as on the wire) and asks for a sync.
    private func commit(_ item: StremioLibraryItem) {
        var item = item
        if let old = items[item.id] {
            var unchanged = old
            unchanged.mtime = item.mtime
            if unchanged == item { return }
        }
        item.mtime = Self.wireDate(now())
        items[item.id] = item
        dirty.insert(item.id)
        persist()
        onLocalChange?()
    }

    nonisolated static func isInContinueWatching(_ item: StremioLibraryItem) -> Bool {
        item.type != "other" && (!item.removed || item.temp) && item.state.timeOffset > 0
    }

    /// stremio-core `should_sync`: skip "other" items and ones removed more than a year ago.
    nonisolated static func shouldSync(_ item: StremioLibraryItem, now: Date) -> Bool {
        let yearAgo = now.addingTimeInterval(-365 * 24 * 3600)
        return item.type != "other" && (!item.removed || item.mtime > yearAgo)
    }

    /// Movies (and other single-video titles) play the meta id itself.
    nonisolated static func isMovie(videoID: String, metaID: String) -> Bool { videoID == metaID }

    nonisolated private static func isMovieLike(_ item: StremioLibraryItem) -> Bool {
        item.type == "movie" || item.state.videoId == item.id
    }

    /// The API stores milliseconds; differences below that are the same instant.
    nonisolated static func isNewer(_ a: Date, than b: Date) -> Bool { a.timeIntervalSince(b) >= 0.001 }

    nonisolated private static func wireDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
    }

    nonisolated private static func milliseconds(_ seconds: Double) -> Int64 {
        seconds.isFinite && seconds > 0 ? Int64(seconds * 1000) : 0
    }

    nonisolated private static func remotePoster(_ url: String?) -> String? {
        guard let url, !url.hasPrefix("file:") else { return nil }
        return url
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        var ownerID: String?
        var items: [StremioLibraryItem]
        var dirty: [String]
        var pendingWatched: [String: [String: Bool]]
        var lastSyncedAt: Date?
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        ownerID = state.ownerID
        items = Dictionary(state.items.map { ($0.id, $0) }, uniquingKeysWith: { $0.mtime > $1.mtime ? $0 : $1 })
        dirty = Set(state.dirty)
        pendingWatched = state.pendingWatched
        lastSyncedAt = state.lastSyncedAt
    }

    private func persist() {
        let state = Persisted(ownerID: ownerID, items: items.values.sorted { $0.mtime > $1.mtime }, dirty: dirty.sorted(),
                              pendingWatched: pendingWatched, lastSyncedAt: lastSyncedAt)
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: fileURL, options: .atomic)
        } catch {
            #if DEBUG
            print("[LibrarySync] save failed: \(error.localizedDescription)")
            #endif
        }
    }
}
