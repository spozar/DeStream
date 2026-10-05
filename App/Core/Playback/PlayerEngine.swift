import Foundation

/// An audio or subtitle track exposed by an engine.
struct PlayerTrack: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case audio, subtitle }
    var id: Int
    var kind: Kind
    var title: String?
    var language: String?
    var codec: String?
    var channels: String?
    var isDefault: Bool = false
    var isForced: Bool = false
    var isExternal: Bool = false
    var isSelected: Bool = false

    var displayName: String {
        var parts: [String] = []
        if let language, !language.isEmpty {
            parts.append(LanguageCodes.displayName(language))
        }
        if let title, !title.isEmpty, title.lowercased() != language?.lowercased() { parts.append(title) }
        var detail: [String] = []
        if let codec, !codec.isEmpty { detail.append(codec.uppercased()) }
        if let channels, !channels.isEmpty { detail.append(channels) }
        if isForced { detail.append("Forced") }
        if parts.isEmpty { parts.append("Track \(id)") }
        return detail.isEmpty ? parts.joined(separator: " – ") : parts.joined(separator: " – ") + " (" + detail.joined(separator: ", ") + ")"
    }
}

/// A chapter marker in the file (MKV/MP4 chapters), used to find where the end credits start.
struct PlayerChapter: Hashable, Sendable {
    var title: String?
    /// Seconds from the start.
    var time: Double
}

enum PlayerEngineKind: String, Sendable { case mpv, avPlayer }

/// A readable playback failure. Never contains the stream URL (it may embed secrets).
struct PlaybackFailure: Error, Hashable, Sendable {
    var title: String
    var message: String

    static let unplayable = PlaybackFailure(
        title: "This stream can't be played",
        message: "The source didn't return a playable video. It may not be cached on your debrid service yet, or the connection failed. Try another stream."
    )
    static let network = PlaybackFailure(
        title: "Connection problem",
        message: "The stream couldn't be loaded. Check your connection and try again, or pick another stream."
    )
    static let unsupportedFormat = PlaybackFailure(
        title: "Format not supported",
        message: "This file needs the mpv engine, which couldn't be started. Try an MP4 stream instead."
    )
    static let fileMissing = PlaybackFailure(
        title: "File not found",
        message: "The saved file is missing or unavailable. If your library is on an external drive, make sure it's connected."
    )
}

/// Common interface of the mpv and AVPlayer engines. All state is observable.
@MainActor
protocol PlayerEngine: AnyObject {
    var kind: PlayerEngineKind { get }
    /// Seconds.
    var currentTime: Double { get }
    var duration: Double? { get }
    var isPaused: Bool { get }
    /// Waiting for network data (also true while the file is opening).
    var isBuffering: Bool { get }
    /// True once the file is opened and duration/tracks are known.
    var isLoaded: Bool { get }
    var reachedEnd: Bool { get }
    /// Absolute position (seconds) up to which data is buffered ahead, if known.
    var bufferedUntil: Double? { get }
    var audioTracks: [PlayerTrack] { get }
    var subtitleTracks: [PlayerTrack] { get }
    var selectedAudioTrackID: Int? { get }
    var selectedSubtitleTrackID: Int? { get }
    /// 0...100
    var volume: Double { get }
    var isMuted: Bool { get }
    var speed: Double { get }
    var failure: PlaybackFailure? { get }
    /// Applied to the tracks of the next `load` until the user picks a track.
    var trackPreferences: TrackPreferences { get set }
    var supportsExternalSubtitles: Bool { get }
    var chapters: [PlayerChapter] { get }
    /// Seconds the subtitles are shifted; positive shows them later.
    var subtitleDelay: Double { get }
    var supportsSubtitleDelay: Bool { get }

    func load(_ url: URL, startAt seconds: Double?)
    func play()
    func pause()
    func seek(to seconds: Double)
    func seek(by delta: Double)
    func selectAudioTrack(_ id: Int?)
    func selectSubtitleTrack(_ id: Int?)
    /// Adds subtitle files as selectable tracks; they survive a reload of the same request.
    func addExternalSubtitles(_ subtitles: [ExternalSubtitle])
    func setVolume(_ volume: Double)
    func setMuted(_ muted: Bool)
    func setSpeed(_ speed: Double)
    func setSubtitleDelay(_ seconds: Double)
    /// Stops playback and releases all resources. The engine is unusable afterwards.
    func shutdown()
}

extension PlayerEngine {
    func togglePause() { isPaused ? play() : pause() }

    var chapters: [PlayerChapter] { [] }
    var subtitleDelay: Double { 0 }
    var supportsSubtitleDelay: Bool { false }
    func setSubtitleDelay(_ seconds: Double) {}
}

@MainActor
enum PlayerEngineFactory {
    static let avFriendlyExtensions: Set<String> = ["mp4", "m4v", "mov", "m3u8"]

    static func fileExtension(for request: PlaybackRequest) -> String {
        let hint = (request.filenameHint as NSString?)?.pathExtension ?? ""
        return (hint.isEmpty ? request.url.pathExtension : hint).lowercased()
    }

    /// mpv by default; AVPlayer for MP4/HLS when mpv isn't preferred, or when mpv fails to start.
    static func makeEngine(for request: PlaybackRequest, preferMPV: Bool) -> (engine: any PlayerEngine, failure: PlaybackFailure?) {
        let avFriendly = avFriendlyExtensions.contains(fileExtension(for: request))
        if !preferMPV && avFriendly { return (AVPlayerController(), nil) }
        if let mpv = MPVPlayerController() { return (mpv, nil) }
        let avIncompatible: Set<String> = ["mkv", "avi", "webm", "wmv", "flv", "ts"]
        return (AVPlayerController(), avIncompatible.contains(fileExtension(for: request)) ? .unsupportedFormat : nil)
    }
}
