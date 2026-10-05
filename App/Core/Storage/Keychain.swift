import Foundation
import Security

/// Generic-password Keychain wrapper. OWNER: Agent 1 (Core).
/// Uses the legacy file keychain on macOS (no `kSecUseDataProtectionKeychain`), which works for
/// unsandboxed, ad-hoc signed builds without a keychain-access-groups entitlement.
enum Keychain {
    static let service = "se.mediaempire.DeStream"

    struct Failure: LocalizedError, Sendable {
        var status: OSStatus
        var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "Keychain error \(status): \(message)"
        }
    }

    static func set(_ data: Data, for key: String) throws {
        let query = baseQuery(key)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(update) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    static func get(_ key: String) -> Data? {
        try? read(key)
    }

    /// Like `get`, but distinguishes "no item" (nil) from "item exists but couldn't be read" (throws),
    /// e.g. when the user denies the macOS access prompt that appears after an ad-hoc rebuild.
    static func read(_ key: String) throws -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        return result as? Data
    }

    static func setString(_ value: String, for key: String) throws {
        try set(Data(value.utf8), for: key)
    }

    static func readString(_ key: String) throws -> String? {
        try read(key).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func delete(_ key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }

    private static func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
