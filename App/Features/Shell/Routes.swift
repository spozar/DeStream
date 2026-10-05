import SwiftUI

/// Navigation values pushed onto any NavigationStack. RootView registers destinations for all of them.
enum Route: Hashable {
    case detail(MetaPreview)
    case saved(titleID: String)
    case discover(DiscoverSeed)
    /// A whole section pushed as a page (the iPhone "Library" hub).
    case section(AppSection)
    case watchHistory
}

/// Initial Discover filters; nil fields fall back to the first available option.
struct DiscoverSeed: Hashable, Sendable {
    var type: String?
    /// `CatalogRef.selectionKey`.
    var catalogKey: String?
    var genre: String?

    init(type: String? = nil, catalogKey: String? = nil, genre: String? = nil) {
        self.type = type
        self.catalogKey = catalogKey
        self.genre = genre
    }
}

/// Environment action that starts playback: a separate window on macOS, full-screen cover on iOS.
struct PlayAction {
    var handler: @MainActor (PlaybackRequest) -> Void
    @MainActor func callAsFunction(_ request: PlaybackRequest) { handler(request) }
}

extension EnvironmentValues {
    @Entry var play = PlayAction { _ in }
}
