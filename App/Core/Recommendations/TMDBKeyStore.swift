import Foundation
import Observation

/// Owns the TMDB API key (Keychain only, never logged). OWNER: Rec Agent 1 (TMDB).
@MainActor @Observable
final class TMDBKeyStore {
    static let keychainKey = "tmdbAPIKey"

    /// True when a key is stored. Observable so Settings and the Suggestions source picker update live.
    private(set) var hasKey: Bool = false

    @ObservationIgnored private let session: URLSession

    init() {
        self.session = TMDBClient.defaultSession
        hasKey = Self.storedKey() != nil
    }

    /// Validates the key against TMDB, then stores it. Accepts a v3 API key or a v4 read access token.
    func save(_ key: String) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TMDBError.invalidKey }
        try await TMDBClient(key: trimmed, session: session).validate()
        try Keychain.setString(trimmed, for: Self.keychainKey)
        hasKey = true
        Task { await TMDBRecommendationCache.shared.removeAll() }
    }

    func remove() {
        Keychain.delete(Self.keychainKey)
        hasKey = false
        Task { await TMDBRecommendationCache.shared.removeAll() }
    }

    /// A client for the stored key, or nil when none is set.
    func makeService() -> (any TMDBService)? {
        Self.storedKey().map { TMDBClient(key: $0, session: session) }
    }

    private static func storedKey() -> String? {
        guard let key = try? Keychain.readString(keychainKey), !key.isEmpty else { return nil }
        return key
    }
}
