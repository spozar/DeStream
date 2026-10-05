import SwiftUI

/// The overlay drawn over the video: title bar, center transport, scrubber and control row.
struct PlayerControls: View {
    let session: PlayerSession
    let window: PlayerWindowState
    @Binding var scrubTime: Double?
    @Binding var panel: PlayerPanel?
    var nextEpisode: NextEpisodeModel? = nil
    var onPlayNext: () -> Void = {}
    var onSubtitleDelayChange: () -> Void = {}
    let showsCenterButtons: Bool
    var isVisible = true
    let onInteraction: () -> Void
    let onClose: () -> Void

    @AppStorage("player.showsRemainingTime") private var showsRemaining = true

    private var engine: any PlayerEngine { session.engine }
    private var request: PlaybackRequest { session.request }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                topBar
                    .offset(y: isVisible ? 0 : -PlayerMetrics.hideOffset)
                Spacer(minLength: 0)
                bottomBar
                    .offset(y: isVisible ? 0 : PlayerMetrics.hideOffset)
            }
            if showsCenterButtons {
                centerButtons
                    .scaleEffect(isVisible ? 1 : 0.92)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            #if os(iOS)
            if panel != nil {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { closePanel() }
                    .transition(.opacity)
                panelView
                    .padding(.vertical, Theme.Space.s)
                    .padding(.trailing, Theme.Space.s)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
            #endif
        }
        .foregroundStyle(Theme.Palette.textPrimary)
        .buttonStyle(.plain)
        .animation(Theme.Motion.appear, value: showsCenterButtons)
        .dsSelectionHaptic(panel)
    }

    private func closePanel() {
        withAnimation(PlayerMetrics.panelSpring) { panel = nil }
        onInteraction()
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(alignment: .center, spacing: Theme.Space.s) {
            PlayerIconButton(systemName: "chevron.left", size: 20, help: "Back", backdrop: PlayerMetrics.backButtonBackdrop, action: onClose)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.title)
                    .font(.system(size: PlayerMetrics.titleSize, weight: .bold))
                    .lineLimit(1)
                if let subtitle = request.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
            Spacer(minLength: 0)
        }
        #if os(macOS)
        .padding(.leading, window.isFullScreen ? Theme.Space.l : 76)
        .padding(.trailing, Theme.Space.l)
        .padding(.top, window.isFullScreen ? Theme.Space.m : Theme.Space.xs)
        #else
        .padding(.horizontal, PlayerMetrics.edge)
        .padding(.top, Theme.Space.s)
        #endif
        .padding(.bottom, 56)
        .background(
            LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
    }

    // MARK: Center

    private var centerButtons: some View {
        HStack(spacing: PlayerMetrics.centerSpacing) {
            PlayerCenterButton(systemName: "gobackward.10", diameter: PlayerMetrics.skipDiameter, help: "Back 10 seconds", bounces: true) {
                engine.seek(by: -10); onInteraction()
            }
            PlayerCenterButton(
                systemName: engine.isPaused ? "play.fill" : "pause.fill", diameter: PlayerMetrics.playDiameter,
                help: engine.isPaused ? "Play" : "Pause"
            ) {
                engine.togglePause(); onInteraction()
            }
            PlayerCenterButton(systemName: "goforward.10", diameter: PlayerMetrics.skipDiameter, help: "Forward 10 seconds", bounces: true) {
                engine.seek(by: 10); onInteraction()
            }
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack(spacing: Theme.Space.xxs) {
            HStack(spacing: Theme.Space.s) {
                Text(PlayerTime.format(scrubTime ?? engine.currentTime))
                    .frame(minWidth: 52, alignment: .leading)
                PlayerScrubber(
                    current: engine.currentTime, duration: engine.duration, buffered: engine.bufferedUntil,
                    scrubTime: $scrubTime,
                    onCommit: { engine.seek(to: $0); onInteraction() },
                    onChange: onInteraction
                )
                Button {
                    showsRemaining.toggle()
                } label: {
                    Text(trailingTime)
                        .frame(minWidth: 56, minHeight: PlayerMetrics.hit, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .help(showsRemaining ? "Show total duration" : "Show remaining time")
                .accessibilityLabel(showsRemaining ? "Time remaining" : "Duration")
                .accessibilityValue(trailingTime)
                .accessibilityHint(showsRemaining ? "Shows the total duration" : "Shows the remaining time")
            }
            .font(PlayerMetrics.timeFont)
            .foregroundStyle(Theme.Palette.textPrimary.opacity(0.9))
            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)

            HStack(spacing: PlayerMetrics.rowSpacing) {
                #if os(macOS)
                PlayerIconButton(systemName: engine.isPaused ? "play.fill" : "pause.fill", size: 22, help: engine.isPaused ? "Play (Space)" : "Pause (Space)") {
                    engine.togglePause(); onInteraction()
                }
                PlayerIconButton(systemName: "gobackward.10", size: 20, help: "Back 10 seconds (←)") { engine.seek(by: -10); onInteraction() }
                PlayerIconButton(systemName: "goforward.10", size: 20, help: "Forward 10 seconds (→)") { engine.seek(by: 10); onInteraction() }
                PlayerVolumeControl(engine: engine, onInteraction: onInteraction)
                #endif
                Spacer(minLength: 0)
                if let target = nextEpisode?.target {
                    nextEpisodeButton(target)
                }
                PlayerIconButton(
                    systemName: engine.selectedSubtitleTrackID == nil ? "captions.bubble" : "captions.bubble.fill",
                    size: 20, help: "Audio & Subtitles", isActive: panel == .tracks
                ) { toggle(.tracks) }
                speedButton
                if PlayerWindowState.supportsFullScreenToggle {
                    PlayerIconButton(
                        systemName: window.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                        size: 18, help: window.isFullScreen ? "Exit Full Screen (F)" : "Full Screen (F)"
                    ) { window.toggleFullScreen(); onInteraction() }
                }
            }
        }
        #if os(macOS)
        .overlay(alignment: .topTrailing) {
            panelView
                .alignmentGuide(.top) { $0[.bottom] + Theme.Space.s }
        }
        #endif
        .padding(.horizontal, PlayerMetrics.edge)
        .padding(.top, PlayerMetrics.bottomGradientLead)
        .padding(.bottom, PlayerMetrics.bottom)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.45), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
    }

    private var trailingTime: String {
        guard let duration = engine.duration else { return "--:--" }
        if showsRemaining { return "-" + PlayerTime.format(max(0, duration - (scrubTime ?? engine.currentTime))) }
        return PlayerTime.format(duration)
    }

    private func nextEpisodeButton(_ target: NextEpisodeModel.Target) -> some View {
        let loading = nextEpisode?.phase == .loading
        return Button(action: onPlayNext) {
            HStack(spacing: Theme.Space.xxs + 2) {
                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "forward.end.fill").font(.system(size: PlayerMetrics.uniformGlyph ?? 17, weight: .semibold))
                }
                #if os(macOS)
                Text("Next Episode").font(Theme.Font.headline)
                #endif
            }
            .padding(.horizontal, Theme.Space.xs)
            .frame(minWidth: PlayerMetrics.hit, minHeight: PlayerMetrics.hit)
            .contentShape(Capsule())
        }
        .buttonStyle(PlayerPressStyle())
        .disabled(loading)
        .help("Next Episode: \(target.label) (N)")
        .accessibilityLabel("Next episode")
        .accessibilityValue(target.label)
    }

    private var speedButton: some View {
        Button { toggle(.speed) } label: {
            HStack(spacing: 3) {
                Image(systemName: "gauge.with.dots.needle.67percent").font(.system(size: PlayerMetrics.uniformGlyph ?? 19, weight: .semibold))
                if engine.speed != 1 {
                    Text(PlayerSpeed.label(engine.speed))
                        .font(Theme.Font.caption.monospacedDigit().weight(.bold))
                        .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .leading)))
                }
            }
            .animation(PlayerMetrics.panelSpring, value: engine.speed)
            .padding(.horizontal, engine.speed != 1 ? Theme.Space.xs : 0)
            .frame(minWidth: PlayerMetrics.hit, minHeight: PlayerMetrics.hit)
            .background(Capsule().fill(.white.opacity(panel == .speed ? 0.18 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(PlayerPressStyle())
        .help("Playback Speed ([ ])")
        .accessibilityLabel("Playback speed")
    }

    @ViewBuilder private var panelView: some View {
        Group {
            switch panel {
            case .tracks:
                PlayerTracksPanel(engine: engine, onSelect: onInteraction, onDelayChange: {
                    onInteraction(); onSubtitleDelayChange()
                })
            case .speed:
                PlayerSpeedPanel(engine: engine, onSelect: closePanel)
            case nil:
                EmptyView()
            }
        }
        #if os(macOS)
        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottomTrailing)))
        #else
        .transition(.move(edge: .trailing).combined(with: .opacity))
        #endif
    }

    private func toggle(_ target: PlayerPanel) {
        withAnimation(PlayerMetrics.panelSpring) { panel = panel == target ? nil : target }
        onInteraction()
    }
}

enum PlayerMetrics {
    static let hideOffset: CGFloat = 10
    static let panelSpring = Animation.spring(response: 0.34, dampingFraction: 0.86)
    #if os(macOS)
    static let hit: CGFloat = 38
    /// nil keeps each control's own glyph size.
    static let uniformGlyph: CGFloat? = nil
    static let backButtonBackdrop = false
    static let timeFont = Theme.Font.caption.monospacedDigit()
    static let bottomGradientLead: CGFloat = 72
    static let scrubBar: (idle: CGFloat, active: CGFloat) = (4, 8)
    static let scrubKnob: (idle: CGFloat, active: CGFloat) = (12, 18)
    static let scrubTipLift: CGFloat = 26
    static let titleSize: CGFloat = 20
    static let playDiameter: CGFloat = 84
    static let skipDiameter: CGFloat = 60
    static let centerSpacing: CGFloat = 56
    static let rowSpacing: CGFloat = 6
    static let edge: CGFloat = Theme.Space.l
    static let bottom: CGFloat = Theme.Space.m
    static let toastTop: CGFloat = 96
    static let upNextLift: CGFloat = 132
    #else
    static let hit: CGFloat = 44
    static let uniformGlyph: CGFloat? = 20
    static let backButtonBackdrop = true
    static let timeFont = SwiftUI.Font.system(size: 13, weight: .semibold).monospacedDigit()
    static let bottomGradientLead: CGFloat = 56
    static let scrubBar: (idle: CGFloat, active: CGFloat) = (4, 10)
    static let scrubKnob: (idle: CGFloat, active: CGFloat) = (14, 26)
    static let scrubTipLift: CGFloat = 40
    static let titleSize: CGFloat = 17
    static let playDiameter: CGFloat = 72
    static let skipDiameter: CGFloat = 52
    static let centerSpacing: CGFloat = 52
    static let rowSpacing: CGFloat = 8
    static let edge: CGFloat = Theme.Space.m
    static let bottom: CGFloat = Theme.Space.xxs
    static let toastTop: CGFloat = 72
    static let upNextLift: CGFloat = 112
    #endif
}

enum PlayerSpeed {
    static let options: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    static func label(_ speed: Double) -> String { String(format: "%g×", speed) }
}

/// Scales slightly while pressed.
struct PlayerPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(configuration.isPressed ? Theme.Motion.press : Theme.Motion.release, value: configuration.isPressed)
            .dsPressHaptic(configuration.isPressed)
    }
}

/// Icon button of the title bar and control row, with a soft hover halo.
struct PlayerIconButton: View {
    let systemName: String
    var size: CGFloat = 20
    let help: String
    var isActive = false
    /// Translucent disc behind the glyph, for buttons that float over bright video (iOS back button).
    var backdrop = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: PlayerMetrics.uniformGlyph ?? size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: PlayerMetrics.hit, height: PlayerMetrics.hit)
                .background(Circle().fill(.white.opacity(isActive ? 0.18 : isHovering ? 0.12 : 0)))
                .background {
                    if backdrop { Circle().fill(.black.opacity(0.3)).padding(2) }
                }
                .contentShape(Circle())
                .scaleEffect(isHovering ? 1.06 : 1)
                .animation(Theme.Motion.fast, value: isActive)
        }
        .buttonStyle(PlayerPressStyle())
        .foregroundStyle(Theme.Palette.textPrimary)
        .onHover { hovering in withAnimation(Theme.Motion.hover) { isHovering = hovering } }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Large translucent circle used for the center play/pause and ±10 s buttons.
struct PlayerCenterButton: View {
    let systemName: String
    let diameter: CGFloat
    let help: String
    var bounces = false
    let action: () -> Void

    @State private var isHovering = false
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: diameter * 0.4, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, options: .speed(1.6), value: bounces ? taps : 0)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(.black.opacity(isHovering ? 0.5 : 0.35)))
                .background(Circle().fill(.ultraThinMaterial).opacity(0.6))
                .overlay(Circle().strokeBorder(.white.opacity(isHovering ? 0.35 : 0.18), lineWidth: 1))
                .contentShape(Circle())
                .scaleEffect(isHovering ? 1.07 : 1)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        }
        .buttonStyle(PlayerPressStyle())
        .foregroundStyle(Theme.Palette.textPrimary)
        .environment(\.colorScheme, .dark)
        .onHover { hovering in withAnimation(Theme.Motion.hover) { isHovering = hovering } }
        .help(help)
        .accessibilityLabel(help)
    }
}

#if os(macOS)
/// Mute button whose volume slider slides out on hover.
struct PlayerVolumeControl: View {
    let engine: any PlayerEngine
    let onInteraction: () -> Void

    @State private var isHovering = false
    @State private var isDragging = false

    private var expanded: Bool { isHovering || isDragging }

    var body: some View {
        HStack(spacing: 2) {
            PlayerIconButton(systemName: icon, size: 18, help: engine.isMuted ? "Unmute (M)" : "Mute (M)") {
                engine.setMuted(!engine.isMuted); onInteraction()
            }
            PlayerVolumeSlider(
                value: engine.isMuted ? 0 : engine.volume,
                isDragging: $isDragging,
                onChange: { engine.setVolume($0); onInteraction() }
            )
            .frame(width: expanded ? 92 : 0)
            .opacity(expanded ? 1 : 0)
            .padding(.trailing, expanded ? Theme.Space.xs : 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(Theme.Motion.hover) { isHovering = hovering } }
        .animation(Theme.Motion.hover, value: isDragging)
    }

    private var icon: String {
        if engine.isMuted || engine.volume == 0 { return "speaker.slash.fill" }
        if engine.volume < 34 { return "speaker.wave.1.fill" }
        return engine.volume < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}

private struct PlayerVolumeSlider: View {
    let value: Double
    @Binding var isDragging: Bool
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let x = width * CGFloat(min(1, max(0, value / 100)))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28)).frame(height: 4)
                Capsule().fill(.white).frame(width: x, height: 4)
                Circle().fill(.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .offset(x: x - 6)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        onChange(Double(min(1, max(0, drag.location.x / width))) * 100)
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .frame(height: PlayerMetrics.hit)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(value)) percent")
    }
}
#endif

/// Seek bar: thickens on hover or drag, shows the buffered range and a time bubble above the knob; draggable.
struct PlayerScrubber: View {
    let current: Double
    let duration: Double?
    let buffered: Double?
    @Binding var scrubTime: Double?
    let onCommit: (Double) -> Void
    let onChange: () -> Void

    @State private var hoverX: CGFloat?
    /// Holds the knob at the committed target until the engine reports the new position, so it doesn't snap back.
    @State private var pendingTarget: Double?
    @State private var pendingTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let total = max(duration ?? 0, 0.001)
            let shown = scrubTime ?? pendingTarget ?? current
            let playedX = duration == nil ? 0 : width * CGFloat(min(1, max(0, shown / total)))
            let bufferedX = width * CGFloat(min(1, max(0, (buffered ?? 0) / total)))
            let previewX = previewX(width: width)
            let dragging = scrubTime != nil
            let active = previewX != nil || dragging
            let barHeight = active ? PlayerMetrics.scrubBar.active : PlayerMetrics.scrubBar.idle
            let knob = active ? PlayerMetrics.scrubKnob.active : PlayerMetrics.scrubKnob.idle
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22)).frame(height: barHeight)
                Capsule().fill(.white.opacity(0.45)).frame(width: max(bufferedX, playedX), height: barHeight)
                if let previewX, !dragging, previewX > playedX {
                    Capsule().fill(.white.opacity(0.3)).frame(width: previewX, height: barHeight)
                }
                Capsule().fill(Theme.Palette.progress).frame(width: playedX, height: barHeight)
                Circle()
                    .fill(Theme.Palette.progress)
                    .overlay(Circle().strokeBorder(.white.opacity(dragging ? 0.9 : 0), lineWidth: 2))
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.4), radius: dragging ? 6 : 3)
                    .offset(x: playedX - knob / 2)
                if duration != nil, let tipX = scrubTime.map({ CGFloat($0 / total) * width }) ?? previewX {
                    Text(PlayerTime.format(Double(tipX / width) * total))
                        .font(PlayerMetrics.timeFont.weight(.bold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .padding(.horizontal, Theme.Space.xs + 2)
                        .padding(.vertical, Theme.Space.xxs + 1)
                        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous).strokeBorder(Theme.Palette.stroke))
                        .fixedSize()
                        .position(x: min(max(tipX, 36), width - 36), y: geo.size.height / 2 - PlayerMetrics.scrubTipLift)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottom)))
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point): hoverX = min(max(0, point.x), width)
                case .ended: hoverX = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration != nil else { return }
                        scrubTime = Double(min(1, max(0, value.location.x / width))) * total
                        onChange()
                    }
                    .onEnded { value in
                        guard duration != nil else { return }
                        let target = Double(min(1, max(0, value.location.x / width))) * total
                        hold(target)
                        scrubTime = nil
                        onCommit(target)
                    }
            )
            .animation(.spring(response: 0.26, dampingFraction: 0.78), value: active)
        }
        .frame(height: PlayerMetrics.hit)
        .opacity(duration == nil ? 0.5 : 1)
        .sensoryFeedback(.impact(weight: .light), trigger: scrubTime == nil)
        .onChange(of: current) { _, now in
            if let target = pendingTarget, abs(now - target) < 2 { release() }
        }
        .onDisappear { pendingTask?.cancel() }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(PlayerTime.format(current))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onCommit(current + 10)
            case .decrement: onCommit(max(0, current - 10))
            @unknown default: break
            }
        }
    }

    private func hold(_ target: Double) {
        pendingTarget = target
        pendingTask?.cancel()
        pendingTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            pendingTarget = nil
        }
    }

    private func release() {
        pendingTask?.cancel()
        pendingTarget = nil
    }

    private func previewX(width: CGFloat) -> CGFloat? {
        if let hoverX { return hoverX }
        return PlayerDebugOptions.scrubPreview.map { CGFloat($0) * width }
    }
}
