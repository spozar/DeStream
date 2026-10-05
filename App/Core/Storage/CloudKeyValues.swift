import Foundation

/// Small values mirrored to iCloud key-value storage so they follow the user across devices (last write wins per key).
/// Without iCloud (signed out, or a build without the entitlement) writes stay local and nothing arrives.
@MainActor
final class CloudKeyValues {
    static let shared = CloudKeyValues()

    private let store = NSUbiquitousKeyValueStore.default
    private var handlers: [String: @MainActor () -> Void] = [:]

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main
        ) { [weak self] note in
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            MainActor.assumeIsolated { self?.changed(keys) }
        }
        store.synchronize()
    }

    func strings(forKey key: String) -> [String]? { store.array(forKey: key) as? [String] }

    func set(_ strings: [String], forKey key: String) { store.set(strings, forKey: key) }

    /// Called on the main actor whenever another device changes `key`.
    func observe(_ key: String, _ handler: @escaping @MainActor () -> Void) { handlers[key] = handler }

    private func changed(_ keys: [String]) {
        for key in keys { handlers[key]?() }
    }
}
