import Foundation
import Observation

/// Where the addon list is persisted. The blob contains manifest URLs (secrets), so production uses the Keychain.
struct AddonStore: Sendable {
    /// nil = nothing saved yet; throws if a saved list exists but can't be read.
    var load: @Sendable () throws -> Data?
    var save: @Sendable (Data) throws -> Void
    /// Default manifest URLs still to install after a failed first-install attempt (nil = none tracked).
    var loadPendingDefaults: @Sendable () -> [String]? = { nil }
    var savePendingDefaults: @Sendable ([String]) -> Void = { _ in }

    static func keychain(key: String = "addons") -> AddonStore {
        let pendingKey = key + ".pendingDefaults"
        return AddonStore(
            load: { try Keychain.read(key) },
            save: { try Keychain.set($0, for: key) },
            loadPendingDefaults: { (try? Keychain.read(pendingKey)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } },
            savePendingDefaults: { urls in
                if urls.isEmpty { Keychain.delete(pendingKey) }
                else if let data = try? JSONEncoder().encode(urls) { try? Keychain.set(data, for: pendingKey) }
            })
    }
}

/// A no-config addon offered in Settings. `manifestID` identifies it once installed (configured variants share it).
struct RecommendedAddon: Identifiable, Hashable, Sendable {
    let manifestID: String
    let name: String
    let summary: String
    let manifestURL: String
    let systemImage: String
    var id: String { manifestID }
}

/// The only component that talks to addons. Persists addon URLs in the Keychain. OWNER: Agent 1 (Core).
@MainActor @Observable
final class AddonRegistry {
    nonisolated static let cinemetaManifestURL = "https://v3-cinemeta.strem.io/manifest.json"
    nonisolated static let streamingCatalogsManifestURL = "https://7a82163c306e-stremio-netflix-catalog-addon.baby-beamup.club/manifest.json"
    nonisolated static let animeKitsuManifestURL = "https://anime-kitsu.strem.fun/manifest.json"
    nonisolated static let openSubtitlesManifestURL = "https://opensubtitles-v3.strem.io/manifest.json"

    /// Catalog, metadata and subtitle addons that need no account or key and use IDs Comet resolves (IMDb `tt`, `kitsu`).
    nonisolated static let recommended: [RecommendedAddon] = [
        RecommendedAddon(manifestID: "com.linvo.cinemeta", name: "Cinemeta",
                         summary: "Stremio's official catalog: popular, new and featured movies and series, with metadata and search.",
                         manifestURL: cinemetaManifestURL, systemImage: "film.stack"),
        RecommendedAddon(manifestID: "pw.ers.netflix-catalog", name: "Streaming Catalogs",
                         summary: "What's trending on Netflix, HBO Max, Disney+, Prime Video and Apple TV+.",
                         manifestURL: streamingCatalogsManifestURL, systemImage: "rectangle.stack.fill"),
        RecommendedAddon(manifestID: "org.stremio.opensubtitlesv3", name: "OpenSubtitles v3",
                         summary: "Stremio's official subtitles addon: subtitles in many languages for movies and series.",
                         manifestURL: openSubtitlesManifestURL, systemImage: "captions.bubble.fill"),
        RecommendedAddon(manifestID: "community.anime.kitsu", name: "Anime Kitsu",
                         summary: "Anime catalogs (trending, airing, top rated) with genres, metadata and search.",
                         manifestURL: animeKitsuManifestURL, systemImage: "sparkles.tv"),
    ]

    /// Installed on a fresh install only.
    nonisolated static let defaultManifestURLs = [cinemetaManifestURL, streamingCatalogsManifestURL, openSubtitlesManifestURL]

    /// Sorted by `order`.
    private(set) var addons: [Addon] = []
    let client: AddonClient
    @ObservationIgnored private let store: AddonStore
    @ObservationIgnored private let defaultManifestURLs: [String]
    /// True once a list has been persisted; defaults are only installed before that (so removing a default sticks).
    @ObservationIgnored private var hasSavedList = false
    /// Defaults from the first install that haven't been installed yet; retried on each refresh until they are.
    @ObservationIgnored private var pendingDefaults: [String]?

    /// Called after a user edit that changes the synced collection (add, remove, move; not enable/disable,
    /// which is local-only). `SyncCoordinator` points it at `scheduleSync()`. Not called by `applySynced`.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    /// Per-addon overall budget for `streams(type:id:)`.
    var streamTimeout: TimeInterval = 15

    /// Set when the saved addon list exists but couldn't be read (e.g. Keychain access denied).
    /// While set, nothing is persisted so the saved list isn't overwritten. Safe to show in UI.
    private(set) var storageError: String?

    init(client: AddonClient = AddonClient(), store: AddonStore = .keychain(),
         defaultManifestURLs: [String] = AddonRegistry.defaultManifestURLs) {
        self.client = client
        self.store = store
        self.defaultManifestURLs = defaultManifestURLs
        loadFromStore()
    }

    /// Re-reads the persisted list. Called on init and again by `refreshManifests` if the first read failed.
    func loadFromStore() {
        do {
            pendingDefaults = store.loadPendingDefaults()
            guard let data = try store.load() else { return }
            hasSavedList = true
            storageError = nil
            if let saved = try? JSONDecoder().decode([Addon].self, from: data) {
                addons = saved.sorted { $0.order < $1.order }
            }
        } catch {
            hasSavedList = true
            storageError = "Saved addons couldn't be read from the Keychain (\(error.localizedDescription))."
        }
    }

    /// Recommended addons not installed yet (matched by manifest id, so a configured variant counts as installed).
    var recommendedNotInstalled: [RecommendedAddon] {
        let installed = Set(addons.map(\.manifest.id))
        return Self.recommended.filter { !installed.contains($0.manifestID) }
    }

    var enabledAddons: [Addon] { addons.filter(\.enabled).sorted { $0.order < $1.order } }

    // MARK: - Management

    /// Fetches and validates the manifest, then installs it at the end of the list.
    /// Accepts `stremio://` links and `…/configure` pages. Throws `AddonError.duplicate` if already installed.
    @discardableResult
    func add(manifestURL: String) async throws -> Addon {
        let url = Addon.normalizeManifestURL(manifestURL)
        if let existing = addons.first(where: { Addon.normalizeManifestURL($0.manifestURL) == url }) {
            throw AddonError.duplicate(addon: existing.manifest.name)
        }
        let manifest = try await client.fetchManifest(from: url)
        // Re-checked after the await: a concurrent add (e.g. first-launch defaults) may have installed it meanwhile.
        if addons.contains(where: { Addon.normalizeManifestURL($0.manifestURL) == url }) {
            throw AddonError.duplicate(addon: manifest.name)
        }
        let addon = Addon(id: UUID(), manifestURL: url, manifest: manifest, enabled: true,
                          order: (addons.map(\.order).max() ?? -1) + 1)
        addons.append(addon)
        persist()
        onChange?()
        return addon
    }

    func remove(_ addon: Addon) {
        addons.removeAll { $0.id == addon.id }
        renumber()
        persist()
        onChange?()
    }

    /// Same semantics as SwiftUI's `move(fromOffsets:toOffset:)` on `addons`.
    func move(fromOffsets: IndexSet, toOffset: Int) {
        let moving = fromOffsets.filter { addons.indices.contains($0) }.map { addons[$0] }
        guard !moving.isEmpty else { return }
        let insertAt = toOffset - fromOffsets.filter { $0 < toOffset }.count
        var rest = addons.enumerated().filter { !fromOffsets.contains($0.offset) }.map(\.element)
        rest.insert(contentsOf: moving, at: max(0, min(insertAt, rest.count)))
        addons = rest
        renumber()
        persist()
        onChange?()
    }

    /// Replaces the list with one produced by account sync (in the given order). Doesn't fire `onChange`,
    /// and stops installing first-launch defaults: the account's list is authoritative from here on.
    func applySynced(_ newAddons: [Addon]) {
        guard storageError == nil else { return }
        addons = newAddons
        renumber()
        pendingDefaults = []
        store.savePendingDefaults([])
        persist()
    }

    func setEnabled(_ addon: Addon, _ enabled: Bool) {
        guard let i = addons.firstIndex(where: { $0.id == addon.id }) else { return }
        addons[i].enabled = enabled
        persist()
    }

    /// Installs default addons on first launch, then re-fetches all manifests in parallel.
    /// Failures keep the cached manifest, so this is safe offline.
    func refreshManifests() async {
        if storageError != nil { loadFromStore() }
        await installDefaultsIfNeeded()
        let client = client
        let snapshot = addons
        let fresh = await withTaskGroup(of: (UUID, Manifest?).self) { group in
            for addon in snapshot {
                group.addTask { (addon.id, try? await client.fetchManifest(from: addon.manifestURL)) }
            }
            var result: [UUID: Manifest] = [:]
            for await (id, manifest) in group { if let manifest { result[id] = manifest } }
            return result
        }
        var changed = false
        for i in addons.indices {
            if let m = fresh[addons[i].id], m != addons[i].manifest {
                addons[i].manifest = m
                changed = true
            }
        }
        if changed { persist() }
    }

    /// On a fresh install, installs the defaults. Any that fail (e.g. offline) stay pending and are retried on
    /// later refreshes, but only until installed once: removing a default afterwards sticks.
    func installDefaultsIfNeeded() async {
        guard storageError == nil else { return }
        if pendingDefaults == nil, !hasSavedList, addons.isEmpty {
            pendingDefaults = defaultManifestURLs
        }
        guard let pending = pendingDefaults, !pending.isEmpty else { return }
        var stillPending: [String] = []
        for url in pending where !isInstalled(defaultURL: url) {
            do {
                try await add(manifestURL: url)
            } catch AddonError.duplicate {
            } catch {
                stillPending.append(url)
            }
        }
        pendingDefaults = stillPending
        // Nothing worked and nothing is saved: stay a fresh install so the next launch tries everything again.
        if hasSavedList { store.savePendingDefaults(stillPending) }
    }

    /// Same URL, or (for a recommended addon) any installed variant with its manifest id, e.g. a configured one.
    private func isInstalled(defaultURL url: String) -> Bool {
        let normalized = Addon.normalizeManifestURL(url)
        let manifestID = Self.recommended.first { $0.manifestURL == url }?.manifestID
        return addons.contains { Addon.normalizeManifestURL($0.manifestURL) == normalized || $0.manifest.id == manifestID }
    }

    // MARK: - Resource selection

    /// Enabled addons serving `resource` for `type` (and `id` prefix, if given), in user order.
    func addons(for resource: String, type: String, id: String? = nil) -> [Addon] {
        enabledAddons.filter { $0.manifest.supports(resource: resource, type: type, id: id) }
    }

    /// (addon, catalog) pairs usable as home rows (no required extras).
    var homeCatalogs: [(addon: Addon, catalog: ManifestCatalog)] {
        enabledAddons.flatMap { addon in
            addon.manifest.catalogs.filter { $0.requiredExtras.isEmpty }.map { (addon: addon, catalog: $0) }
        }
    }

    /// (addon, catalog) pairs supporting `search` (and requiring nothing else).
    var searchCatalogs: [(addon: Addon, catalog: ManifestCatalog)] {
        enabledAddons.flatMap { addon in
            addon.manifest.catalogs
                .filter { $0.supportsSearch && $0.requiredExtras.allSatisfy { $0 == "search" } }
                .map { (addon: addon, catalog: $0) }
        }
    }

    // MARK: - Fetching

    func catalog(_ addon: Addon, _ catalog: ManifestCatalog, skip: Int? = nil, search: String? = nil, genre: String? = nil) async throws -> [MetaPreview] {
        try await client.catalog(addon, type: catalog.type, id: catalog.id, search: search, skip: skip, genre: genre)
    }

    /// First meta addon (in user order) that returns a result wins.
    func meta(type: String, id: String) async throws -> MetaDetail {
        var lastError: Error = AddonError.notFound
        for addon in addons(for: "meta", type: type, id: id) {
            do {
                return try await client.meta(addon, type: type, id: id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Queries all stream addons in parallel (each with a `streamTimeout` budget), merges them in addon
    /// order with cached streams first within each addon. Per-addon failures are reported in `errors`.
    func streams(type: String, id: String) async -> (streams: [AddonStream], errors: [String]) {
        let sources = addons(for: "stream", type: type, id: id)
        let client = client
        let budget = streamTimeout
        let results = await withTaskGroup(of: (Int, Result<[Stream], Error>).self) { group in
            for (i, addon) in sources.enumerated() {
                group.addTask {
                    do {
                        let streams = try await withTimeout(budget, label: addon.redactedURL) {
                            try await client.streams(addon, type: type, id: id)
                        }
                        return (i, .success(streams))
                    } catch {
                        return (i, .failure(error))
                    }
                }
            }
            var out: [Int: Result<[Stream], Error>] = [:]
            for await (i, r) in group { out[i] = r }
            return out
        }
        var merged: [AddonStream] = []
        var errors: [String] = []
        for (i, addon) in sources.enumerated() {
            switch results[i] {
            case .success(let streams):
                merged += Self.orderCachedFirst(streams).enumerated().map { j, s in
                    AddonStream(id: "\(addon.id.uuidString)-\(j)", addonName: addon.manifest.name, addonID: addon.id.uuidString, stream: s)
                }
            case .failure(let error):
                errors.append(Self.describe(error, addon: addon))
            case nil:
                break
            }
        }
        return (merged, errors)
    }

    /// Stable partition: cached streams first, otherwise keeping the addon's ranking.
    nonisolated static func orderCachedFirst(_ streams: [Stream]) -> [Stream] {
        streams.filter(\.isCached) + streams.filter { !$0.isCached }
    }

    private static func describe(_ error: Error, addon: Addon) -> String {
        // The addon is already named, so drop the redacted URL the AddonError descriptions start with.
        let reason = switch error {
        case AddonError.http(let status, _): "returned HTTP \(status)"
        case AddonError.network(_, let e): "couldn't be reached (\(e))"
        case AddonError.decoding: "sent an unexpected response"
        case AddonError.addon(_, let message): "reported an error: \(message)"
        case AddonError.timedOut: "timed out"
        case AddonError.notFound: "found nothing"
        case let e as AddonError: e.errorDescription ?? "failed"
        case is CancellationError: "cancelled"
        default: "request failed"
        }
        return "\(addon.manifest.name): \(reason)"
    }

    /// Looks up the installed addon an `AddonStream` came from.
    func addon(withID id: String) -> Addon? {
        addons.first { $0.id.uuidString == id }
    }

    // MARK: - Persistence

    private func renumber() {
        for i in addons.indices { addons[i].order = i }
    }

    private func persist() {
        guard storageError == nil, let data = try? JSONEncoder().encode(addons) else { return }
        do {
            try store.save(data)
            hasSavedList = true
        } catch {
            print("AddonRegistry: failed to save addons: \(error.localizedDescription)")
        }
    }
}

/// Runs `operation`, throwing `AddonError.timedOut` if it doesn't finish within `seconds`.
func withTimeout<T: Sendable>(_ seconds: TimeInterval, label: String, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw AddonError.timedOut(addon: label)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw AddonError.timedOut(addon: label) }
        return first
    }
}
