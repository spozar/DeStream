import Foundation
import Observation

/// Identity of an addon in a collection: manifest id + normalized transport URL (configured variants differ by URL).
struct AddonSyncKey: Codable, Hashable, Sendable {
    var manifestID: String
    var url: String
}

extension Addon {
    var syncKey: AddonSyncKey { AddonSyncKey(manifestID: manifest.id, url: Addon.normalizeManifestURL(manifestURL)) }
}

extension StremioAddonDescriptor {
    var syncKey: AddonSyncKey { AddonSyncKey(manifestID: manifestID ?? "", url: Addon.normalizeManifestURL(transportUrl)) }
    var displayName: String { manifest["name"]?.stringValue ?? manifestID ?? "Addon" }
}

/// Network seam for the account's addon collection (tests inject a fake).
struct AddonCollectionAPI: Sendable {
    var fetch: @Sendable (_ authKey: String) async throws -> [StremioAddonDescriptor]
    var push: @Sendable (_ addons: [StremioAddonDescriptor], _ authKey: String) async throws -> Void

    static func live(_ api: StremioAPI) -> AddonCollectionAPI {
        AddonCollectionAPI(fetch: { try await api.addonCollection(authKey: $0) },
                           push: { try await api.setAddonCollection($0, authKey: $1) })
    }
}

/// Persists the last-synced snapshot. It contains transport URLs (secrets), so production uses the Keychain.
struct AddonSyncStore: Sendable {
    var load: @Sendable () -> Data?
    var save: @Sendable (Data?) -> Void

    static func keychain(key: String = "stremio.addonSync") -> AddonSyncStore {
        AddonSyncStore(load: { Keychain.get(key) },
                       save: { data in
                           if let data { try? Keychain.set(data, for: key) } else { Keychain.delete(key) }
                       })
    }
}

/// State after the last successful sync with `userID`'s account: the collection as pushed/pulled, and which of
/// its addons were installed locally. Supported addons in `remote` but not in `local` are ones the user removed
/// here that must stay on the account (protected), plus unsupported ones never installed here.
struct AddonSyncState: Codable, Sendable, Equatable {
    var userID: String
    var remote: [StremioAddonDescriptor]
    var local: [AddonSyncKey]
}

/// Two-way sync between `AddonRegistry` and the account's addon collection. OWNER: Stremio Agent 2 (Addon sync).
///
/// - The collection's array order is the user's addon order (as in Stremio); local order maps to it 1:1.
/// - Addons DeStream can't use (localhost transports such as Local Files, or no catalog/meta/stream/subtitles
///   resource) stay in the account untouched and in place, but aren't installed locally (`accountOnlyAddonNames`).
/// - Protected addons (e.g. Cinemeta) are never removed from the account; removing one here only hides it here.
/// - Enabled/disabled is local-only (Stremio has no such concept): disabled addons stay in the collection.
/// - Ongoing sync is a 3-way merge against the last-synced snapshot; local wins when both sides changed.
@MainActor @Observable
final class AddonSync {
    enum FirstSyncChoice: Sendable { case useAccount, keepThisDevice, merge }

    struct Credentials: Sendable {
        var userID: String
        var authKey: String
    }

    @ObservationIgnored let account: StremioAccount
    @ObservationIgnored let registry: AddonRegistry
    @ObservationIgnored private let api: AddonCollectionAPI
    @ObservationIgnored private let store: AddonSyncStore
    @ObservationIgnored private let credentials: @MainActor () -> Credentials?
    @ObservationIgnored private let fetchManifestJSON: @Sendable (String) async -> JSONValue?
    @ObservationIgnored private var inFlight: Task<Void, Error>?

    private var state: AddonSyncState?

    init(account: StremioAccount, registry: AddonRegistry,
         api: AddonCollectionAPI? = nil,
         store: AddonSyncStore = .keychain(),
         credentials: (@MainActor () -> Credentials?)? = nil,
         fetchManifestJSON: (@Sendable (String) async -> JSONValue?)? = nil) {
        self.account = account
        self.registry = registry
        self.api = api ?? .live(account.api)
        self.store = store
        self.credentials = credentials ?? { [account] in
            guard account.isSignedIn, let user = account.user, let key = account.authKey else { return nil }
            return Credentials(userID: user.id, authKey: key)
        }
        let session = registry.client.session
        self.fetchManifestJSON = fetchManifestJSON ?? { url in await Self.downloadManifestJSON(url, session: session) }
        state = store.load().flatMap { try? JSONDecoder().decode(AddonSyncState.self, from: $0) }
    }

    /// True right after sign-in, until the user picks how to combine this device's addons with the account's.
    var needsFirstSyncChoice: Bool {
        guard let creds = credentials() else { return false }
        return state?.userID != creds.userID
    }

    /// Names of the account's addons that aren't installed on this device (unsupported here, or protected ones
    /// removed here). Safe to show in UI.
    var accountOnlyAddonNames: [String] {
        guard let state, let creds = credentials(), state.userID == creds.userID else { return [] }
        let local = Set(state.local)
        return state.remote.filter { !local.contains($0.syncKey) }.map(\.displayName)
    }

    func performFirstSync(_ choice: FirstSyncChoice) async throws {
        try await serialized { try await self.runFirstSync(choice) }
    }

    /// Pull remote changes and push local ones. No-op when signed out or while the first-sync choice is pending.
    func sync() async throws {
        try await serialized { try await self.runSync() }
    }

    /// Forgets the snapshot, so the next sign-in asks for the first-sync choice again.
    func reset() {
        state = nil
        store.save(nil)
    }

    // MARK: - Running

    private func serialized(_ work: @escaping @MainActor @Sendable () async throws -> Void) async throws {
        let previous = inFlight
        let task = Task { @MainActor in
            _ = try? await previous?.value
            try await work()
        }
        inFlight = task
        defer { if inFlight == task { inFlight = nil } }
        try await task.value
    }

    private func runFirstSync(_ choice: FirstSyncChoice) async throws {
        guard let creds = credentials(), registry.storageError == nil else { return }
        let api = api
        let remote = try await call { try await api.fetch(creds.authKey) }
        guard credentials()?.userID == creds.userID else { return }
        let plan = Self.firstSyncPlan(choice, remote: remote, local: registry.addons)
        try await commit(plan, remote: remote, creds: creds)
    }

    private func runSync() async throws {
        guard let creds = credentials(), let base = state, base.userID == creds.userID,
              registry.storageError == nil else { return }
        let api = api
        let remote = try await call { try await api.fetch(creds.authKey) }
        guard credentials()?.userID == creds.userID else { return }
        let plan = Self.mergePlan(remote: remote, local: registry.addons, base: base)
        try await commit(plan, remote: remote, creds: creds)
    }

    /// Applies the local side first (no await between reading and writing the registry, so concurrent edits
    /// aren't clobbered), then pushes. Edits made during the push show up as local changes next time.
    private func commit(_ plan: Plan, remote: [StremioAddonDescriptor], creds: Credentials) async throws {
        if plan.local.map(\.syncKey) != registry.addons.map(\.syncKey) {
            registry.applySynced(plan.local)
        }
        var collection = plan.collection
        for i in collection.indices where plan.newKeys.contains(collection[i].syncKey) {
            if let raw = await fetchManifestJSON(collection[i].transportUrl),
               raw["id"]?.stringValue == collection[i].manifestID {
                collection[i].manifest = raw
            }
        }
        if collection != remote {
            let api = api, toPush = collection
            try await call { try await api.push(toPush, creds.authKey) }
        }
        let newState = AddonSyncState(userID: creds.userID, remote: collection, local: plan.local.map(\.syncKey))
        state = newState
        if let data = try? JSONEncoder().encode(newState) { store.save(data) }
    }

    private func call<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch StremioAPIError.unauthorized {
            account.handleUnauthorized()
            throw StremioAPIError.unauthorized
        }
    }

    // MARK: - Planning (pure)

    struct Plan {
        /// The account collection to push, in order.
        var collection: [StremioAddonDescriptor]
        /// The local addon list, in order.
        var local: [Addon]
        /// Collection entries created from local addons (their manifest JSON is re-fetched raw before pushing).
        var newKeys: Set<AddonSyncKey>
    }

    nonisolated static func firstSyncPlan(_ choice: FirstSyncChoice, remote: [StremioAddonDescriptor], local: [Addon]) -> Plan {
        let remote = dedupe(remote, key: \.syncKey)
        let local = dedupe(local, key: \.syncKey)
        let remoteKeys = remote.map(\.syncKey)
        let remoteSet = Set(remoteKeys)
        let localKeys = local.map(\.syncKey)
        switch choice {
        case .useAccount:
            return assemble(order: remoteKeys, remote: remote, local: local,
                            showLocally: { k in remote.first { $0.syncKey == k }.map(isSupported) ?? false })
        case .keepThisDevice:
            let kept = remote.filter { $0.flags.protected || !isSupported($0) }.map(\.syncKey)
            let order = interleave(localKeys, kept)
            let localSet = Set(localKeys)
            return assemble(order: order, remote: remote, local: local, showLocally: localSet.contains)
        case .merge:
            let order = remoteKeys + localKeys.filter { !remoteSet.contains($0) }
            let localSet = Set(localKeys)
            return assemble(order: order, remote: remote, local: local, showLocally: { k in
                localSet.contains(k) || (remote.first { $0.syncKey == k }.map(isSupported) ?? false)
            })
        }
    }

    /// 3-way merge of the current remote collection and local list against the last-synced snapshot.
    nonisolated static func mergePlan(remote: [StremioAddonDescriptor], local: [Addon], base: AddonSyncState) -> Plan {
        let remote = dedupe(remote, key: \.syncKey)
        let local = dedupe(local, key: \.syncKey)
        let remoteKeys = remote.map(\.syncKey)
        let localKeys = local.map(\.syncKey)
        let remoteSet = Set(remoteKeys), localSet = Set(localKeys)
        let baseRemote = Set(base.remote.map(\.syncKey)), baseLocal = Set(base.local)
        let remoteByKey = Dictionary(remote.map { ($0.syncKey, $0) }, uniquingKeysWith: { a, _ in a })

        // Remote entries survive unless removed here since the last sync (protected ones always survive).
        let keptRemote = remoteKeys.filter { k in
            localSet.contains(k) || !baseLocal.contains(k) || remoteByKey[k]!.flags.protected
        }
        // Local entries missing remotely were added here, unless the account removed them and they're unchanged here.
        let keptLocal = localKeys.filter { k in
            remoteSet.contains(k) || !(baseRemote.contains(k) && baseLocal.contains(k))
        }

        let common = localSet.intersection(baseLocal)
        let reorderedHere = localKeys.filter(common.contains) != base.local.filter(common.contains)
        let order = reorderedHere
            ? interleave(keptLocal, keptRemote)
            : interleave(keptRemote, keptLocal)

        return assemble(order: order, remote: remote, local: local, showLocally: { k in
            if localSet.contains(k) { return true }
            guard let d = remoteByKey[k] else { return false }
            return !baseRemote.contains(k) && !baseLocal.contains(k) && isSupported(d)
        })
    }

    private nonisolated static func assemble(order: [AddonSyncKey], remote: [StremioAddonDescriptor], local: [Addon],
                                             showLocally: (AddonSyncKey) -> Bool) -> Plan {
        let remoteByKey = Dictionary(remote.map { ($0.syncKey, $0) }, uniquingKeysWith: { a, _ in a })
        let localByKey = Dictionary(local.map { ($0.syncKey, $0) }, uniquingKeysWith: { a, _ in a })
        var collection: [StremioAddonDescriptor] = []
        var addons: [Addon] = []
        var newKeys: Set<AddonSyncKey> = []
        for k in order {
            if let d = remoteByKey[k] {
                collection.append(d)
            } else if let a = localByKey[k] {
                collection.append(descriptor(for: a))
                newKeys.insert(k)
            }
            guard showLocally(k) else { continue }
            if let a = localByKey[k] {
                addons.append(a)
            } else if let d = remoteByKey[k], let a = addon(from: d) {
                addons.append(a)
            }
        }
        for i in addons.indices { addons[i].order = i }
        return Plan(collection: collection, local: addons, newKeys: newKeys)
    }

    // MARK: - Mapping

    nonisolated static func descriptor(for addon: Addon, rawManifest: JSONValue? = nil) -> StremioAddonDescriptor {
        let json = rawManifest
            ?? (try? JSONEncoder().encode(addon.manifest)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            ?? .object(["id": .string(addon.manifest.id), "name": .string(addon.manifest.name),
                        "version": .string(addon.manifest.version)])
        let host = URL(string: addon.manifestURL)?.host?.lowercased() ?? ""
        let official = host == "strem.io" || host.hasSuffix(".strem.io")
        return StremioAddonDescriptor(
            transportUrl: addon.manifestURL, manifest: json,
            flags: .init(official: official, protected: official && addon.manifest.id == "com.linvo.cinemeta"))
    }

    nonisolated static func addon(from descriptor: StremioAddonDescriptor) -> Addon? {
        guard let manifest = manifest(from: descriptor.manifest) else { return nil }
        return Addon(id: UUID(), manifestURL: Addon.normalizeManifestURL(descriptor.transportUrl),
                     manifest: manifest, enabled: true, order: 0)
    }

    nonisolated static func manifest(from json: JSONValue) -> Manifest? {
        guard let data = try? JSONEncoder().encode(json),
              let m = try? JSONDecoder().decode(Manifest.self, from: data), !m.id.isEmpty else { return nil }
        return m
    }

    /// Whether DeStream can use this addon: a remote http(s) transport and a resource the app consumes.
    nonisolated static func isSupported(_ descriptor: StremioAddonDescriptor) -> Bool {
        guard let url = URL(string: Addon.normalizeManifestURL(descriptor.transportUrl)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !isLocalHost(host),
              let m = manifest(from: descriptor.manifest) else { return false }
        let usable: Set = ["catalog", "meta", "stream", "subtitles"]
        return !m.catalogs.isEmpty || m.resources.contains { usable.contains($0.name) }
    }

    private nonisolated static func isLocalHost(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return h == "localhost" || h == "::1" || h == "0.0.0.0" || h.hasPrefix("127.") || h.hasSuffix(".localhost")
    }

    // MARK: - Helpers

    /// `primary` order, with items only in `secondary` inserted right after their nearest preceding
    /// `secondary` neighbour (or at the front), so e.g. hidden account addons keep their place.
    nonisolated static func interleave<K: Hashable>(_ primary: [K], _ secondary: [K]) -> [K] {
        var result = primary
        var placed = Set(primary)
        var anchor: K?
        for k in secondary {
            if !placed.contains(k) {
                let i = anchor.flatMap { result.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
                result.insert(k, at: i)
                placed.insert(k)
            }
            anchor = k
        }
        return result
    }

    private nonisolated static func dedupe<T, K: Hashable>(_ items: [T], key: (T) -> K) -> [T] {
        var seen = Set<K>()
        return items.filter { seen.insert(key($0)).inserted }
    }

    private nonisolated static func downloadManifestJSON(_ urlString: String, session: URLSession) async -> JSONValue? {
        guard let url = URL(string: Addon.normalizeManifestURL(urlString)) else { return nil }
        let request = URLRequest(url: url, timeoutInterval: 10)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}
