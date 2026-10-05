import SwiftUI
#if os(macOS)
import AppKit
#endif

// Shared building blocks for the Downloads and Saved screens. OWNER: UI Agent 5.

// MARK: - Watch state

/// Resolved progress for one video, merging ProgressStore (preferred) with the sidecar's offline copy.
struct LibWatchState: Equatable {
    var seconds: Double = 0
    var duration: Double?

    var fraction: Double {
        guard let duration, duration > 0 else { return 0 }
        return min(1, max(0, seconds / duration))
    }
    var isWatched: Bool { fraction >= ProgressStore.finishedFraction }
    /// Position to resume from, or nil to start at the beginning.
    var resumeAt: Double? {
        guard !isWatched, seconds > ProgressStore.minimumResumeSeconds else { return nil }
        if let duration, seconds >= duration { return nil }
        return seconds
    }
    var isInProgress: Bool { resumeAt != nil }
    var remainingText: String? { ProgressStore.remainingText(seconds: seconds, duration: duration) }

    /// "Resume at 28:10 · 32 min left", "Watched", or nil when not started.
    var statusText: String? {
        if isWatched { return "Watched" }
        guard let resumeAt else { return nil }
        return ["Resume at \(LibFormat.clock(resumeAt))", remainingText].compactMap { $0 }.joined(separator: " · ")
    }

    @MainActor
    static func resolve(videoId: String, sidecar: SidecarMeta.SidecarItem?, progress: ProgressStore) -> LibWatchState {
        if let entry = progress.entry(for: videoId) {
            return LibWatchState(seconds: entry.seconds, duration: entry.duration ?? sidecar?.durationSeconds)
        }
        return LibWatchState(seconds: sidecar?.progressSeconds ?? 0, duration: sidecar?.durationSeconds)
    }
}

// MARK: - Formatting

enum LibFormat {
    /// 1690 → "28:10", 3725 → "1:02:05".
    static func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds.isFinite ? seconds : 0))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// 3388 → "56 min", 7300 → "2 h 1 min".
    static func runtime(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        let total = Int((seconds / 60).rounded())
        if total < 60 { return "\(max(1, total)) min" }
        let h = total / 60, m = total % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// Compact ETA: "45 s", "2 min", "1 h 5 min".
    static func eta(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s) s" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}

/// Quality tags inferred from a release file name ("…2160p…DV.HDR…Atmos…" → 4K, Dolby Vision, HDR, Atmos).
enum LibReleaseTags {
    static func from(_ filename: String?) -> [String] {
        guard let filename else { return [] }
        let tokens = Set(filename.uppercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        var tags: [String] = []
        if tokens.contains("2160P") || tokens.contains("4K") || tokens.contains("UHD") { tags.append("4K") }
        else if tokens.contains("1080P") { tags.append("1080p") }
        else if tokens.contains("720P") { tags.append("720p") }
        if tokens.contains("DV") || tokens.contains("DOVI") { tags.append("Dolby Vision") }
        if tokens.contains(where: { $0.hasPrefix("HDR") }) { tags.append("HDR") }
        if tokens.contains("ATMOS") { tags.append("Atmos") }
        return tags
    }
}

// MARK: - Artwork

/// Local artwork for a title folder (works for in-flight downloads too, since art is written at enqueue).
struct LibArtwork: View {
    enum Kind { case poster, landscape }
    var folder: URL?
    var name: String
    var kind: Kind
    var maxPixelSize: Int = 900

    var body: some View {
        LocalImage(url: primaryURL, maxPixelSize: maxPixelSize) {
            if let secondaryURL {
                LocalImage(url: secondaryURL, maxPixelSize: maxPixelSize) { LibArtworkPlaceholder(name: name) }
            } else {
                LibArtworkPlaceholder(name: name)
            }
        }
        .aspectRatio(contentMode: .fill)
    }

    private var poster: URL? { folder?.appendingPathComponent(LibraryWriter.posterFileName) }
    private var backdrop: URL? { folder?.appendingPathComponent(LibraryWriter.backdropFileName) }
    private var primaryURL: URL? { kind == .poster ? poster : backdrop }
    private var secondaryURL: URL? { kind == .poster ? backdrop : poster }
}

/// Gradient tile with the title's initials, used when no artwork is on disk.
struct LibArtworkPlaceholder: View {
    var name: String

    var body: some View {
        ZStack {
            LinearGradient(colors: [hue.opacity(0.85), Theme.Palette.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.10), .clear], center: .topLeading, startRadius: 0, endRadius: 260)
            Text(initials)
                .font(.system(size: 40, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .minimumScaleFactor(0.4)
                .padding(8)
        }
        .accessibilityHidden(true)
    }

    private var initials: String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2)
        let s = words.compactMap(\.first).map { String($0).uppercased() }.joined()
        return s.isEmpty ? "?" : s
    }

    private var hue: Color {
        let palette: [Color] = [Theme.Palette.accent, Theme.Palette.progress, .teal, .indigo, .orange, .pink, .blue]
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[abs(sum) % palette.count]
    }
}

// MARK: - Controls

/// Control sizing shared by every Downloads/Saved action so text buttons and icon buttons line up.
/// Heights follow `Theme.Control`; icon circles use the same diameter as the text buttons beside them.
enum LibMetrics {
    static let control = Theme.Control.height
    static let compactControl = Theme.Control.compactHeight
    static let minHit = Theme.Control.minHitTarget
    #if os(macOS)
    static let expandsActions = false
    static let isTouch = false
    #else
    static let expandsActions = true
    static let isTouch = true
    #endif
}

@MainActor enum LibMotion {
    static let spring = Theme.Motion.content
    static let snappy = Animation.snappy(duration: 0.3)
    static let card = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.96)),
        removal: .opacity.combined(with: .scale(scale: 0.92)))
}

/// Round icon control; usable on Button or NavigationLink. The diameter matches `DSButtonStyle` heights.
struct LibIconButtonStyle: ButtonStyle {
    var size: CGFloat = LibMetrics.control
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        LibIconBody(configuration: configuration, size: size, destructive: destructive)
    }
}

private struct LibIconBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    let destructive: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: max(13, size * 0.34), weight: .bold))
            .foregroundStyle(hovering && destructive ? Theme.Palette.danger : Theme.Palette.textPrimary)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.white.opacity(hovering || pressed ? 0.22 : 0.12)))
            .overlay(Circle().strokeBorder(Color.white.opacity(hovering ? 0.25 : 0.08)))
            .contentShape(Circle().inset(by: Theme.Control.hitInset(for: size)))
            .scaleEffect(pressed ? 0.9 : 1)
            .opacity(isEnabled ? (pressed ? 0.85 : 1) : 0.4)
            .animation(pressed ? Theme.Motion.press : Theme.Motion.release, value: pressed)
            .animation(Theme.Motion.hover, value: hovering)
            .onHover { hovering = $0 && isEnabled }
            .dsPressHaptic(pressed)
    }
}

/// Round icon button (Show in Finder, Remove, Cancel…) with hover highlight and tooltip.
struct LibIconButton: View {
    var title: String
    var systemImage: String
    var size: CGFloat = LibMetrics.control
    var role: ButtonRole? = nil
    /// VoiceOver label when the tooltip alone doesn't say what the button acts on ("Delete S01E02").
    var accessibilityTitle: String? = nil
    var action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(LibIconButtonStyle(size: size, destructive: role == .destructive))
        .help(title)
        .accessibilityLabel(accessibilityTitle ?? title)
    }
}

/// Primary call to action ("▶ Resume", "▶ Play"), same height as the icon buttons beside it.
struct LibPlayButton: View {
    var title: String
    var systemImage: String = "play.fill"
    var expands = LibMetrics.expandsActions
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .contentTransition(.numericText())
        }
        .buttonStyle(.ds(.primary, fullWidth: expands))
        .animation(LibMotion.snappy, value: title)
    }
}

/// One line of badges that drops trailing badges instead of overflowing on narrow widths.
struct LibBadgeRow: View {
    struct Item: Hashable {
        var text: String
        var systemImage: String? = nil
        var tint: Color = .white
    }
    var items: [Item]
    var spacing: CGFloat = Theme.Space.xxs

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach((0..<items.count).reversed(), id: \.self) { last in
                HStack(spacing: spacing) {
                    ForEach(items[...last], id: \.self) { Badge(text: $0.text, systemImage: $0.systemImage, tint: $0.tint) }
                }
            }
            Color.clear.frame(width: 0, height: 0)
        }
    }
}

/// Thick download progress bar with an accent gradient; greys out (animated) while paused.
struct LibTransferBar: View {
    var fraction: Double
    var paused = false
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let width = max(height, max(0, min(1, fraction)) * geo.size.width)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                ZStack {
                    Capsule().fill(Color.white.opacity(0.35))
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.Palette.accent, Color(red: 0.75, green: 0.5, blue: 1)],
                                             startPoint: .leading, endPoint: .trailing))
                        .shadow(color: Theme.Palette.accent.opacity(0.6), radius: 6)
                        .opacity(paused ? 0 : 1)
                }
                .frame(width: width)
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.5), value: fraction)
        .animation(.easeInOut(duration: 0.3), value: paused)
        .accessibilityElement()
        .accessibilityLabel("Download progress")
        .accessibilityValue("\(Int(max(0, min(1, fraction)) * 100)) percent")
    }
}

// MARK: - Page chrome

/// Big in-page header ("Downloads" + summary line) with optional trailing actions.
struct LibPageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title).font(Theme.Font.title).foregroundStyle(Theme.Palette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Font.headline)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .monospacedDigit()
                        .lineLimit(2)
                        .contentTransition(.numericText())
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
    }
}

extension LibPageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String?) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Section title with a count pill and optional trailing control.
struct LibrarySectionHeader<Trailing: View>: View {
    var title: String
    var count: Int?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.xs) {
            Text(title).font(Theme.Font.rowTitle).foregroundStyle(Theme.Palette.textPrimary)
            if let count {
                Text("\(count)")
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
                    .contentTransition(.numericText(value: Double(count)))
            }
            Spacer(minLength: 0)
            trailing()
        }
    }
}

extension LibrarySectionHeader where Trailing == EmptyView {
    init(title: String, count: Int?) { self.init(title: title, count: count) { EmptyView() } }
}

/// Illustration-like empty/unavailable state: layered glow, a hero symbol and orbiting satellites.
struct LibraryEmptyState<Actions: View>: View {
    var symbol: String
    var satellites: [String]
    var title: String
    var message: String
    var tint: Color = Theme.Palette.accent
    @ViewBuilder var actions: () -> Actions
    @State private var appeared = false

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            ZStack {
                Circle().fill(RadialGradient(colors: [tint.opacity(0.35), .clear], center: .center, startRadius: 4, endRadius: 120))
                    .frame(width: 240, height: 240)
                Circle().strokeBorder(Color.white.opacity(0.07), lineWidth: 1).frame(width: 190, height: 190)
                Circle().strokeBorder(Color.white.opacity(0.05), lineWidth: 1).frame(width: 136, height: 136)
                ForEach(Array(satellites.prefix(3).enumerated()), id: \.offset) { index, name in
                    Image(systemName: name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(Theme.Palette.surfaceHigh))
                        .overlay(Circle().strokeBorder(Theme.Palette.stroke))
                        .offset(appeared ? satelliteOffset(index) : .zero)
                        .opacity(appeared ? 1 : 0)
                }
                Image(systemName: symbol)
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 96, height: 96)
                    .background(Circle().fill(LinearGradient(colors: [tint, tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .shadow(color: tint.opacity(0.55), radius: 24, y: 8)
                    .scaleEffect(appeared ? 1 : 0.8)
            }
            .frame(width: 240, height: 240)
            .accessibilityHidden(true)
            VStack(spacing: Theme.Space.xs) {
                Text(title).font(Theme.Font.title).foregroundStyle(Theme.Palette.textPrimary).multilineTextAlignment(.center)
                Text(message)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.s) { actions() }
                VStack(spacing: Theme.Space.xs) { actions() }
            }
            .opacity(appeared ? 1 : 0)
        }
        .padding(.horizontal, Theme.Space.page)
        .padding(.vertical, Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.78)) { appeared = true } }
    }

    private func satelliteOffset(_ index: Int) -> CGSize {
        let angles: [Double] = [-35, 200, 95]
        let r = 95.0, a = angles[index] * .pi / 180
        return CGSize(width: cos(a) * r, height: sin(a) * r)
    }
}

extension View {
    /// Rounds the long-press context-menu preview on iOS to match the card.
    func libContextMenuShape(_ cornerRadius: CGFloat) -> some View {
        #if os(iOS)
        contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        #else
        self
        #endif
    }
}

/// Bottom-to-top darkening so text is readable over artwork.
struct LibScrim: View {
    var strength: Double = 0.85
    var body: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0.35),
            .init(color: .black.opacity(strength * 0.6), location: 0.65),
            .init(color: .black.opacity(strength), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}

enum LibFinder {
    #if os(macOS)
    static func show(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    #endif
}
