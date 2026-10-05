import Foundation
import Observation

/// Where suggestions come from. TMDB needs a user-supplied API key; Cinemeta always works.
enum RecommendationSource: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case tmdb, cinemeta
    var id: String { rawValue }
}

/// A watched title that recommendations are based on. `metaID` is an IMDb id ("tt…").
struct RecommendationSeed: Codable, Hashable, Sendable, Identifiable {
    var metaID: String
    /// "movie" or "series".
    var type: String
    var name: String
    var poster: String?
    var background: String?
    var lastWatched: Date
    /// Relative importance (recency × completion); higher seeds get earlier rows.
    var weight: Double

    var id: String { metaID }
}

struct RecommendationRow: Codable, Hashable, Sendable, Identifiable {
    enum Kind: Codable, Hashable, Sendable {
        /// "Because you watched <seed.name>".
        case becauseYouWatched(RecommendationSeed)
        /// "Top <genre> <movies|series>" – used by the Cinemeta source.
        case genre(name: String, type: String)
        /// Mixed "Top picks for you" row aggregated across all seeds.
        case topPicks
    }

    var id: String
    var kind: Kind
    var title: String
    /// IMDb-id previews so `Route.detail` and playback work unchanged.
    var items: [MetaPreview]
}

struct RecommendationFeed: Codable, Hashable, Sendable {
    var source: RecommendationSource
    var rows: [RecommendationRow]
    var generatedAt: Date
}

/// Network seam for TMDB (tests inject a fake). Implemented by `TMDBClient`.
protocol TMDBService: Sendable {
    /// Recommended titles for an IMDb id, already mapped back to IMDb-id previews (unmappable ones dropped).
    func recommendations(imdbID: String, type: String, limit: Int) async throws -> [MetaPreview]
    /// Backdrop image URL for an IMDb id, if TMDB has one.
    func backdrop(imdbID: String, type: String) async throws -> String?
}
