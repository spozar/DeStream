import Foundation
import Observation
import Libmpv

/// libmpv engine (MKV/HEVC/10-bit/HDR, all audio codecs, embedded ASS/SRT). Renders into `layer`,
/// which the platform video view hosts.
@MainActor @Observable
final class MPVPlayerController: PlayerEngine {
    let kind = PlayerEngineKind.mpv
    private(set) var currentTime: Double = 0
    private(set) var duration: Double?
    private(set) var isPaused = false
    private(set) var isBuffering = false
    private(set) var isLoaded = false
    private(set) var reachedEnd = false
    private(set) var bufferedUntil: Double?
    /// mpv's cache fill (0...100) while waiting for data, if known.
    private(set) var cacheBufferingPercent: Double?
    private(set) var audioTracks: [PlayerTrack] = []
    private(set) var subtitleTracks: [PlayerTrack] = []
    private(set) var selectedAudioTrackID: Int?
    private(set) var selectedSubtitleTrackID: Int?
    private(set) var volume: Double = 100
    private(set) var isMuted = false
    private(set) var speed: Double = 1
    private(set) var chapters: [PlayerChapter] = []
    private(set) var subtitleDelay: Double = 0
    let supportsSubtitleDelay = true
    private(set) var failure: PlaybackFailure?
    var trackPreferences: TrackPreferences {
        get { autoSelection.preferences }
        set { autoSelection.preferences = newValue }
    }
    let supportsExternalSubtitles = true

    @ObservationIgnored let layer: MPVMetalLayer
    @ObservationIgnored private let core: MPVCore
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var pausedForCache = false
    @ObservationIgnored private var isShutDown = false
    @ObservationIgnored private var isLocalFile = false
    @ObservationIgnored private var pendingSeekTarget: Double?
    @ObservationIgnored private var autoSelection = TrackAutoSelection()
    @ObservationIgnored private var externalSubtitles: [ExternalSubtitle] = []
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    #if DEBUG
    @ObservationIgnored private var lastLoggedSecond = -1
    #endif

    init?() {
        guard let core = MPVCore() else { return nil }
        self.core = core
        layer = core.layer
        core.start { [weak self] events in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(events) }
            }
        }
    }

    deinit { core.destroy() }

    func load(_ url: URL, startAt seconds: Double?) {
        guard !isShutDown else { return }
        isLocalFile = url.isFileURL
        failure = nil
        isLoaded = false
        reachedEnd = false
        chapters = []
        isLoading = true
        updateBuffering()
        autoSelection.reset()
        resizeTask?.cancel()
        core.resetVideoSize()
        // Subtitles are chosen by TrackAutoSelection once the track list is known; mpv only picks the audio.
        core.set("alang", trackPreferences.mpvAudioLanguages)
        core.set("slang", trackPreferences.mpvSubtitleLanguages)
        core.set("sid", "no")
        var args = ["loadfile", url.isFileURL ? url.path : url.absoluteString, "replace", "-1"]
        if let seconds, seconds > 0 {
            args.append("start=\(Int(seconds))")
            currentTime = seconds
        }
        core.command(args)
        play()
    }

    /// Render size in pixels. Once a video is showing, mpv has to reconfigure to pick up a new size,
    /// so that only happens after resizing settles; the layer scales the last frame meanwhile.
    func setDrawableSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1, !isShutDown else { return }
        resizeTask?.cancel()
        guard isLoaded else {
            layer.drawableSize = size
            return
        }
        guard size != layer.drawableSize else { return }
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled, !isShutDown else { return }
            layer.drawableSize = size
            core.refreshVideoSize()
        }
    }

    func play() {
        if reachedEnd { seek(to: 0) }
        isPaused = false
        core.set("pause", "no")
    }

    func pause() {
        isPaused = true
        core.set("pause", "yes")
    }

    func seek(to seconds: Double) {
        let target = max(0, duration.map { min(seconds, $0 - 0.5) } ?? seconds)
        currentTime = target
        pendingSeekTarget = target
        reachedEnd = false
        core.command(["seek", String(format: "%.3f", target), "absolute"])
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

    func addExternalSubtitles(_ subtitles: [ExternalSubtitle]) {
        let new = subtitles.filter { !externalSubtitles.contains($0) }
        externalSubtitles += new
        if isLoaded { new.forEach(addToPlayer) }
    }

    private func addToPlayer(_ subtitle: ExternalSubtitle) {
        core.commandAsync(["sub-add", subtitle.url.isFileURL ? subtitle.url.path : subtitle.url.absoluteString, "auto", subtitle.source ?? "", subtitle.language ?? ""])
    }

    private func setAudioTrack(_ id: Int?) {
        selectedAudioTrackID = id
        core.set("aid", id.map(String.init) ?? "no")
    }

    private func setSubtitleTrack(_ id: Int?) {
        selectedSubtitleTrackID = id
        core.set("sid", id.map(String.init) ?? "no")
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
        core.set("volume", String(format: "%.0f", self.volume))
        if isMuted && volume > 0 { setMuted(false) }
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        core.set("mute", muted ? "yes" : "no")
    }

    func setSpeed(_ speed: Double) {
        self.speed = speed
        core.set("speed", String(format: "%.2f", speed))
    }

    func setSubtitleDelay(_ seconds: Double) {
        subtitleDelay = (min(60, max(-60, seconds)) * 10).rounded() / 10
        core.set("sub-delay", String(format: "%.2f", subtitleDelay))
    }

    /// Lifts subtitles above the player controls while they are shown (mpv scales this to a 720p canvas).
    func setSubtitlesRaised(_ raised: Bool) {
        guard !isShutDown else { return }
        core.set("sub-margin-y", raised ? "96" : "22")
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        resizeTask?.cancel()
        core.destroy()
    }

    private func updateBuffering() {
        isBuffering = failure == nil && (isLoading || pausedForCache)
    }

    private func apply(_ events: [MPVEvent]) {
        guard !isShutDown else { return }
        var tracksChanged = false
        for event in events {
            switch event {
            case .property(let name, let value):
                applyProperty(name, value)
                if name == "track-list" || name == "aid" || name == "sid" { tracksChanged = true }
            case .startFile:
                isLoading = true
            case .fileLoaded:
                isLoading = false
                isLoaded = true
                externalSubtitles.forEach(addToPlayer)
                tracksChanged = true
            case .endFile(let reason, let error):
                isLoading = false
                if reason == MPV_END_FILE_REASON_ERROR.rawValue {
                    #if DEBUG
                    print("[mpv] end-file error: \(String(cString: mpv_error_string(error)))")
                    #endif
                    // A stream that already played and then broke is a connection problem, not a bad source.
                    failure = isLocalFile ? .fileMissing : isLoaded ? .network : .unplayable
                }
            case .shutdown:
                shutdown()
            }
        }
        updateBuffering()
        if tracksChanged { applyTrackPreferences() }
    }

    private func applyProperty(_ name: String, _ value: MPVEvent.Value) {
        switch (name, value) {
        case ("time-pos", .double(let t)):
            if let target = pendingSeekTarget, abs(t - target) > 1.5 { break }
            pendingSeekTarget = nil
            currentTime = t
            #if DEBUG
            if Int(t) != lastLoggedSecond && Int(t) % 2 == 0 {
                lastLoggedSecond = Int(t)
                print(String(format: "[DeStream] mpv time-pos=%.2f duration=%.2f paused=%@ buffering=%@", t, duration ?? -1, "\(isPaused)", "\(isBuffering)"))
            }
            #endif
        case ("duration", .double(let d)): duration = d > 0 ? d : nil
        case ("duration", .none): duration = nil
        case ("pause", .flag(let p)): isPaused = p
        case ("paused-for-cache", .flag(let b)): pausedForCache = b
        case ("eof-reached", .flag(let e)): reachedEnd = e
        case ("seeking", .flag(false)): pendingSeekTarget = nil
        case ("volume", .double(let v)): volume = v
        case ("mute", .flag(let m)): isMuted = m
        case ("speed", .double(let s)): speed = s
        case ("aid", .string(let s)): selectedAudioTrackID = Int(s)
        case ("sid", .string(let s)): selectedSubtitleTrackID = Int(s)
        case ("demuxer-cache-time", .double(let c)): bufferedUntil = c
        case ("demuxer-cache-time", .none): bufferedUntil = nil
        case ("cache-buffering-state", .double(let p)): cacheBufferingPercent = p
        case ("cache-buffering-state", .none): cacheBufferingPercent = nil
        case ("chapter-list", .chapters(let list)): chapters = list
        case ("track-list", .tracks(let tracks)):
            audioTracks = tracks.filter { $0.kind == .audio }
            subtitleTracks = tracks.filter { $0.kind == .subtitle }
            selectedAudioTrackID = audioTracks.first(where: \.isSelected)?.id
            selectedSubtitleTrackID = subtitleTracks.first(where: \.isSelected)?.id
            #if DEBUG
            print("[DeStream] mpv tracks: audio=\(audioTracks.map(\.displayName)) subs=\(subtitleTracks.map(\.displayName))")
            #endif
        default: break
        }
    }
}
