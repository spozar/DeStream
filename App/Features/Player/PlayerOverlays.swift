import SwiftUI

/// "Continue watching?" card over the dimmed, blurred backdrop.
struct ResumePrompt: View {
    let request: PlaybackRequest
    let position: Double
    let duration: Double?
    let onResume: () -> Void
    let onStartOver: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            PlayerBackdrop(urlString: request.backgroundURL ?? request.posterURL)
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text("Continue watching?")
                        .font(Theme.Font.title)
                    Text(subtitleLine)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(2)
                }
                if let duration, duration > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        WatchProgressBar(fraction: position / duration, height: 4)
                        Text("\(PlayerTime.format(max(0, duration - position))) left")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Space.xs) { buttons }
                    VStack(spacing: Theme.Space.xs) { buttons }
                }
                .padding(.top, Theme.Space.xxs)
            }
            .padding(PlayerOverlayMetrics.cardPadding)
            .frame(maxWidth: PlayerOverlayMetrics.resumeWidth)
            .playerCard()
            .padding(Theme.Space.m)
            #if os(iOS)
            PlayerIconButton(systemName: "chevron.left", help: "Back", backdrop: true, action: onClose)
                .padding(.horizontal, PlayerMetrics.edge)
                .padding(.top, Theme.Space.s)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            #endif
        }
        .foregroundStyle(Theme.Palette.textPrimary)
    }

    @ViewBuilder private var buttons: some View {
        Button(action: onResume) {
            Label("Resume from \(PlayerTime.format(position))", systemImage: "play.fill")
        }
        .buttonStyle(.ds(.primary, fullWidth: true))
        .keyboardShortcut(.defaultAction)
        Button(action: onStartOver) {
            Label("Start over", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.ds(.secondary, fullWidth: true))
    }

    private var subtitleLine: String {
        [request.title, request.subtitle].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }
}

struct PlayerErrorOverlay: View {
    let failure: PlaybackFailure
    let canRetry: Bool
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.Palette.warning)
                .frame(width: 60, height: 60)
                .background(Theme.Palette.warning.opacity(0.14), in: Circle())
            VStack(spacing: Theme.Space.xs) {
                Text(failure.title)
                    .font(Theme.Font.rowTitle)
                    .multilineTextAlignment(.center)
                Text(failure.message)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Space.xs) {
                if canRetry {
                    Button(action: onClose) {
                        Text("Close")
                    }
                    .buttonStyle(.ds(.secondary, fullWidth: true))
                    .keyboardShortcut(.cancelAction)
                    Button(action: onRetry) {
                        Label("Try again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.ds(.primary, fullWidth: true))
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(action: onClose) {
                        Text("Close")
                    }
                    .buttonStyle(.ds(.primary, fullWidth: true))
                    .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.top, Theme.Space.xxs)
        }
        .foregroundStyle(Theme.Palette.textPrimary)
        .padding(PlayerOverlayMetrics.cardPadding)
        .frame(maxWidth: 420)
        .playerCard()
        .padding(Theme.Space.m)
    }
}

/// Spinner with the cache fill percentage when the engine reports it.
struct BufferingIndicator: View {
    let percent: Double?

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            PlayerSpinner()
                .frame(width: 44, height: 44)
            if let percent {
                Text("Buffering… \(Int(percent))%")
                    .font(Theme.Font.caption.monospacedDigit())
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .contentTransition(.numericText())
            }
        }
        .padding(Theme.Space.l)
        .background(Circle().fill(.black.opacity(0.35)).blur(radius: 20))
        .accessibilityElement()
        .accessibilityLabel(percent.map { "Buffering \(Int($0)) percent" } ?? "Loading")
    }
}

private struct PlayerSpinner: View {
    var body: some View {
        TimelineView(.animation) { context in
            let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(angle))
            }
        }
    }
}

/// Shown when playback reaches the end: the next episode when there is one, close the player, or watch again.
struct PlayerEndCard: View {
    let request: PlaybackRequest
    var next: (target: NextEpisodeModel.Target, phase: NextEpisodeModel.Phase)? = nil
    var onPlayNext: () -> Void = {}
    let onReplay: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text("Finished")
                    .font(Theme.Font.micro)
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text(request.title)
                    .font(Theme.Font.rowTitle)
                    .lineLimit(2)
                if let subtitle = request.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            if let next {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Button(action: onPlayNext) {
                        HStack(spacing: Theme.Space.xs) {
                            if next.phase == .loading { ProgressView().controlSize(.small) } else { Image(systemName: "play.fill") }
                            Text(next.phase == .loading ? "Finding Stream…" : "Next Episode · \(next.target.code ?? next.target.title)")
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.ds(.primary, fullWidth: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(next.phase == .loading)
                    if case .failed(let message) = next.phase {
                        Text(message)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: Theme.Space.xs) {
                // Playback also starts from Home, Downloads and Saved, so don't promise a return to the details page.
                Button(action: onClose) {
                    Label("Done", systemImage: "checkmark")
                }
                .buttonStyle(.ds(next == nil ? .primary : .secondary, fullWidth: true))
                .keyboardShortcut(next == nil ? .defaultAction : nil)
                Button(action: onReplay) {
                    Label("Watch again", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.ds(.secondary, fullWidth: true))
            }
        }
        .foregroundStyle(Theme.Palette.textPrimary)
        .padding(PlayerOverlayMetrics.cardPadding)
        .frame(maxWidth: 420)
        .playerCard()
        .padding(Theme.Space.m)
    }
}

private struct PlayerBackdrop: View {
    let urlString: String?

    var body: some View {
        ZStack {
            Color.black
            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill().blur(radius: 24).opacity(0.5)
                } placeholder: {
                    Color.clear
                }
            }
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        }
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private enum PlayerOverlayMetrics {
    #if os(macOS)
    static let cardPadding: CGFloat = Theme.Space.l
    static let resumeWidth: CGFloat = 400
    #else
    static let cardPadding: CGFloat = Theme.Space.l - 4
    static let resumeWidth: CGFloat = 460
    #endif
}

struct PlayerToastState: Equatable {
    var systemImage: String
    var text: String
    /// Bumped on every change so repeated presses re-trigger the transition.
    var tick: Int
}

/// Small capsule confirming a keyboard change (volume, mute, speed) while the controls may be hidden.
struct PlayerToast: View {
    let toast: PlayerToastState

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: toast.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22)
            Text(toast.text)
                .font(Theme.Font.headline.monospacedDigit())
                .contentTransition(.numericText())
        }
        .foregroundStyle(Theme.Palette.textPrimary)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.xs)
        .background(.black.opacity(0.72), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Palette.stroke))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .environment(\.colorScheme, .dark)
        .animation(Theme.Motion.fast, value: toast.text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(toast.text)
    }
}

enum SeekSide {
    case back, forward
}

struct SeekFeedback: Equatable {
    var side: SeekSide
    var seconds: Int
    /// Bumped on every tap so the icon bounces and haptics fire even when nothing else changes.
    var tick: Int
}

/// Double-tap seek feedback: a soft wash from the tapped edge with a bouncing icon and the accumulated seconds.
struct DoubleTapSeekIndicator: View {
    let feedback: SeekFeedback

    var body: some View {
        let forward = feedback.side == .forward
        GeometryReader { geo in
            ZStack {
                Ellipse()
                    .fill(.white.opacity(0.1))
                    .frame(width: geo.size.width * 0.7, height: geo.size.height * 1.6)
                    .offset(x: (forward ? 1 : -1) * geo.size.width * 0.42)
                VStack(spacing: Theme.Space.xs) {
                    Image(systemName: forward ? "forward.fill" : "backward.fill")
                        .font(.system(size: 26, weight: .bold))
                        .symbolEffect(.bounce, options: .speed(1.8), value: feedback.tick)
                    Text("\(feedback.seconds) seconds")
                        .font(Theme.Font.caption.monospacedDigit().weight(.bold))
                        .contentTransition(.numericText(value: Double(feedback.seconds)))
                }
                .foregroundStyle(Theme.Palette.textPrimary)
                .shadow(color: .black.opacity(0.4), radius: 4)
                .offset(x: (forward ? 1 : -1) * geo.size.width * 0.3)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

private extension View {
    func playerCard() -> some View {
        background(Theme.Palette.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(Theme.Palette.stroke))
            .shadow(color: .black.opacity(0.55), radius: 30, y: 12)
            .environment(\.colorScheme, .dark)
    }
}
