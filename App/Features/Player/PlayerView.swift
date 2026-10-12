import SwiftUI

/// Player: mpv (MPVKit) for MKV/HEVC, AVPlayer fallback. OWNER: UI Agent 4 (Player).
struct PlayerView: View {
    let request: PlaybackRequest

    @Environment(AppSettings.self) private var settings
    @Environment(AppServices.self) private var services
    @Environment(ProgressStore.self) private var progress
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: PlayerSession?
    @State private var nextEpisode: NextEpisodeModel?
    @State private var window = PlayerWindowState()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let session {
                PlayerContent(session: session, window: window, nextEpisode: nextEpisode, onPlayNext: playNext, onClose: close)
                    .id(ObjectIdentifier(session))
            }
        }
        .navigationTitle(session?.request.title ?? request.title)
        .playerWindow(window)
        .preferredColorScheme(.dark)
        .onAppear {
            guard session == nil else { return }
            start(request)
        }
        .task(id: session.map(ObjectIdentifier.init)) { await nextEpisode?.resolve() }
        .onChange(of: settings.subtitleStyle) { _, style in session?.engine.setSubtitleStyle(style) }
        .onDisappear {
            session?.close()
            session = nil
            PlayerPlatform.setPlayerPresented(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: PlayerPlatform.willTerminateNotification)) { _ in
            session?.close()
        }
        // iOS may suspend or kill the app in the background before the next periodic save.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session?.saveProgress() }
        }
        #if os(iOS)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        #endif
    }

    private func close() {
        session?.close()
        if !window.closeWindow() { dismiss() }
    }

    private func start(_ request: PlaybackRequest) {
        let s = PlayerSession(request: request, preferMPV: settings.preferMPV, progress: progress, library: library,
                              trackPreferences: settings.trackPreferences, addons: services.registry)
        s.engine.setSubtitleStyle(settings.subtitleStyle)
        nextEpisode = NextEpisodeModel(request: request, registry: services.registry, library: library)
        session = s
        s.start()
    }

    /// Swaps in a session for the next episode; the current one is recorded as watched.
    private func playNext() {
        guard let nextEpisode else { return }
        Task {
            guard let next = await nextEpisode.nextRequest(), self.nextEpisode === nextEpisode else { return }
            session?.markFinished()
            session?.close()
            start(next)
        }
    }
}

/// Floating panels opened from the control row.
enum PlayerPanel: String {
    case tracks, speed
}

/// DEBUG-only launch arguments that freeze overlay states for visual checks.
enum PlayerDebugOptions {
    #if DEBUG
    static var pinControls: Bool { UserDefaults.standard.bool(forKey: "DeStreamPinControls") }
    static var initialPanel: PlayerPanel? {
        UserDefaults.standard.string(forKey: "DeStreamPlayerPanel").flatMap(PlayerPanel.init(rawValue:))
    }
    /// Fraction (0...1) at which the scrubber shows its hover preview.
    static var scrubPreview: Double? {
        UserDefaults.standard.object(forKey: "DeStreamScrubPreview") != nil ? UserDefaults.standard.double(forKey: "DeStreamScrubPreview") : nil
    }
    static var forceBuffering: Bool { UserDefaults.standard.bool(forKey: "DeStreamForceBuffering") }
    #else
    static let pinControls = false
    static let initialPanel: PlayerPanel? = nil
    static let scrubPreview: Double? = nil
    static let forceBuffering = false
    #endif
}

private struct PlayerContent: View {
    let session: PlayerSession
    let window: PlayerWindowState
    let nextEpisode: NextEpisodeModel?
    let onPlayNext: () -> Void
    let onClose: () -> Void

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubTime: Double?
    @State private var panel: PlayerPanel? = PlayerDebugOptions.initialPanel
    @State private var seekFeedback: SeekFeedback?
    @State private var seekFeedbackTask: Task<Void, Never>?
    @State private var toast: PlayerToastState?
    @State private var toastTask: Task<Void, Never>?
    @State private var lastTap: TapRecord?
    @State private var size: CGSize = .zero
    @State private var upNextDismissed = false
    @FocusState private var focused: Bool

    private var engine: any PlayerEngine { session.engine }
    private var showsEndCard: Bool { engine.reachedEnd && engine.isLoaded && scrubTime == nil }

    /// Over the end credits (chapter marker, else the last 30 s – 2 min) while a next episode exists.
    private var showsUpNext: Bool {
        guard nextEpisode?.target != nil, !upNextDismissed, engine.isLoaded, !showsEndCard, scrubTime == nil,
              let start = CreditsMarker.start(duration: engine.duration, chapters: engine.chapters) else { return false }
        return engine.currentTime >= start
    }

    var body: some View {
        ZStack {
            video.ignoresSafeArea()

            if let failure = session.failure {
                Color.black.opacity(0.6).ignoresSafeArea().transition(.opacity)
                PlayerErrorOverlay(failure: failure, canRetry: session.canRetry, onRetry: session.retry, onClose: onClose)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if let offer = session.resumeOffer {
                ResumePrompt(
                    request: session.request, position: offer, duration: session.knownDuration,
                    onResume: session.resume, onStartOver: session.startOver, onClose: onClose
                )
                .transition(.opacity)
            } else {
                if engine.isBuffering || PlayerDebugOptions.forceBuffering {
                    BufferingIndicator(percent: bufferingPercent)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                PlayerControls(
                    session: session, window: window, scrubTime: $scrubTime, panel: $panel,
                    nextEpisode: nextEpisode, onPlayNext: onPlayNext, onSubtitleDelayChange: showSubtitleDelay,
                    showsCenterButtons: !showsEndCard && !engine.isBuffering,
                    isVisible: controlsVisible,
                    onInteraction: poke, onClose: onClose
                )
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)

                if let seekFeedback {
                    DoubleTapSeekIndicator(feedback: seekFeedback)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if let toast {
                    PlayerToast(toast: toast)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, PlayerMetrics.toastTop)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                if showsUpNext, let nextEpisode, let target = nextEpisode.target {
                    PlayerUpNextCard(target: target, phase: nextEpisode.phase, onPlay: onPlayNext,
                                     onDismiss: { withAnimation(Theme.Motion.appear) { upNextDismissed = true } })
                        .padding(.trailing, PlayerMetrics.edge)
                        .padding(.bottom, controlsVisible ? PlayerMetrics.upNextLift : PlayerMetrics.edge)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                if showsEndCard {
                    PlayerEndCard(
                        request: session.request,
                        next: nextEpisode?.target.map { ($0, nextEpisode?.phase ?? .idle) },
                        onPlayNext: onPlayNext,
                        onReplay: { engine.seek(to: 0); engine.play(); poke() },
                        onClose: onClose
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
        }
        .animation(Theme.Motion.appear, value: session.failure)
        .animation(Theme.Motion.appear, value: session.resumeOffer)
        .animation(Theme.Motion.appear, value: engine.isBuffering)
        .animation(Theme.Motion.appear, value: showsEndCard)
        .animation(Theme.Motion.appear, value: showsUpNext)
        .animation(Theme.Motion.appear, value: controlsVisible)
        .contentShape(Rectangle())
        #if os(macOS)
        // Double-click for full screen and keyboard focus are Mac-only; on iOS the double-tap
        // recognizer and focus handling delay or swallow taps on the overlay buttons.
        .onTapGesture(count: 2) {
            if PlayerWindowState.supportsFullScreenToggle, session.resumeOffer == nil, session.failure == nil { window.toggleFullScreen() }
        }
        #endif
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .onTapGesture(coordinateSpace: .local) { handleTap(at: $0) }
        .sensoryFeedback(.impact(weight: .light), trigger: seekFeedback?.tick)
        .onContinuousHover { phase in
            if case .active = phase { poke() }
        }
        #if os(macOS)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(action: handleKey)
        #endif
        .onAppear {
            focused = true
            poke()
        }
        .onChange(of: engine.isPaused) { _, paused in
            if paused { session.saveProgress() }
            poke()
        }
        .onChange(of: engine.reachedEnd) { _, ended in
            if ended { session.saveProgress() }
            poke()
        }
        .onChange(of: panel) { _, _ in poke() }
        .onChange(of: showsUpNext) { _, shows in
            if shows { nextEpisode?.prepare() }
        }
        .onChange(of: controlsVisible, initial: true) { _, visible in
            window.setChromeVisible(visible)
            (engine as? MPVPlayerController)?.setSubtitlesRaised(visible)
        }
        .onDisappear {
            hideTask?.cancel()
            seekFeedbackTask?.cancel()
            toastTask?.cancel()
        }
    }

    @ViewBuilder private var video: some View {
        if let mpv = engine as? MPVPlayerController {
            MPVVideoView(controller: mpv)
        } else if let av = engine as? AVPlayerController {
            AVVideoView(player: av.player)
        }
    }

    private var bufferingPercent: Double? {
        guard let p = (engine as? MPVPlayerController)?.cacheBufferingPercent, p > 0, p < 100, engine.isLoaded else { return nil }
        return p
    }

    private var keepsControlsVisible: Bool {
        engine.isPaused || scrubTime != nil || !engine.isLoaded || panel != nil || engine.reachedEnd
            || session.resumeOffer != nil || session.failure != nil || PlayerDebugOptions.pinControls
    }

    private func poke() {
        if !controlsVisible { withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true } }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(PlayerContent.autoHideDelay))
            guard !Task.isCancelled else { return }
            if keepsControlsVisible { poke(); return }
            withAnimation(.easeInOut(duration: 0.4)) { controlsVisible = false }
        }
    }

    #if os(macOS)
    private static let autoHideDelay = 3.0
    #else
    private static let autoHideDelay = 3.5
    #endif

    private func handleTap(at location: CGPoint) {
        guard session.failure == nil, session.resumeOffer == nil else { return }
        if panel != nil {
            withAnimation(PlayerMetrics.panelSpring) { panel = nil }
            return
        }
        #if os(macOS)
        // A stray click beside the end card would otherwise restart the video from the beginning.
        guard !showsEndCard else { return }
        engine.togglePause()
        poke()
        #else
        if handleDoubleTapSeek(at: location) { return }
        setControlsVisible(!controlsVisible)
        #endif
    }

    private func setControlsVisible(_ visible: Bool) {
        if visible {
            poke()
        } else {
            hideTask?.cancel()
            withAnimation(.easeIn(duration: 0.2)) { controlsVisible = false }
        }
    }

    /// YouTube-style seeking: double-tap the left or right edge to skip 10 s; further quick taps keep adding.
    /// The first tap of the pair has already toggled the controls, so a double-tap restores their previous state.
    private func handleDoubleTapSeek(at location: CGPoint) -> Bool {
        let side: SeekSide? = location.x < size.width * 0.35 ? .back : location.x > size.width * 0.65 ? .forward : nil
        let now = Date()
        guard let side, engine.isLoaded, !showsEndCard, scrubTime == nil else {
            lastTap = nil
            return false
        }
        let streaking = seekFeedback?.side == side
        if let last = lastTap, last.side == side, now.timeIntervalSince(last.date) < (streaking ? 0.7 : 0.32) {
            lastTap = TapRecord(date: now, side: side, controlsWereVisible: last.controlsWereVisible)
            if controlsVisible != last.controlsWereVisible { setControlsVisible(last.controlsWereVisible) }
            seek(side)
            return true
        }
        lastTap = TapRecord(date: now, side: side, controlsWereVisible: controlsVisible)
        return false
    }

    private func seek(_ side: SeekSide) {
        engine.seek(by: side == .forward ? 10 : -10)
        withAnimation(.snappy(duration: 0.25)) {
            if var current = seekFeedback, current.side == side {
                current.seconds += 10
                current.tick += 1
                seekFeedback = current
            } else {
                seekFeedback = SeekFeedback(side: side, seconds: 10, tick: (seekFeedback?.tick ?? 0) + 1)
            }
        }
        seekFeedbackTask?.cancel()
        seekFeedbackTask = Task {
            try? await Task.sleep(for: .seconds(0.75))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { seekFeedback = nil }
        }
        if controlsVisible { poke() }
    }

    /// Brief on-screen confirmation for keyboard changes whose control may be hidden (volume, mute, speed).
    private func showToast(_ systemImage: String, _ text: String) {
        withAnimation(Theme.Motion.fast) {
            toast = PlayerToastState(systemImage: systemImage, text: text, tick: (toast?.tick ?? 0) + 1)
        }
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.1))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { toast = nil }
        }
    }

    private func changeVolume(by delta: Double) {
        engine.setVolume(engine.volume + delta)
        let volume = Int(engine.volume.rounded())
        showToast(volume == 0 ? "speaker.slash.fill" : volume < 50 ? "speaker.wave.1.fill" : "speaker.wave.3.fill", "\(volume)%")
    }

    private func changeSubtitleDelay(by delta: Double) {
        guard engine.supportsSubtitleDelay, engine.selectedSubtitleTrackID != nil else { return }
        engine.setSubtitleDelay(engine.subtitleDelay + delta)
        showSubtitleDelay()
    }

    private func showSubtitleDelay() {
        showToast("captions.bubble.fill", "Subtitles " + PlayerSubtitleTiming.label(engine.subtitleDelay))
    }

    private func changeSpeed(to speed: Double) {
        engine.setSpeed(speed)
        showToast("gauge.with.dots.needle.67percent", speed == 1 ? "Normal speed" : PlayerSpeed.label(speed))
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // Leave menu shortcuts (⌘F, ⌘M, ⌃⌘F…) to the menu bar.
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        if session.resumeOffer != nil {
            if press.key == .return { session.resume(); return .handled }
            return .ignored
        }
        guard session.failure == nil else { return .ignored }
        switch press.key {
        case .space: engine.togglePause()
        case .leftArrow: engine.isLoaded ? seek(.back) : engine.seek(by: -10)
        case .rightArrow: engine.isLoaded ? seek(.forward) : engine.seek(by: 10)
        case .upArrow: changeVolume(by: 5)
        case .downArrow: changeVolume(by: -5)
        case .escape:
            if panel != nil {
                withAnimation(PlayerMetrics.panelSpring) { panel = nil }
            } else if window.isFullScreen, PlayerWindowState.supportsFullScreenToggle {
                window.exitFullScreen()
            } else {
                return .ignored
            }
        default:
            switch press.characters.lowercased() {
            case "f": window.toggleFullScreen()
            case "m":
                engine.setMuted(!engine.isMuted)
                showToast(engine.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", engine.isMuted ? "Muted" : "Sound on")
            case "]": changeSpeed(to: min(3, engine.speed + 0.25))
            case "[": changeSpeed(to: max(0.25, engine.speed - 0.25))
            case "\\": changeSpeed(to: 1)
            case "z": changeSubtitleDelay(by: -0.1)
            case "x": changeSubtitleDelay(by: 0.1)
            case "n" where nextEpisode?.target != nil: onPlayNext()
            default: return .ignored
            }
        }
        poke()
        return .handled
    }
}

private struct TapRecord {
    let date: Date
    let side: SeekSide
    let controlsWereVisible: Bool
}
