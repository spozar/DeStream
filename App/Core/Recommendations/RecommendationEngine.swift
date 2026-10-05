import Foundation
import Observation

/// Builds and caches the Suggestions feed from Stremio/local watch history. OWNER: Rec Agent 2 (Engine).
@MainActor @Observable
final class Recommendations {
    enum Phase: Equatable, Sendable {
        case idle
        case loading
        case loaded(RecommendationFeed)
        /// No watch history yet (nothing to base suggestions on).
        case noHistory
        case failed(String)
    }

    /// Watch history snapshot the seeds are computed from.
    struct History: Sendable {
        var libraryItems: [StremioLibraryItem]
        var progress: [ProgressStore.Entry]
    }

    /// A Cinemeta "top" catalog request; `genre == nil` means the plain popular list.
    struct GenreKey: Hashable, Sendable {
        var type: String
        var genre: String?
    }

    typealias MetaFetcher = @MainActor @Sendable (_ type: String, _ id: String) async throws -> MetaDetail
    typealias CatalogFetcher = @MainActor @Sendable (_ type: String, _ genre: String?) async throws -> [MetaPreview]

    /// The user's choice; persisted. Falls back to `.cinemeta` while no TMDB key is stored.
    /// Changing it cancels an in-flight load; call `load()` afterwards (e.g. keyed on `effectiveSource`).
    var source: RecommendationSource = .cinemeta {
        didSet {
            guard source != oldValue, !isApplyingDefaultSource else { return }
            defaults.set(source.rawValue, forKey: Keys.source)
            // Without a TMDB key both choices load Cinemeta, so `effectiveSource` doesn't change and nothing
            // would restart a cancelled load (the page would stay in `.loading`).
            let oldEffective: RecommendationSource = oldValue == .tmdb && tmdbAvailable() ? .tmdb : .cinemeta
            guard oldEffective != effectiveSource else { return }
            loadTask?.cancel()
            generation += 1
            isRefreshing = false
        }
    }
    /// Sources currently usable (`.tmdb` only with a key).
    var availableSources: [RecommendationSource] { tmdbAvailable() ? [.tmdb, .cinemeta] : [.cinemeta] }
    /// Source actually used for the next load (`source`, or `.cinemeta` when TMDB isn't available).
    var effectiveSource: RecommendationSource { source == .tmdb && tmdbAvailable() ? .tmdb : .cinemeta }
    private(set) var phase: Phase = .idle
    /// Seeds the current feed is based on, highest weight first.
    private(set) var seeds: [RecommendationSeed] = []
    /// True while fetching a fresh feed (`phase` is `.loading` meanwhile).
    private(set) var isRefreshing = false
    /// The most recent feed shown or cached (possibly stale or from the other source), for display while `.loading`.
    /// Cleared only when there is no history.
    private(set) var lastFeed: RecommendationFeed?
    /// Non-fatal note for the UI, e.g. TMDB failed and Cinemeta was used, or a refresh failed while showing a cached feed.
    private(set) var notice: String?

    nonisolated static let seedLimit = 8
    nonisolated static let halfLife: TimeInterval = 30 * 86_400
    nonisolated static let maxCacheAge: TimeInterval = 12 * 3_600
    nonisolated static let minRowItems = 4
    nonisolated static let maxRowItems = 20
    nonisolated static let maxAppearances = 2
    nonisolated static let maxGenreRows = 5

    private enum Keys {
        static let source = "recommendations.source"
        static let dismissed = "recommendations.dismissed"
        static let ignoredSeeds = "recommendations.ignoredSeeds"
        /// Prefix of per-list flags set once this device's list has been merged with the iCloud copy.
        static let cloudMerged = "recommendations.cloudMerged"
    }

    @ObservationIgnored private let history: @MainActor () -> History
    @ObservationIgnored private let clearHistory: @MainActor (String) -> Void
    @ObservationIgnored private let tmdbAvailable: @MainActor () -> Bool
    @ObservationIgnored private let makeTMDB: @MainActor () -> (any TMDBService)?
    @ObservationIgnored private let fetchMeta: MetaFetcher
    @ObservationIgnored private let fetchCatalog: CatalogFetcher
    @ObservationIgnored private let cacheDirectory: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let cloud: CloudKeyValues?
    private var dismissed: Set<String>
    /// Watched titles the user excluded from seeding (e.g. someone else watched them on this account).
    private(set) var ignoredSeedIDs: Set<String>
    /// Bumped whenever the history list may have changed, so views showing `watchHistory()` refresh.
    private(set) var historyVersion = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isApplyingDefaultSource = false

    convenience init(librarySync: LibrarySync, progress: ProgressStore, registry: AddonRegistry, tmdb: TMDBKeyStore) {
        self.init(
            history: { History(libraryItems: Array(librarySync.items.values), progress: Array(progress.entries.values)) },
            clearHistory: { metaID in
                progress.clearHistory(metaID: metaID)
                librarySync.clearHistory(metaID: metaID)
            },
            tmdbAvailable: { tmdb.hasKey },
            makeTMDB: { tmdb.makeService() },
            fetchMeta: { type, id in try await registry.meta(type: type, id: id) },
            fetchCatalog: Self.cinemetaCatalogFetcher(registry: registry),
            cloud: .shared
        )
    }

    init(history: @escaping @MainActor () -> History,
         clearHistory: @escaping @MainActor (String) -> Void = { _ in },
         tmdbAvailable: @escaping @MainActor () -> Bool,
         makeTMDB: @escaping @MainActor () -> (any TMDBService)?,
         fetchMeta: @escaping MetaFetcher,
         fetchCatalog: @escaping CatalogFetcher,
         cacheDirectory: URL = Recommendations.defaultCacheDirectory,
         defaults: UserDefaults = .standard,
         now: @escaping @Sendable () -> Date = Date.init,
         cloud: CloudKeyValues? = nil) {
        self.history = history
        self.clearHistory = clearHistory
        self.tmdbAvailable = tmdbAvailable
        self.makeTMDB = makeTMDB
        self.fetchMeta = fetchMeta
        self.fetchCatalog = fetchCatalog
        self.cacheDirectory = cacheDirectory
        self.defaults = defaults
        self.now = now
        self.cloud = cloud
        dismissed = Set(defaults.stringArray(forKey: Keys.dismissed) ?? [])
        ignoredSeedIDs = Set(defaults.stringArray(forKey: Keys.ignoredSeeds) ?? [])
        source = defaults.string(forKey: Keys.source).flatMap(RecommendationSource.init(rawValue:))
            ?? (tmdbAvailable() ? .tmdb : .cinemeta)
        if let cloud {
            for key in [Keys.dismissed, Keys.ignoredSeeds] {
                cloud.observe(key) { [weak self] in self?.applyCloud(key) }
                applyCloud(key)
            }
        }
    }

    nonisolated static var defaultCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeStream", isDirectory: true)
            .appendingPathComponent("Suggestions", isDirectory: true)
    }

    // MARK: - Loading

    /// Loads the feed for `effectiveSource`; serves the cached feed first when fresh unless `force`.
    func load(force: Bool = false) async {
        applyDefaultSourceIfNeeded()
        loadTask?.cancel()
        generation += 1
        let gen = generation
        let task = Task { await self.refresh(force: force, generation: gen) }
        loadTask = task
        await task.value
    }

    /// Removes a title from future suggestions ("Not interested"); persisted.
    func dismiss(metaID: String) {
        guard dismissed.insert(metaID).inserted else { return }
        persist(dismissed, key: Keys.dismissed)
        if case .loaded(let feed) = phase { phase = .loaded(Self.filtered(feed, excluding: [metaID])) }
        lastFeed = lastFeed.map { Self.filtered($0, excluding: [metaID]) }
        for source in RecommendationSource.allCases {
            guard var cached = readCache(source) else { continue }
            cached.feed = Self.filtered(cached.feed, excluding: [metaID])
            writeCache(cached, source: source)
        }
    }

    /// Forgets every "Not interested" choice; takes effect on the next refresh.
    func resetDismissed() {
        dismissed.removeAll()
        persist(dismissed, key: Keys.dismissed)
    }

    var dismissedIDs: Set<String> { dismissed }

    // MARK: - Watch history

    /// Every watched title suggestions can be based on, most recently watched first (ignored ones included).
    func watchHistory() -> [RecommendationSeed] {
        let snapshot = history()
        return Self.computeSeeds(libraryItems: snapshot.libraryItems, progress: snapshot.progress, now: now(), limit: .max)
            .sorted { $0.lastWatched > $1.lastWatched }
    }

    func countsTowardSuggestions(_ metaID: String) -> Bool { !ignoredSeedIDs.contains(metaID) }

    /// Includes or excludes a watched title as a basis for suggestions; persisted, applied on the next load.
    func setCountsTowardSuggestions(_ counts: Bool, metaID: String) {
        if counts { ignoredSeedIDs.remove(metaID) } else { ignoredSeedIDs.insert(metaID) }
        persist(ignoredSeedIDs, key: Keys.ignoredSeeds)
    }

    /// Deletes a title's progress and watched state locally and on the Stremio account.
    func removeFromHistory(metaID: String) {
        clearHistory(metaID)
        ignoredSeedIDs.remove(metaID)
        persist(ignoredSeedIDs, key: Keys.ignoredSeeds)
        historyVersion += 1
    }

    // MARK: - iCloud

    private func persist(_ ids: Set<String>, key: String) {
        defaults.set(ids.sorted(), forKey: key)
        cloud?.set(ids.sorted(), forKey: key)
    }

    /// Adopts the iCloud copy of `key`. The first time a device sees one it merges instead, so choices made on
    /// each device before syncing existed aren't lost.
    private func applyCloud(_ key: String) {
        guard let cloud else { return }
        let local = key == Keys.dismissed ? dismissed : ignoredSeedIDs
        guard let remote = cloud.strings(forKey: key).map(Set.init) else {
            // iCloud may not have delivered anything yet; an empty local list must not overwrite another device's.
            if !local.isEmpty { cloud.set(local.sorted(), forKey: key) }
            return
        }
        let mergedKey = Keys.cloudMerged + "." + key
        let merged = defaults.bool(forKey: mergedKey) ? remote : local.union(remote)
        defaults.set(true, forKey: mergedKey)
        if merged != remote { cloud.set(merged.sorted(), forKey: key) }
        guard merged != local else { return }
        defaults.set(merged.sorted(), forKey: key)
        if key == Keys.dismissed {
            dismissed = merged
            if case .loaded(let feed) = phase { phase = .loaded(Self.filtered(feed, excluding: merged)) }
            lastFeed = lastFeed.map { Self.filtered($0, excluding: merged) }
        } else {
            ignoredSeedIDs = merged
            historyVersion += 1
        }
    }

    /// Without an explicit choice the source follows whether a TMDB key exists (it may be added after launch).
    private func applyDefaultSourceIfNeeded() {
        guard defaults.string(forKey: Keys.source) == nil else { return }
        let preferred: RecommendationSource = tmdbAvailable() ? .tmdb : .cinemeta
        guard preferred != source else { return }
        isApplyingDefaultSource = true
        source = preferred
        isApplyingDefaultSource = false
    }

    private func refresh(force: Bool, generation gen: Int) async {
        let source = effectiveSource
        let snapshot = history()
        let seeds = Self.computeSeeds(libraryItems: snapshot.libraryItems, progress: snapshot.progress, now: now(),
                                      ignoring: ignoredSeedIDs)
        guard !seeds.isEmpty else {
            self.seeds = []
            lastFeed = nil
            notice = nil
            isRefreshing = false
            phase = .noHistory
            return
        }
        let excluded = Self.exclusions(libraryItems: snapshot.libraryItems, progress: snapshot.progress).union(dismissed)
        let fingerprint = Self.fingerprint(seeds)

        if let cached = readCache(source) {
            if !force, cached.fingerprint == fingerprint,
               now().timeIntervalSince(cached.feed.generatedAt) < Self.maxCacheAge {
                publish(cached.feed, seeds: cached.seeds, excluded: excluded)
                notice = nil
                isRefreshing = false
                return
            }
            self.seeds = cached.seeds
            lastFeed = Self.filtered(cached.feed, excluding: excluded)
        }
        phase = .loading
        isRefreshing = true

        var result: (feed: RecommendationFeed, seeds: [RecommendationSeed])?
        var newNotice: String?
        if source == .tmdb {
            if let service = makeTMDB() {
                result = await buildTMDB(service: service, seeds: seeds, excluded: excluded)
            }
            if result == nil, !Task.isCancelled {
                result = await buildCinemeta(seeds: seeds, excluded: excluded)
                if result != nil { newNotice = "TMDB couldn't be reached, so these suggestions come from Cinemeta." }
            }
        } else {
            result = await buildCinemeta(seeds: seeds, excluded: excluded)
        }

        guard gen == generation, !Task.isCancelled else { return }
        isRefreshing = false
        if let result {
            notice = newNotice
            publish(result.feed, seeds: result.seeds, excluded: [])
            if result.feed.source == source {
                writeCache(CachedFeed(feed: result.feed, seeds: result.seeds, fingerprint: fingerprint), source: source)
            }
        } else if let lastFeed {
            notice = "Couldn't refresh suggestions. Showing the last ones."
            phase = .loaded(lastFeed)
        } else {
            notice = nil
            phase = .failed("Check your connection and try again.")
        }
    }

    private func publish(_ feed: RecommendationFeed, seeds: [RecommendationSeed], excluded: Set<String>) {
        let feed = Self.filtered(feed, excluding: excluded)
        self.seeds = seeds
        lastFeed = feed
        phase = .loaded(feed)
    }

    // MARK: - TMDB

    private func buildTMDB(service: any TMDBService, seeds: [RecommendationSeed],
                           excluded: Set<String>) async -> (feed: RecommendationFeed, seeds: [RecommendationSeed])? {
        async let backdrops = Self.boundedMap(seeds, limit: 4) { seed in
            try? await service.backdrop(imdbID: seed.metaID, type: seed.type)
        }
        let results = await Self.boundedMap(seeds, limit: 4) { seed in
            try? await service.recommendations(imdbID: seed.metaID, type: seed.type, limit: 20)
        }
        let images = await backdrops
        guard results.contains(where: { $0 != nil }) else { return nil }
        var enriched = seeds
        for (i, image) in images.enumerated() where image != nil {
            enriched[i].background = image
        }
        let rows = Self.tmdbRows(seeds: enriched, results: results.map { $0 ?? [] }, excluded: excluded)
        guard !rows.isEmpty else { return nil }
        return (RecommendationFeed(source: .tmdb, rows: rows, generatedAt: now()), enriched)
    }

    /// "Top picks" (when at least two seeds contribute) followed by one "Because you watched" row per seed.
    nonisolated static func tmdbRows(seeds: [RecommendationSeed], results: [[MetaPreview]],
                                     excluded: Set<String>) -> [RecommendationRow] {
        let blocked = excluded.union(seeds.map(\.metaID))
        let lists = results.map { usable($0, excluding: blocked) }

        var score: [String: Double] = [:]
        var previews: [String: MetaPreview] = [:]
        for (seed, list) in zip(seeds, lists) {
            for (rank, item) in list.enumerated() {
                score[item.id, default: 0] += seed.weight * (1 - Double(rank) / Double(list.count * 2))
                if previews[item.id] == nil { previews[item.id] = item }
            }
        }

        var rows: [RecommendationRow] = []
        var appearances: [String: Int] = [:]
        let contributing = lists.filter { !$0.isEmpty }.count
        let picks = score.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(maxRowItems).compactMap { previews[$0.key] }
        if contributing >= 2, picks.count >= minRowItems {
            rows.append(RecommendationRow(id: "top", kind: .topPicks, title: "Top Picks for You", items: picks))
            for item in picks { appearances[item.id, default: 0] += 1 }
        }

        for (seed, list) in zip(seeds, lists) {
            let items = Array(list.filter { appearances[$0.id, default: 0] < maxAppearances }.prefix(maxRowItems))
            guard items.count >= minRowItems else { continue }
            for item in items { appearances[item.id, default: 0] += 1 }
            rows.append(RecommendationRow(id: "because-\(seed.metaID)", kind: .becauseYouWatched(seed),
                                          title: "Because you watched \(seed.name)", items: items))
        }
        return rows
    }

    // MARK: - Cinemeta

    private func buildCinemeta(seeds: [RecommendationSeed],
                               excluded: Set<String>) async -> (feed: RecommendationFeed, seeds: [RecommendationSeed])? {
        let fetchMeta = fetchMeta
        let fetchCatalog = fetchCatalog
        let metas = await Self.boundedMap(seeds, limit: 4) { seed in try? await fetchMeta(seed.type, seed.metaID) }
        guard !Task.isCancelled else { return nil }
        var enriched = seeds
        for (i, meta) in metas.enumerated() where enriched[i].background == nil {
            enriched[i].background = meta?.background
        }

        var keys = Self.rankedGenres(seeds: seeds, genres: metas.map { $0?.allGenres ?? [] }, limit: 8)
        if keys.isEmpty {
            var types: [String] = []
            for seed in seeds where !types.contains(seed.type) { types.append(seed.type) }
            keys = types.map { GenreKey(type: $0, genre: nil) }
        }
        let results = await Self.boundedMap(keys, limit: 5) { key in
            (try? await fetchCatalog(key.type, key.genre)) ?? []
        }
        let rows = Self.cinemetaRows(keys: keys, results: results, excluded: excluded.union(seeds.map(\.metaID)))
        guard !rows.isEmpty else { return nil }
        return (RecommendationFeed(source: .cinemeta, rows: rows, generatedAt: now()), enriched)
    }

    /// (type, genre) pairs ranked by the summed weight of the seeds that have them.
    nonisolated static func rankedGenres(seeds: [RecommendationSeed], genres: [[String]], limit: Int) -> [GenreKey] {
        var weights: [GenreKey: Double] = [:]
        for (seed, list) in zip(seeds, genres) {
            for genre in Set(list) where !genre.isEmpty {
                weights[GenreKey(type: seed.type, genre: genre), default: 0] += seed.weight
            }
        }
        return weights.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return ($0.key.type, $0.key.genre ?? "") < ($1.key.type, $1.key.genre ?? "")
        }.prefix(limit).map(\.key)
    }

    /// Up to `maxGenreRows` genre rows (in `keys` order) plus a "Top picks" row interleaving the best of each.
    nonisolated static func cinemetaRows(keys: [GenreKey], results: [[MetaPreview]],
                                         excluded: Set<String>) -> [RecommendationRow] {
        var genreRows: [RecommendationRow] = []
        var appearances: [String: Int] = [:]
        for (key, list) in zip(keys, results) where genreRows.count < maxGenreRows {
            let items = Array(usable(list, excluding: excluded)
                .filter { appearances[$0.id, default: 0] < maxAppearances }.prefix(maxRowItems))
            guard items.count >= minRowItems else { continue }
            for item in items { appearances[item.id, default: 0] += 1 }
            let label = typeLabel(key.type)
            let title = key.genre.map { "Top \($0) \(label)" } ?? "Popular \(label)"
            genreRows.append(RecommendationRow(id: "genre-\(key.type)-\(key.genre ?? "popular")",
                                               kind: .genre(name: key.genre ?? "Popular", type: key.type),
                                               title: title, items: items))
        }
        guard genreRows.count >= 2 else { return genreRows }

        var picks: [MetaPreview] = []
        var picked = Set<String>()
        let depth = 6
        for index in 0..<depth {
            for row in genreRows where index < row.items.count && picks.count < maxRowItems {
                let item = row.items[index]
                if picked.insert(item.id).inserted { picks.append(item) }
            }
        }
        return [RecommendationRow(id: "top", kind: .topPicks, title: "Top Picks for You", items: picks)] + genreRows
    }

    nonisolated static func typeLabel(_ type: String) -> String {
        switch type {
        case "movie": "Movies"
        case "series": "Series"
        default: type.capitalized
        }
    }

    /// Cinemeta's genre-filtered "top" catalog: the installed addon if present, else the public instance.
    static func cinemetaCatalogFetcher(registry: AddonRegistry) -> CatalogFetcher {
        let fallback = CinemetaFallback()
        return { type, genre in
            let cinemetaURL = Addon.normalizeManifestURL(AddonRegistry.cinemetaManifestURL)
            let installed = registry.addons.first {
                Addon.normalizeManifestURL($0.manifestURL) == cinemetaURL || $0.manifest.id == "com.linvo.cinemeta"
            }
            let addon = if let installed { installed } else { try await fallback.addon(client: registry.client) }
            guard let catalog = addon.manifest.catalogs.first(where: { $0.type == type && $0.id == "top" }) else {
                throw AddonError.notFound
            }
            if let genre, !catalog.genreOptions.isEmpty, !catalog.genreOptions.contains(genre) {
                throw AddonError.notFound
            }
            return try await registry.catalog(addon, catalog, genre: genre)
        }
    }

    // MARK: - Seeds

    /// Watched titles weighted by recency (30-day half-life) × engagement, deduped by metaID, best first.
    nonisolated static func computeSeeds(libraryItems: [StremioLibraryItem], progress: [ProgressStore.Entry],
                                         now: Date, limit: Int = seedLimit, ignoring: Set<String> = []) -> [RecommendationSeed] {
        var byID: [String: RecommendationSeed] = [:]
        func merge(_ seed: RecommendationSeed) {
            guard var existing = byID[seed.metaID] else { byID[seed.metaID] = seed; return }
            existing.weight = max(existing.weight, seed.weight)
            existing.lastWatched = max(existing.lastWatched, seed.lastWatched)
            if existing.poster == nil { existing.poster = seed.poster }
            if existing.background == nil { existing.background = seed.background }
            byID[seed.metaID] = existing
        }
        func recency(_ date: Date) -> Double {
            pow(0.5, max(0, now.timeIntervalSince(date)) / halfLife)
        }

        for item in libraryItems where isSeedCandidate(id: item.id, type: item.type) {
            let state = item.state
            guard let last = state.lastWatched, hasWatched(state) else { continue }
            var completion = 0.0
            if state.duration > 0 {
                completion = min(1, Double(max(state.overallTimeWatched, state.timeWatched)) / Double(state.duration))
            }
            if state.timesWatched > 0 || state.flaggedWatched > 0 { completion = 1 }
            if state.watched != nil { completion = max(completion, 0.5) }
            let engagement = 0.25 + completion + 0.25 * Double(min(state.timesWatched, 4))
            merge(RecommendationSeed(metaID: item.id, type: item.type, name: item.name, poster: remote(item.poster),
                                     background: nil, lastWatched: last, weight: engagement * recency(last)))
        }

        let groups = Dictionary(grouping: progress.filter { isSeedCandidate(id: $0.metaID, type: $0.metaType) },
                                by: \.metaID)
        for (metaID, entries) in groups {
            guard let latest = entries.max(by: { $0.updatedAt < $1.updatedAt }),
                  entries.contains(where: { $0.seconds > 0 }) else { continue }
            let completion = latest.metaType == "movie"
                ? entries.map(\.fraction).max() ?? 0
                : min(1, entries.map(\.fraction).reduce(0, +))
            let finished = entries.filter(\.isFinished).count
            let engagement = 0.25 + completion + 0.25 * Double(min(finished, 4))
            let poster = entries.lazy.compactMap { remote($0.posterURL) }.first
            let background = entries.lazy.compactMap { remote($0.backgroundURL) }.first
            merge(RecommendationSeed(metaID: metaID, type: latest.metaType, name: latest.title, poster: poster,
                                     background: background, lastWatched: latest.updatedAt,
                                     weight: engagement * recency(latest.updatedAt)))
        }

        return byID.values
            .filter { !ignoring.contains($0.metaID) }
            .sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.metaID < $1.metaID }
            .prefix(limit).map { $0 }
    }

    /// Titles never to suggest: anything watched or started, and everything in the Stremio library.
    nonisolated static func exclusions(libraryItems: [StremioLibraryItem], progress: [ProgressStore.Entry]) -> Set<String> {
        var ids = Set(progress.map(\.metaID))
        for item in libraryItems where (!item.removed && !item.temp) || hasWatched(item.state) {
            ids.insert(item.id)
        }
        return ids
    }

    nonisolated static func hasWatched(_ state: StremioLibraryItem.State) -> Bool {
        state.overallTimeWatched > 0 || state.timeWatched > 0 || state.timeOffset > 0
            || state.timesWatched > 0 || state.flaggedWatched > 0 || state.watched != nil
    }

    nonisolated private static func isSeedCandidate(id: String, type: String) -> Bool {
        id.hasPrefix("tt") && (type == "movie" || type == "series")
    }

    nonisolated private static func remote(_ url: String?) -> String? {
        guard let url, url.hasPrefix("http") else { return nil }
        return url
    }

    nonisolated static func fingerprint(_ seeds: [RecommendationSeed]) -> String {
        seeds.map(\.metaID).joined(separator: ",")
    }

    // MARK: - Helpers

    /// IMDb-id previews not in `excluded`, first occurrence only.
    nonisolated static func usable(_ items: [MetaPreview], excluding excluded: Set<String>) -> [MetaPreview] {
        var seen = Set<String>()
        return items.filter { $0.id.hasPrefix("tt") && !excluded.contains($0.id) && seen.insert($0.id).inserted }
    }

    nonisolated static func filtered(_ feed: RecommendationFeed, excluding excluded: Set<String>) -> RecommendationFeed {
        var feed = feed
        feed.rows = feed.rows.compactMap { row in
            var row = row
            row.items.removeAll { excluded.contains($0.id) }
            return row.items.isEmpty ? nil : row
        }
        return feed
    }

    /// Maps `items` with at most `limit` operations in flight, preserving order.
    nonisolated static func boundedMap<T: Sendable, R: Sendable>(
        _ items: [T], limit: Int, _ operation: @escaping @Sendable (T) async -> R
    ) async -> [R] {
        await withTaskGroup(of: (Int, R).self) { group in
            var results = [R?](repeating: nil, count: items.count)
            var next = 0
            while next < min(limit, items.count) {
                let i = next
                group.addTask { (i, await operation(items[i])) }
                next += 1
            }
            while let (i, value) = await group.next() {
                results[i] = value
                if next < items.count, !Task.isCancelled {
                    let j = next
                    group.addTask { (j, await operation(items[j])) }
                    next += 1
                }
            }
            return results.compactMap { $0 }
        }
    }

    // MARK: - Cache

    struct CachedFeed: Codable, Sendable {
        var feed: RecommendationFeed
        var seeds: [RecommendationSeed]
        /// Seed ids the feed was built from; a different set means the history changed.
        var fingerprint: String
    }

    private func cacheURL(_ source: RecommendationSource) -> URL {
        cacheDirectory.appendingPathComponent("suggestions-\(source.rawValue).json")
    }

    private func readCache(_ source: RecommendationSource) -> CachedFeed? {
        guard let data = try? Data(contentsOf: cacheURL(source)) else { return nil }
        return try? JSONDecoder().decode(CachedFeed.self, from: data)
    }

    private func writeCache(_ cached: CachedFeed, source: RecommendationSource) {
        guard let data = try? JSONEncoder().encode(cached) else { return }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cacheURL(source), options: .atomic)
    }
}

/// Cinemeta's manifest, fetched once when the addon isn't installed.
@MainActor
private final class CinemetaFallback {
    private var cached: Addon?

    func addon(client: AddonClient) async throws -> Addon {
        if let cached { return cached }
        let manifest = try await client.fetchManifest(from: AddonRegistry.cinemetaManifestURL)
        let addon = Addon(id: UUID(), manifestURL: AddonRegistry.cinemetaManifestURL, manifest: manifest,
                          enabled: true, order: 0)
        cached = addon
        return addon
    }
}
