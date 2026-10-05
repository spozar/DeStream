import Foundation
import Observation

/// Optional Stremio account session; the app works fully without one. OWNER: Stremio Agent 1 (API).
/// The auth key lives in the Keychain; the (non-secret) user profile is cached in UserDefaults.
@MainActor @Observable
final class StremioAccount {
    private(set) var user: StremioUser?
    var isSignedIn: Bool { user != nil && authKey != nil }
    /// True after the server rejected the session and signed this device out, until the next sign-in or sign-out.
    private(set) var sessionExpired = false
    @ObservationIgnored let api: StremioAPI
    /// Secret; Keychain only.
    @ObservationIgnored private(set) var authKey: String?
    @ObservationIgnored private let keychainKey: String
    @ObservationIgnored private let defaults: UserDefaults
    private var userDefaultsKey: String { "\(keychainKey).user" }

    init(api: StremioAPI = StremioAPI(), keychainKey: String = "stremio.auth", defaults: UserDefaults = .standard) {
        self.api = api
        self.keychainKey = keychainKey
        self.defaults = defaults
        authKey = try? Keychain.readString(keychainKey)
        if authKey != nil, let data = defaults.data(forKey: userDefaultsKey) {
            user = try? JSONDecoder().decode(StremioUser.self, from: data)
        }
        if authKey != nil, user == nil {
            Task { try? await self.refreshUser() }
        }
    }

    func login(email: String, password: String) async throws {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let (key, user) = try await api.login(email: email, password: password)
        try Keychain.setString(key, for: keychainKey)
        authKey = key
        sessionExpired = false
        setUser(user)
    }

    /// Re-fetches the profile; signs out locally if the session has expired.
    func refreshUser() async throws {
        guard let authKey else { return }
        do {
            let fresh = try await api.getUser(authKey: authKey)
            guard self.authKey == authKey else { return }
            setUser(fresh)
        } catch StremioAPIError.unauthorized {
            if self.authKey == authKey { handleUnauthorized() }
            throw StremioAPIError.unauthorized
        }
    }

    /// Signs out on the server (best effort) and clears the local session.
    func logout() async {
        let key = authKey
        sessionExpired = false
        clearSession()
        if let key { try? await api.logout(authKey: key) }
    }

    /// Called by sync code when the server rejects the auth key.
    func handleUnauthorized() {
        if authKey != nil { sessionExpired = true }
        clearSession()
    }

    private func setUser(_ user: StremioUser) {
        self.user = user
        if let data = try? JSONEncoder().encode(user) { defaults.set(data, forKey: userDefaultsKey) }
    }

    private func clearSession() {
        Keychain.delete(keychainKey)
        defaults.removeObject(forKey: userDefaultsKey)
        authKey = nil
        user = nil
    }
}
