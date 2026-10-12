import AVFoundation
import Foundation
import Observation

/// AVPlayer engine for MP4/MOV/HLS (and the fallback when mpv can't start).
@MainActor @Observable
final class AVPlayerController: PlayerEngine {
    let kind = PlayerEngineKind.avPlayer
    private(set) var currentTime: Double = 0
    private(set) var duration: Double?
    private(set) var isPaused = false
    private(set) var isBuffering = false
    private(set) var isLoaded = false
    private(set) var reachedEnd = false
    private(set) var bufferedUntil: Double?
    private(set) var audioTracks: [PlayerTrack] = []
    private(set) var subtitleTracks: [PlayerTrack] = []
    private(set) var selectedAudioTrackID: Int?
    private(set) var selectedSubtitleTrackID: Int?
    private(set) var volume: Double = 100
    private(set) var isMuted = false
    private(set) var speed: Double = 1
    private(set) var failure: PlaybackFailure?
    var trackPreferences: TrackPreferences {
        get { autoSelection.preferences }
        set { autoSelection.preferences = newValue }
    }
    let supportsExternalSubtitles = false

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var stallObserver: NSObjectProtocol?
    @ObservationIgnored private var audioOptions: [AVMediaSelectionOption] = []
    @ObservationIgnored private var subtitleOptions: [AVMediaSelectionOption] = []
    @ObservationIgnored private var isLocalFile = false
    @ObservationIgnored private var isShutDown = false
    @ObservationIgnored private var pendingStart: Double?
    @ObservationIgnored private var autoSelection = TrackAutoSelection()
    @ObservationIgnored private var subtitleStyle = SubtitleStyle()

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncStatus() } }
        })
    }

    func load(_ url: URL, startAt seconds: Double?) {
        guard !isShutDown else { return }
        isLocalFile = url.isFileURL
        failure = nil
        isLoaded = false
        reachedEnd = false
        isBuffering = true
        autoSelection.reset()
        audioOptions = []
        subtitleOptions = []
        audioTracks = []
        subtitleTracks = []
        let item = AVPlayerItem(url: url)
        item.textStyleRules = Self.textStyleRules(for: subtitleStyle)
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.itemStatusChanged(failed: failed) } }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reachedEnd = true
                self?.isPaused = true
            }
        }
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        stallObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.playbackFailed() }
        }
        player.replaceCurrentItem(with: item)
        // Seeks before the item is ready are dropped, so the start position is applied in itemStatusChanged.
        pendingStart = seconds.flatMap { $0 > 0 ? $0 : nil }
        if let pendingStart { currentTime = pendingStart }
        play()
    }

    func play() {
        if reachedEnd { seek(to: 0) }
        isPaused = false
        player.rate = Float(speed)
    }

    func pause() {
        isPaused = true
        player.pause()
    }

    func seek(to seconds: Double) {
        let target = max(0, duration.map { min(seconds, $0 - 0.5) } ?? seconds)
        currentTime = target
        reachedEnd = false
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(by delta: Double) { seek(to: currentTime + delta) }

    func selectAudioTrack(_ id: Int?) {
        autoSelection.audioLocked = true
        setAudioTrack(id)
        applyTrackPreferences()
    }

    func selectSubtitleTrack(_ id: Int?) {
        autoSelection.subtitleLocked = true
        setSubtitleTrack(id)
    }

    /// AVPlayer can't side-load subtitle files into an item.
    func addExternalSubtitles(_ subtitles: [ExternalSubtitle]) {}

    private func setAudioTrack(_ id: Int?) {
        select(id, in: audioOptions, characteristic: .audible)
        selectedAudioTrackID = id
    }

    private func setSubtitleTrack(_ id: Int?) {
        select(id, in: subtitleOptions, characteristic: .legible)
        selectedSubtitleTrackID = id
    }

    private func applyTrackPreferences() {
        guard isLoaded, !isShutDown else { return }
        let change = autoSelection.resolve(audio: audioTracks, subtitles: subtitleTracks,
                                           selectedAudio: selectedAudioTrackID, selectedSubtitle: selectedSubtitleTrackID)
        if let audio = change.audio { setAudioTrack(audio) }
        if let subtitle = change.subtitle { setSubtitleTrack(subtitle) }
    }

    func setVolume(_ volume: Double) {
        self.volume = min(100, max(0, volume))
        player.volume = Float(self.volume / 100)
        if isMuted && volume > 0 { setMuted(false) }
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        player.isMuted = muted
    }

    func setSpeed(_ speed: Double) {
        self.speed = speed
        if !isPaused { player.rate = Float(speed) }
    }

    func setSubtitleStyle(_ style: SubtitleStyle) {
        subtitleStyle = style
        player.currentItem?.textStyleRules = Self.textStyleRules(for: style)
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        stallObserver = nil
        observations.removeAll()
        itemObservation = nil
        player.replaceCurrentItem(with: nil)
    }

    private func tick(_ time: CMTime) {
        guard !isShutDown else { return }
        if time.isNumeric { currentTime = time.seconds }
        #if DEBUG
        if Int(currentTime) % 2 == 0 && Int(currentTime * 2) % 2 == 0 {
            print(String(format: "[DeStream] avplayer time=%.2f duration=%.2f", currentTime, duration ?? -1))
        }
        #endif
        if let item = player.currentItem {
            let d = item.duration
            if d.isNumeric && d.seconds > 0 { duration = d.seconds }
            if let range = item.loadedTimeRanges.last?.timeRangeValue { bufferedUntil = range.end.seconds }
        }
    }

    private func syncStatus() {
        guard !isShutDown else { return }
        isBuffering = failure == nil && (!isLoaded || player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
    }

    private func itemStatusChanged(failed: Bool) {
        guard !isShutDown, let item = player.currentItem else { return }
        if failed {
            playbackFailed()
            return
        }
        guard item.status == .readyToPlay else { return }
        if let start = pendingStart {
            pendingStart = nil
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600))
        }
        isLoaded = true
        syncStatus()
        Task { await loadTracks(for: item) }
    }

    /// A stream that already played and then broke is a connection problem, not a bad source.
    private func playbackFailed() {
        guard !isShutDown, failure == nil else { return }
        failure = isLocalFile ? .fileMissing : isLoaded ? .network : .unplayable
        isBuffering = false
    }

    private func loadTracks(for item: AVPlayerItem) async {
        let asset = item.asset
        if let group = try? await asset.loadMediaSelectionGroup(for: .audible) {
            audioOptions = group.options
            audioTracks = group.options.enumerated().map { Self.track($0.offset, $0.element, kind: .audio) }
            if let selected = item.currentMediaSelection.selectedMediaOption(in: group) {
                selectedAudioTrackID = group.options.firstIndex(of: selected)
            }
        }
        if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
            subtitleOptions = group.options
            subtitleTracks = group.options.enumerated().map { Self.track($0.offset, $0.element, kind: .subtitle) }
            selectedSubtitleTrackID = item.currentMediaSelection.selectedMediaOption(in: group).flatMap { group.options.firstIndex(of: $0) }
        }
        guard player.currentItem === item else { return }
        applyTrackPreferences()
    }

    private func select(_ id: Int?, in options: [AVMediaSelectionOption], characteristic: AVMediaCharacteristic) {
        guard let item = player.currentItem else { return }
        Task {
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: characteristic) else { return }
            let option = id.flatMap { options.indices.contains($0) ? options[$0] : nil }
            item.select(option, in: group)
        }
    }

    /// AVFoundation has no outline color or width, so a visible outline maps to a uniform edge.
    private static func textStyleRules(for style: SubtitleStyle) -> [AVTextStyleRule] {
        guard !style.isDefault else { return [] }
        var attributes: [String: Any] = [
            kCMTextMarkupAttribute_RelativeFontSize as String: style.size * 100,
            kCMTextMarkupAttribute_ForegroundColorARGB as String: style.textColor.argb,
            kCMTextMarkupAttribute_BoldStyle as String: style.bold,
            kCMTextMarkupAttribute_CharacterEdgeStyle as String:
                (style.outlineWidth > 0 ? kCMTextMarkupCharacterEdgeStyle_Uniform : kCMTextMarkupCharacterEdgeStyle_None) as String,
            kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String:
                style.background ? style.backgroundColor.argb : [0.0, 0, 0, 0],
        ]
        if let family = style.font.familyName {
            attributes[kCMTextMarkupAttribute_FontFamilyName as String] = family
        }
        if style.elevation > 0 {
            attributes[kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection as String] = 90 - style.elevation * 100
        }
        return AVTextStyleRule(textMarkupAttributes: attributes).map { [$0] } ?? []
    }

    private static func track(_ index: Int, _ option: AVMediaSelectionOption, kind: PlayerTrack.Kind) -> PlayerTrack {
        PlayerTrack(id: index, kind: kind, title: option.displayName,
                    language: option.extendedLanguageTag ?? option.locale?.language.languageCode?.identifier,
                    isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles))
    }
}
