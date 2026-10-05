#if DEBUG
import SwiftUI

/// Sample data for previews of the Suggestions page (the engine itself isn't needed).
enum RecommendationsSample {
    static func poster(_ id: String) -> String { "https://images.metahub.space/poster/medium/\(id)/img" }
    static func background(_ id: String) -> String { "https://images.metahub.space/background/medium/\(id)/img" }

    static let seeds: [RecommendationSeed] = [
        .init(metaID: "tt0903747", type: "series", name: "Breaking Bad", poster: poster("tt0903747"),
              background: background("tt0903747"), lastWatched: .now, weight: 1),
        .init(metaID: "tt1375666", type: "movie", name: "Inception", poster: poster("tt1375666"),
              background: background("tt1375666"), lastWatched: .now, weight: 0.8),
        .init(metaID: "tt0816692", type: "movie", name: "Interstellar", poster: poster("tt0816692"),
              background: nil, lastWatched: .now, weight: 0.6),
    ]

    static func items(_ ids: [(String, String, String)]) -> [MetaPreview] {
        ids.map { MetaPreview(id: $0.0, type: $0.2, name: $0.1, poster: poster($0.0), releaseInfo: "2010", imdbRating: "8.4") }
    }

    static let feed = RecommendationFeed(source: .tmdb, rows: [
        .init(id: "top", kind: .topPicks, title: "Top Picks for You", items: items([
            ("tt2306299", "Vikings", "series"), ("tt0468569", "The Dark Knight", "movie"),
            ("tt1856010", "House of Cards", "series"), ("tt0137523", "Fight Club", "movie"),
            ("tt0110912", "Pulp Fiction", "movie"), ("tt0944947", "Game of Thrones", "series"),
        ])),
        .init(id: "byw-tt0903747", kind: .becauseYouWatched(seeds[0]), title: "Because you watched Breaking Bad", items: items([
            ("tt3032476", "Better Call Saul", "series"), ("tt2085059", "Black Mirror", "series"),
            ("tt0306414", "The Wire", "series"), ("tt2356777", "True Detective", "series"),
        ])),
        .init(id: "genre-scifi", kind: .genre(name: "Sci-Fi", type: "movie"), title: "Top Sci-Fi Movies", items: items([
            ("tt0133093", "The Matrix", "movie"), ("tt1856101", "Blade Runner 2049", "movie"),
            ("tt0062622", "2001: A Space Odyssey", "movie"),
        ])),
    ], generatedAt: .now)

    static func state(feed: RecommendationFeed? = feed, loading: Bool = false, noHistory: Bool = false,
                      error: String? = nil, notice: String? = nil, tmdb: Bool = true) -> RecommendationsState {
        RecommendationsState(feed: feed, seeds: noHistory ? [] : seeds, isLoading: loading, isEmptyHistory: noHistory,
                             error: error, notice: notice, selectedSource: tmdb ? .tmdb : .cinemeta, tmdbAvailable: tmdb,
                             showsUpsell: !tmdb, isSignedIn: false)
    }
}

extension RecommendationsSample {
    /// Named sample states for the QA launch hooks.
    static func state(named name: String) -> RecommendationsState {
        var cinemetaFeed = feed
        cinemetaFeed.source = .cinemeta
        switch name {
        case "cinemeta": return state(feed: cinemetaFeed, tmdb: false)
        case "fallback":
            var fallback = state(feed: cinemetaFeed, notice: "TMDB couldn't be reached, so these suggestions come from Cinemeta.")
            fallback.selectedSource = .cinemeta
            return fallback
        case "loading": return state(feed: nil, loading: true, tmdb: false)
        case "nohistory": return state(feed: nil, noHistory: true, tmdb: false)
        case "failed": return state(feed: nil, error: "Check your connection and try again.")
        default: return state()
        }
    }
}

private struct PreviewHost: View {
    let state: RecommendationsState
    var body: some View {
        NavigationStack {
            RecommendationsContent(state: state, actions: .none)
                .navigationDestination(for: Route.self) { _ in Text("Detail") }
        }
    }
}

#Preview("Loaded (TMDB)") { PreviewHost(state: RecommendationsSample.state()) }

#Preview("Cinemeta + upsell, refreshing") {
    var feed = RecommendationsSample.feed
    feed.source = .cinemeta
    return PreviewHost(state: RecommendationsSample.state(feed: feed, loading: true, tmdb: false))
}

#Preview("TMDB fell back to Cinemeta") { PreviewHost(state: RecommendationsSample.state(named: "fallback")) }

#Preview("Loading") { PreviewHost(state: RecommendationsSample.state(feed: nil, loading: true)) }

#Preview("No history") { PreviewHost(state: RecommendationsSample.state(feed: nil, noHistory: true)) }

#Preview("Failed") {
    PreviewHost(state: RecommendationsSample.state(feed: nil, error: "The Internet connection appears to be offline."))
}
#endif
