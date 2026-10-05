import Foundation
import Observation

/// One playback of a request: engine choice, resume decision, periodic progress saving, teardown.
@MainActor @Observable
final class PlayerSession {
    let request: PlaybackRequest
    let engine: any PlayerEngine
    /// Position offered in the resume prompt; nil when no prompt is shown.
    private(set) var resumeOffer: Double?
    /// Last known duration of this video, for the resume prompt's progress bar.
    private(set) var knownDuration: Double?
    private(set) var hasStarted = false
    private var startupFailure: PlaybackFailure?

    var failure: PlaybackFailure? {
        #if DEBUG
        if let debugFailure { return debugFailure }
        #endif
        return startupFailure ?? engine.failure
    }
    #if DEBUG
    private var debugFailure: PlaybackFailure?
    #endif

    @ObservationIgnored private let progress: ProgressStore
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let addons: AddonRegistry?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var subtitleTask: Task<Void, Never>?
    @ObservationIgnored private var audioObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastSavedSeconds: Double?
    @ObservationIgnored private var isClosed = false
    /// Set when moving on to the next episode, so closing doesn't overwrite "watched" with the credits position.
    @ObservationIgnored private var isMarkedFinished = false

    init(request: PlaybackRequest, preferMPV: Bool, progress: ProgressStore, library: LibraryStore,
         trackPreferences: TrackPreferences = TrackPreferences(), addons: AddonRegistry? = nil) {
        self.request = request
        self.progress = progress
        self.library = library
        self.addons = addons
        let made = PlayerEngineFactory.makeEngine(for: request, preferMPV: preferMPV)
        engine = made.engine
        engine.trackPreferences = trackPreferences
        startupFailure = made.failure ?? Self.validate(request)
        if request.startAt == nil {
            resumeOffer = progress.resumePosition(for: request.videoId)
                ?? (request.isLocal ? Self.libraryResumePosition(request, library: library) : nil)
        }
        knownDuration = progress.entry(for: request.videoId)?.duration
        #if DEBUG
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "DeStreamResumeOffer") != nil {
            resumeOffer = defaults.double(forKey: "DeStreamResumeOffer")
            knownDuration = defaults.double(forKey: "DeStreamResumeDuration") > 0 ? defaults.double(forKey: "DeStreamResumeDuration") : knownDuration
        }
        if defaults.bool(forKey: "DeStreamForceFailure") { debugFailure = .network }
        #endif
        #if DEBUG
        print("[DeStream] player session created (engine: \(engine.kind.rawValue))")
        #endif
    }

    /// Starts immediately unless a resume prompt is pending.
    func start() {
        guard !hasStarted, !isClosed, startupFailure == nil, resumeOffer == nil else { return }
        begin(at: request.startAt)
    }

    func resume() {
        let position = resumeOffer
        resumeOffer = nil
        begin(at: position)
    }

    func startOver() {
        resumeOffer = nil
        begin(at: nil)
    }

    /// Started streams can be reloaded; a missing saved file can be checked again (e.g. after reconnecting a drive).
    var canRetry: Bool { hasStarted || startupFailure == .fileMissing }

    func retry() {
        #if DEBUG
        debugFailure = nil
        #endif
        if !hasStarted, startupFailure == .fileMissing {
            startupFailure = Self.validate(request)
            start()
            return
        }
        guard hasStarted, startupFailure == nil else { return }
        engine.load(request.url, startAt: engine.currentTime > 0 ? engine.currentTime : nil)
    }

    func saveProgress() {
        guard hasStarted, engine.isLoaded, engine.failure == nil, !isMarkedFinished else { return }
        let duration = engine.duration
        var seconds = engine.currentTime
        if engine.reachedEnd, let duration { seconds = duration }
        guard seconds > 0, seconds != lastSavedSeconds else { return }
        lastSavedSeconds = seconds
        progress.record(request, seconds: seconds, duration: duration)
        if request.isLocal {
            library.updateProgress(titleID: request.metaID, videoId: request.videoId, seconds: seconds, duration: duration)
        }
    }

    /// Records the video as watched to the end (skipping the credits to the next episode).
    func markFinished() {
        guard hasStarted, engine.isLoaded, let duration = engine.duration, duration > 0 else { return }
        isMarkedFinished = true
        progress.record(request, seconds: duration, duration: duration)
        if request.isLocal {
            library.updateProgress(titleID: request.metaID, videoId: request.videoId, seconds: duration, duration: duration)
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        #if DEBUG
        print("[DeStream] player session closed")
        #endif
        saveProgress()
        saveTask?.cancel()
        subtitleTask?.cancel()
        audioObservers.forEach(NotificationCenter.default.removeObserver)
        audioObservers = []
        engine.shutdown()
        if hasStarted { PlayerPlatform.setPlaybackActive(false) }
        // The session is activated before the player is presented, so release it even if playback never began
        // (closed from the resume prompt or an error); otherwise other apps' audio stays interrupted.
        PlayerAudioSession.deactivate()
    }

    private func begin(at position: Double?) {
        guard !hasStarted, !isClosed, startupFailure == nil else { return }
        hasStarted = true
        PlayerAudioSession.activate()
        PlayerPlatform.setPlaybackActive(true)
        engine.load(request.url, startAt: position)
        audioObservers = PlayerAudioSession.observePauseEvents { [weak self] in
            guard let self, !self.isClosed else { return }
            self.engine.pause()
        }
        loadAddonSubtitles()
        saveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.saveProgress()
            }
        }
    }

    /// Offers subtitles in the preferred languages: those saved with a download (no network needed), otherwise from
    /// subtitle addons (e.g. OpenSubtitles), matched by video hash when it can be computed.
    private func loadAddonSubtitles() {
        guard engine.supportsExternalSubtitles else { return }
        let saved = Self.savedSubtitles(request, library: library)
        if !saved.isEmpty {
            engine.addExternalSubtitles(saved)
            return
        }
        let languages = engine.trackPreferences.subtitleLanguages
        guard let addons, !languages.isEmpty else { return }
        let request = request
        subtitleTask = Task { [weak self] in
            let fingerprint = await Self.fingerprint(for: request)
            guard !Task.isCancelled else { return }
            let subtitles = await AddonSubtitles.fetch(registry: addons, type: request.metaType, id: request.videoId,
                                                       languages: languages, fingerprint: fingerprint)
            guard !Task.isCancelled, let self, !self.isClosed, !subtitles.isEmpty else { return }
            self.engine.addExternalSubtitles(subtitles)
        }
    }

    /// Hash of the local file, or of the remote one via two short Range requests; nil hash when that fails.
    private nonisolated static func fingerprint(for request: PlaybackRequest) async -> VideoFingerprint {
        let url = request.url
        let filename = request.filenameHint.flatMap { $0.isEmpty ? nil : ($0 as NSString).lastPathComponent }
            ?? (url.isFileURL ? url.lastPathComponent : nil)
        var fingerprint = VideoFingerprint(filename: filename)
        let hashed: (hash: String, size: Int64)?
        if url.isFileURL {
            hashed = await Task.detached(priority: .utility) { OpenSubtitlesHash.hash(fileAt: url) }.value
        } else {
            hashed = await OpenSubtitlesHash.hash(remote: url)
        }
        fingerprint.hash = hashed?.hash
        fingerprint.size = hashed?.size
        return fingerprint
    }

    private static func savedSubtitles(_ request: PlaybackRequest, library: LibraryStore) -> [ExternalSubtitle] {
        guard request.isLocal, let title = library.title(id: request.metaID),
              let item = title.meta.items.first(where: { $0.videoId == request.videoId }) else { return [] }
        return title.externalSubtitles(for: item)
    }

    /// Saved files also keep their position in meta.json, which survives a lost progress.json.
    private static func libraryResumePosition(_ request: PlaybackRequest, library: LibraryStore) -> Double? {
        guard let item = library.title(id: request.metaID)?.meta.items.first(where: { $0.videoId == request.videoId }),
              let seconds = item.progressSeconds, seconds > 30 else { return nil }
        if let duration = item.durationSeconds, seconds >= duration * 0.92 { return nil }
        return seconds
    }

    private static func validate(_ request: PlaybackRequest) -> PlaybackFailure? {
        let url = request.url
        if url.isFileURL {
            return FileManager.default.fileExists(atPath: url.path) ? nil : .fileMissing
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return .unplayable }
        return nil
    }
}

enum PlayerTime {
    static func format(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
