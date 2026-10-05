import Foundation

/// Everything the player needs. Codable+Hashable so macOS can open it in its own window via openWindow(value:).
struct PlaybackRequest: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var url: URL
    var title: String
    var subtitle: String?
    var metaID: String
    var metaType: String
    var videoId: String
    var isLocal: Bool
    var filenameHint: String?
    var posterURL: String?
    /// Next episode, for auto-play/binge (stretch).
    var bingeGroup: String?
    /// Backdrop image (remote or file URL string), used for Continue Watching cards.
    var backgroundURL: String? = nil
    /// Explicit start position in seconds; skips the resume prompt (0 = start over).
    var startAt: Double? = nil
    /// True for throwaway playback (debug launches) that must not touch watch history. Optional so older encoded requests decode.
    var skipsHistory: Bool? = nil
}
