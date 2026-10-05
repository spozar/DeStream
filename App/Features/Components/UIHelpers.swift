import SwiftUI

extension Color {
    /// Page background; matches the design system canvas.
    static var appBackground: Color { Theme.Palette.canvas }
}

enum UIMetrics {
    #if os(macOS)
    static let posterWidth: CGFloat = 156
    static let landscapeWidth: CGFloat = 320
    static let pagePadding: CGFloat = Theme.Space.page
    static let heroHeight: CGFloat = 460
    /// How far the first Home row tucks up into the billboard's bottom fade.
    static let billboardOverlap: CGFloat = 72
    static let rowSpacing: CGFloat = 14
    #else
    static let posterWidth: CGFloat = 112
    static let landscapeWidth: CGFloat = 250
    static let pagePadding: CGFloat = Theme.Space.page
    static let heroHeight: CGFloat = 320
    static let billboardOverlap: CGFloat = 36
    static let rowSpacing: CGFloat = 10
    #endif
}

enum DisplayFormat {
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()

    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFractional.date(from: s) ?? iso.date(from: s)
    }

    static func date(_ s: String?) -> String? {
        parseDate(s)?.formatted(date: .abbreviated, time: .omitted)
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// "movie" → "Movies", "series" → "Series", anything else capitalized.
    static func typeLabel(_ type: String) -> String {
        switch type {
        case "movie": "Movies"
        case "series": "Series"
        case "tv": "TV"
        default: type.capitalized
        }
    }

    /// "movie" → "Movie", "series" → "Series".
    static func singularTypeLabel(_ type: String) -> String {
        switch type {
        case "movie": "Movie"
        case "series": "Series"
        case "tv": "TV"
        default: type.capitalized
        }
    }

    /// "7.8" from addon ratings like "7.8" / "7.80"; nil for empty or zero.
    static func rating(_ s: String?) -> String? {
        guard let s, let value = Double(s), value > 0 else { return nil }
        return String(format: "%.1f", value)
    }
}

/// Lift + shadow on pointer hover (macOS, iPad pointer). On touch, the shadow settles while pressed inside a
/// `.dsPressable` button (the style itself does the press-in scale).
struct HoverLift: ViewModifier {
    var scale: CGFloat = 1.04
    @State private var hovering = false
    @Environment(\.dsIsPressed) private var pressed

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? scale : 1)
            .shadow(color: .black.opacity(hovering ? 0.55 : (pressed ? 0.15 : 0.25)), radius: hovering ? 18 : (pressed ? 3 : 6), y: hovering ? 10 : (pressed ? 1 : 3))
            .animation(Theme.Motion.hover, value: hovering)
            .animation(Theme.Motion.fast, value: pressed)
            .onHover { hovering = $0 }
    }
}

/// Rounded surface that brightens on hover or touch; `selected` uses the accent tint.
struct HoverCard: ViewModifier {
    var selected = false
    var cornerRadius: CGFloat = 12
    @State private var hovering = false
    @Environment(\.dsIsPressed) private var pressed

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(selected ? Theme.Palette.accentSoft : (hovering || pressed) ? Theme.Palette.surfaceHigh : Theme.Palette.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(selected ? Theme.Palette.accent.opacity(0.6) : Theme.Palette.stroke, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(Theme.Motion.fast, value: pressed)
            .animation(Theme.Motion.hover, value: selected)
            .onHover { hovering = $0 }
    }
}

/// Highlight band sweeping across a skeleton. Driven by a shared clock in global coordinates, so every
/// skeleton on screen shimmers as one continuous sweep instead of each running its own out-of-phase loop.
struct SkeletonShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let period: Double = 1.9
    private static let sweep: Double = 1.4
    private static let band: CGFloat = 220
    #if os(macOS)
    private static let span: CGFloat = 1800
    #else
    private static let span: CGFloat = 1000
    #endif

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    TimelineView(.animation) { context in
                        GeometryReader { geo in
                            LinearGradient(stops: [.init(color: .clear, location: 0),
                                                   .init(color: .white.opacity(0.08), location: 0.5),
                                                   .init(color: .clear, location: 1)],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: Self.band)
                                .offset(x: Self.bandX(at: context.date) - geo.frame(in: .global).minX)
                        }
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
    }

    private static func bandX(at date: Date) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / sweep
        let p = min(1, t)
        let eased = p * p * (3 - 2 * p)
        return -band + CGFloat(eased) * (span + band)
    }
}

extension View {
    func hoverLift(scale: CGFloat = 1.04) -> some View { modifier(HoverLift(scale: scale)) }
    func hoverCard(selected: Bool = false, cornerRadius: CGFloat = 12) -> some View {
        modifier(HoverCard(selected: selected, cornerRadius: cornerRadius))
    }
    func skeletonShimmer() -> some View { modifier(SkeletonShimmer()) }
}

/// A rounded block used to build loading skeletons.
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var cornerRadius: CGFloat = Theme.Radius.s

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Theme.Palette.surfaceHigh.opacity(0.7))
            .frame(width: width, height: height)
            .skeletonShimmer()
    }
}

/// Small capsule label (addon names, genres, badges).
struct Pill: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text).lineLimit(1)
        }
        .font(Theme.Font.micro)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(tint)
        .background(tint.opacity(0.16), in: Capsule())
    }
}

/// Centered icon + title + message for empty pages ("No results", "Add an addon").
struct BrowsePlaceholder: View {
    var systemImage: String
    var title: String
    var message: String? = nil

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 72, height: 72)
                .background(Theme.Palette.surfaceHigh, in: Circle())
                .overlay(Circle().strokeBorder(Theme.Palette.stroke))
                .accessibilityHidden(true)
            VStack(spacing: Theme.Space.xs) {
                Text(title)
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if let message {
                    Text(message)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity)
    }
}
