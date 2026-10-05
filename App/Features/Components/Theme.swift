import SwiftUI

/// DeStream design system. A dark, cinematic look (Netflix / Prime Video / Stremio) built natively.
/// Every feature view uses these tokens instead of system styling. OWNER: UI Agent 1 (Design System & Shell).
/// Existing names are a contract for the other UI agents: add freely, don't rename or remove.
enum Theme {
    // MARK: Colors
    enum Palette {
        /// Near-black canvas behind everything.
        static let canvas = Color(red: 0.055, green: 0.055, blue: 0.067)
        /// Raised surfaces: cards, rows, panels.
        static let surface = Color(red: 0.098, green: 0.098, blue: 0.118)
        static let surfaceHigh = Color(red: 0.145, green: 0.145, blue: 0.172)
        static let stroke = Color.white.opacity(0.08)
        /// Brand accent (violet, matches the app icon).
        static let accent = Color(red: 0.55, green: 0.36, blue: 1.0)
        static let accentSoft = Color(red: 0.55, green: 0.36, blue: 1.0).opacity(0.18)
        static let accentHover = Color(red: 0.63, green: 0.47, blue: 1.0)
        /// Two-stop brand gradient (logo wordmark, selected pills, hero highlights).
        static let accentGradient = LinearGradient(
            colors: [Color(red: 0.66, green: 0.45, blue: 1.0), Color(red: 0.42, green: 0.27, blue: 0.95)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        static let strokeStrong = Color.white.opacity(0.16)
        static let danger = Color(red: 1.0, green: 0.36, blue: 0.40)
        /// Sidebar / floating chrome base (sits under a material).
        static let chrome = Color(red: 0.07, green: 0.07, blue: 0.09)
        /// Progress bars / "watched" ticks.
        static let progress = Color(red: 0.90, green: 0.20, blue: 0.30)
        static let success = Color(red: 0.25, green: 0.80, blue: 0.50)
        static let warning = Color(red: 1.0, green: 0.70, blue: 0.25)
        static let textPrimary = Color.white
        static let textSecondary = Color.white.opacity(0.66)
        /// 0.5 keeps 12 pt captions at WCAG AA contrast (4.5:1) on both canvas and surface.
        static let textTertiary = Color.white.opacity(0.5)
    }

    // MARK: Spacing / radii
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
        #if os(macOS)
        static let page: CGFloat = 40
        #else
        static let page: CGFloat = 16
        #endif
    }

    enum Radius {
        static let s: CGFloat = 6
        static let m: CGFloat = 10
        static let l: CGFloat = 16
        static let pill: CGFloat = 999
    }

    // MARK: Typography (SF Pro, heavier display weights for a cinematic feel)
    enum Font {
        static let display = SwiftUI.Font.system(size: 44, weight: .heavy, design: .default)
        static let title = SwiftUI.Font.system(size: 28, weight: .bold)
        static let rowTitle = SwiftUI.Font.system(size: 19, weight: .bold)
        static let headline = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 14, weight: .regular)
        static let sectionTitle = SwiftUI.Font.system(size: 24, weight: .heavy)
        static let caption = SwiftUI.Font.system(size: 12, weight: .medium)
        static let micro = SwiftUI.Font.system(size: 10.5, weight: .bold)
    }

    // MARK: Scrims (legibility gradients for text over artwork)
    enum Scrim {
        /// Fades artwork into the canvas at the bottom (hero billboards, detail headers).
        static let bottom = LinearGradient(
            stops: [.init(color: Palette.canvas.opacity(0), location: 0),
                    .init(color: Palette.canvas.opacity(0.55), location: 0.55),
                    .init(color: Palette.canvas, location: 1)],
            startPoint: .top, endPoint: .bottom)
        /// Darkens the leading side where titles / buttons sit.
        static let left = LinearGradient(
            stops: [.init(color: Palette.canvas.opacity(0.92), location: 0),
                    .init(color: Palette.canvas.opacity(0.55), location: 0.4),
                    .init(color: Palette.canvas.opacity(0), location: 0.75)],
            startPoint: .leading, endPoint: .trailing)
        /// Subtle top darkening so the transparent title bar / traffic lights stay legible over images.
        static let top = LinearGradient(
            colors: [Color.black.opacity(0.55), Color.black.opacity(0)],
            startPoint: .top, endPoint: .bottom)
        /// Card caption scrim (text at the bottom of a landscape thumbnail).
        static let card = LinearGradient(
            colors: [Color.black.opacity(0), Color.black.opacity(0.85)],
            startPoint: .center, endPoint: .bottom)
    }

    // MARK: Layout
    enum Layout {
        #if os(macOS)
        /// Height reserved for the transparent title bar (traffic lights). Content that should not sit under it pads by this.
        static let titleBarInset: CGFloat = 28
        static let sidebarWidth: CGFloat = 228
        #else
        static let titleBarInset: CGFloat = 0
        static let sidebarWidth: CGFloat = 0
        #endif
    }

    // MARK: Controls (single source of truth for button / field sizing)
    enum Control {
        #if os(macOS)
        static let height: CGFloat = 40
        static let compactHeight: CGFloat = 28
        static let horizontalPadding: CGFloat = 22
        static let compactHorizontalPadding: CGFloat = 12
        static let radius: CGFloat = Radius.s
        static let compactRadius: CGFloat = Radius.s
        /// Smallest tappable size; controls drawn smaller extend their hit area to reach it.
        static let minHitTarget: CGFloat = 0
        static let fieldHeight: CGFloat = 0
        static let font = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let compactFont = SwiftUI.Font.system(size: 12, weight: .bold)
        #else
        static let height: CGFloat = 50
        static let compactHeight: CGFloat = 36
        static let horizontalPadding: CGFloat = 22
        static let compactHorizontalPadding: CGFloat = 14
        static let radius: CGFloat = 12
        static let compactRadius: CGFloat = 10
        static let minHitTarget: CGFloat = 44
        static let fieldHeight: CGFloat = 46
        static let font = SwiftUI.Font.system(size: 16, weight: .semibold)
        static let compactFont = SwiftUI.Font.system(size: 14, weight: .semibold)
        #endif
        /// Default diameter of `IconCircleButton`.
        #if os(macOS)
        static let iconCircle: CGFloat = 40
        #else
        static let iconCircle: CGFloat = 44
        #endif

        /// Negative inset that grows a control of `height` to the minimum hit target.
        static func hitInset(for height: CGFloat) -> CGFloat { min(0, (height - minHitTarget) / 2) }
    }

    // MARK: Motion
    enum Motion {
        static let hover = Animation.spring(response: 0.28, dampingFraction: 0.82)
        static let appear = Animation.easeOut(duration: 0.25)
        static let fast = Animation.easeOut(duration: 0.14)
        /// Finger-down on a control: quick and tight.
        static let press = Animation.spring(response: 0.2, dampingFraction: 0.7)
        /// Finger-up: slightly bouncy settle back to rest.
        static let release = Animation.spring(response: 0.38, dampingFraction: 0.6)
        /// Content swaps, list inserts/removals, expanding sections.
        static let content = Animation.spring(response: 0.42, dampingFraction: 0.86)
        /// Artwork fading in once loaded.
        static let imageFade = Animation.easeOut(duration: 0.3)
        /// Scale applied to pressed buttons / cards.
        static let pressedScale: CGFloat = 0.96
    }
}

extension EnvironmentValues {
    /// True while the enclosing `DSPressableStyle` button is pressed. Lets card content react to touches.
    @Entry var dsIsPressed = false
}

extension View {
    /// Soft haptic on touch-down (iOS only).
    func dsPressHaptic(_ pressed: Bool) -> some View {
        #if os(iOS)
        sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: pressed) { old, new in new && !old }
        #else
        self
        #endif
    }

    /// Selection-tick haptic whenever `value` changes (iOS only).
    func dsSelectionHaptic<V: Equatable>(_ value: V) -> some View {
        #if os(iOS)
        sensoryFeedback(.selection, trigger: value)
        #else
        self
        #endif
    }
}

/// Generic press feedback for tappable cards / rows (scale + dim + spring + haptic). Use instead of `.plain` on
/// buttons whose label is artwork or a card; the label can read `\.dsIsPressed` to react further.
struct DSPressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    var haptic = true

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .environment(\.dsIsPressed, pressed)
            .scaleEffect(pressed ? scale : 1)
            .opacity(pressed ? 0.88 : 1)
            .animation(pressed ? Theme.Motion.press : Theme.Motion.release, value: pressed)
            .dsPressHaptic(haptic && pressed)
    }
}

extension ButtonStyle where Self == DSPressableStyle {
    static var dsPressable: DSPressableStyle { DSPressableStyle() }
}

// MARK: - Shared primitives

/// Thin red/accent progress bar used on posters, landscape cards and episode rows.
struct WatchProgressBar: View {
    var fraction: Double
    var height: CGFloat = 4

    /// Clamped to 0...1; NaN/infinite (e.g. a zero duration) count as 0 instead of trapping in `Int(_:)`.
    private var clamped: Double { fraction.isFinite ? max(0, min(1, fraction)) : 0 }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(Theme.Palette.progress)
                    .frame(width: clamped * geo.size.width)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("\(Int((clamped * 100).rounded())) percent watched")
    }
}

/// Primary/secondary buttons with custom styling (not system bezels). Brightens on hover, dims when disabled.
/// `.primary` = white (Netflix "Play"), `.accent` = violet brand fill, `.secondary` = translucent, `.ghost` = outline,
/// `.destructive` = red tint. Heights come from `Theme.Control`, so every button of a kind matches on each platform.
struct DSButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, accent, destructive }
    var kind: Kind = .primary
    var compact = false
    /// Stretch to the available width (stacked phone actions).
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        DSButtonBody(configuration: configuration, kind: kind, compact: compact, fullWidth: fullWidth)
    }
}

private struct DSButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: DSButtonStyle.Kind
    let compact: Bool
    let fullWidth: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed
        let height = compact ? Theme.Control.compactHeight : Theme.Control.height
        let shape = RoundedRectangle(cornerRadius: compact ? Theme.Control.compactRadius : Theme.Control.radius, style: .continuous)
        configuration.label
            .font(compact ? Theme.Control.compactFont : Theme.Control.font)
            .labelStyle(DSButtonLabelStyle(spacing: compact ? 5 : 8))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, compact ? Theme.Control.compactHorizontalPadding : Theme.Control.horizontalPadding)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .foregroundStyle(foreground)
            .background(background(highlighted: hovering || pressed), in: shape)
            .overlay {
                if kind == .ghost {
                    shape.strokeBorder(Color.white.opacity(hovering || pressed ? 0.35 : 0.18))
                }
            }
            .contentShape(shape.inset(by: Theme.Control.hitInset(for: height)))
            .scaleEffect(pressed ? Theme.Motion.pressedScale : 1)
            .opacity(isEnabled ? (pressed ? 0.85 : 1) : 0.45)
            .animation(pressed ? Theme.Motion.press : Theme.Motion.release, value: pressed)
            .animation(Theme.Motion.fast, value: hovering)
            .onHover { hovering = $0 && isEnabled }
            .dsPressHaptic(pressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: .black
        case .destructive: Theme.Palette.danger
        default: Theme.Palette.textPrimary
        }
    }

    private func background(highlighted: Bool) -> Color {
        switch kind {
        case .primary: highlighted ? Color.white.opacity(0.85) : .white
        case .accent: highlighted ? Theme.Palette.accentHover : Theme.Palette.accent
        case .secondary: Color.white.opacity(highlighted ? 0.24 : 0.15)
        case .ghost: Color.white.opacity(highlighted ? 0.08 : 0)
        case .destructive: Theme.Palette.danger.opacity(highlighted ? 0.24 : 0.14)
        }
    }
}

private struct DSButtonLabelStyle: LabelStyle {
    var spacing: CGFloat = 7
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon.imageScale(.medium)
            configuration.title
        }
    }
}

extension ButtonStyle where Self == DSButtonStyle {
    static var dsPrimary: DSButtonStyle { DSButtonStyle(kind: .primary) }
    static var dsSecondary: DSButtonStyle { DSButtonStyle(kind: .secondary) }
    static var dsGhost: DSButtonStyle { DSButtonStyle(kind: .ghost) }
    static var dsAccent: DSButtonStyle { DSButtonStyle(kind: .accent) }
    static func ds(_ kind: DSButtonStyle.Kind, compact: Bool = false) -> DSButtonStyle { DSButtonStyle(kind: kind, compact: compact) }
    static func ds(_ kind: DSButtonStyle.Kind, compact: Bool = false, fullWidth: Bool) -> DSButtonStyle {
        DSButtonStyle(kind: kind, compact: compact, fullWidth: fullWidth)
    }
}

/// Section header for horizontal rows ("Continue Watching", "Popular — Movies").
struct RowHeader: View {
    var title: String
    var subtitle: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            Text(title).font(Theme.Font.rowTitle).foregroundStyle(Theme.Palette.textPrimary)
            if let subtitle {
                Text(subtitle).font(Theme.Font.caption).foregroundStyle(Theme.Palette.textTertiary)
            }
            Spacer()
        }
    }
}

/// Small rounded badge ("4K", "Cached", "HDR", "S01E03").
struct Badge: View {
    var text: String
    var systemImage: String? = nil
    var tint: Color = .white
    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(Theme.Font.micro)
        .foregroundStyle(tint)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .fixedSize()
    }
}

/// Watched tick shown on episode rows / posters.
struct WatchedCheck: View {
    var size: CGFloat = 20
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: size * 0.5, weight: .black))
            .foregroundStyle(.black)
            .frame(width: size, height: size)
            .background(Theme.Palette.success, in: Circle())
            .accessibilityLabel("Watched")
    }
}

extension View {
    /// Page background for every top-level screen.
    func dsCanvas() -> some View {
        background(Theme.Palette.canvas.ignoresSafeArea())
            .preferredColorScheme(.dark)
    }
}

// MARK: - Additional primitives

/// Large page/section title ("Addons", "Downloads") with an optional trailing accessory.
struct SectionTitle<Accessory: View>: View {
    var title: String
    var subtitle: String? = nil
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(title)
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            Spacer(minLength: 0)
            accessory
        }
        .accessibilityElement(children: .contain)
    }
}

extension SectionTitle where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Round translucent icon button used on heroes, the player and card overlays.
struct IconCircleButton: View {
    var systemImage: String
    var size: CGFloat = Theme.Control.iconCircle
    var label: String
    /// Filled (white) variant, e.g. a big play button.
    var prominent = false
    var action: () -> Void

    init(_ systemImage: String, label: String, size: CGFloat = Theme.Control.iconCircle, prominent: Bool = false, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.size = size
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: (size * 0.4).rounded(), weight: .bold))
                .frame(width: size, height: size)
        }
        .buttonStyle(IconCircleButtonStyle(prominent: prominent))
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Style behind `IconCircleButton`; usable directly on any icon-only Button label sized by the caller.
struct IconCircleButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        IconCircleBody(configuration: configuration, prominent: prominent)
    }
}

private struct IconCircleBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed
        let lit = hovering || pressed
        configuration.label
            .foregroundStyle(prominent ? Color.black : Color.white)
            .background {
                if prominent {
                    Circle().fill(Color.white.opacity(lit ? 0.85 : 1))
                } else {
                    Circle().fill(.ultraThinMaterial)
                        .overlay(Circle().fill(Color.white.opacity(lit ? 0.18 : 0.06)))
                }
            }
            .overlay(Circle().strokeBorder(Color.white.opacity(prominent ? 0 : (lit ? 0.5 : 0.22)), lineWidth: 1))
            .clipShape(Circle())
            .contentShape(Circle().inset(by: Theme.Control.hitInset(for: Theme.Control.compactHeight)))
            .scaleEffect(pressed ? 0.9 : (hovering ? 1.06 : 1))
            .opacity(isEnabled ? 1 : 0.4)
            .animation(Theme.Motion.hover, value: hovering)
            .animation(pressed ? Theme.Motion.press : Theme.Motion.release, value: pressed)
            .onHover { hovering = $0 && isEnabled }
            .dsPressHaptic(pressed)
            .environment(\.colorScheme, .dark)
    }
}

/// Frosted dark panel: material + tint + hairline stroke. Use for floating chrome (player bars, sidebars, popovers).
struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = Theme.Radius.l
    var tint: Color = Theme.Palette.chrome.opacity(0.55)

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(tint))
            }
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.Palette.stroke))
            .environment(\.colorScheme, .dark)
    }
}

/// Solid raised card on the canvas (settings groups, list rows, empty states).
struct DSCard: ViewModifier {
    var padding: CGFloat = Theme.Space.l
    var cornerRadius: CGFloat = Theme.Radius.l
    var fill: Color = Theme.Palette.surface

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.Palette.stroke))
    }
}

/// Hover-focus for artwork cards: scale up, accent/white ring, deeper shadow. Pass the card's corner radius.
struct DSHoverFocus: ViewModifier {
    var cornerRadius: CGFloat = Theme.Radius.m
    var scale: CGFloat = 1.05
    var ring = true
    @State private var hovering = false
    @Environment(\.dsIsPressed) private var pressed

    func body(content: Content) -> some View {
        content
            .overlay {
                if ring {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(hovering ? 0.85 : 0), lineWidth: 2)
                }
            }
            .scaleEffect(hovering ? scale : 1)
            .shadow(color: .black.opacity(hovering ? 0.55 : (pressed ? 0.15 : 0.25)), radius: hovering ? 18 : (pressed ? 3 : 6), y: hovering ? 10 : (pressed ? 1 : 3))
            .zIndex(hovering ? 1 : 0)
            .animation(Theme.Motion.hover, value: hovering)
            .animation(Theme.Motion.fast, value: pressed)
            .onHover { hovering = $0 }
    }
}

/// Animated loading placeholder (skeleton) — a surface with a moving highlight.
struct ShimmerPlaceholder: View {
    var cornerRadius: CGFloat = Theme.Radius.m

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Theme.Palette.surface)
            .skeletonShimmer()
            .accessibilityHidden(true)
    }
}

/// Centered empty / error state: big icon, title, message, optional action.
struct DSEmptyState<Actions: View>: View {
    var systemImage: String
    var title: String
    var message: String? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Theme.Palette.accentGradient)
                .frame(width: 96, height: 96)
                .background(Theme.Palette.accentSoft, in: Circle())
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.Font.title)
                .foregroundStyle(Theme.Palette.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let message {
                Text(message)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            actions.padding(.top, Theme.Space.xs)
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension DSEmptyState where Actions == EmptyView {
    init(systemImage: String, title: String, message: String? = nil) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

/// Text field chrome matching the dark design (wrap any TextField/SecureField).
struct DSFieldBackground: ViewModifier {
    var focused = false
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .frame(minHeight: Theme.Control.fieldHeight)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .strokeBorder(focused ? Theme.Palette.accent : Theme.Palette.strokeStrong, lineWidth: focused ? 1.5 : 1))
    }
}

extension View {
    /// Frosted floating panel.
    func glassPanel(cornerRadius: CGFloat = Theme.Radius.l) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius))
    }
    /// Solid raised card.
    func dsCard(padding: CGFloat = Theme.Space.l, cornerRadius: CGFloat = Theme.Radius.l) -> some View {
        modifier(DSCard(padding: padding, cornerRadius: cornerRadius))
    }
    /// Hover scale + ring + shadow for artwork cards.
    func dsHoverFocus(cornerRadius: CGFloat = Theme.Radius.m, scale: CGFloat = 1.05, ring: Bool = true) -> some View {
        modifier(DSHoverFocus(cornerRadius: cornerRadius, scale: scale, ring: ring))
    }
    /// Dark text-field chrome.
    func dsField(focused: Bool = false) -> some View {
        modifier(DSFieldBackground(focused: focused))
    }
    /// Standard page padding for scrollable screens (horizontal page gutter + vertical rhythm).
    func dsPagePadding() -> some View {
        padding(.horizontal, Theme.Space.page).padding(.vertical, Theme.Space.l)
    }
}

/// Custom accent switch (doesn't fall back to grey when the window is inactive like the system switch).
struct DSSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: Theme.Space.s) {
                configuration.label
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn ? AnyShapeStyle(Theme.Palette.accentGradient) : AnyShapeStyle(Color.white.opacity(0.16)))
                        .frame(width: 44, height: 26)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(configuration.isOn ? 0 : 0.1)))
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .frame(width: 20, height: 20)
                        .padding(3)
                }
                .animation(Theme.Motion.hover, value: configuration.isOn)
            }
            .frame(minHeight: Theme.Control.minHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dsSelectionHaptic(configuration.isOn)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

extension ToggleStyle where Self == DSSwitchToggleStyle {
    static var dsSwitch: DSSwitchToggleStyle { DSSwitchToggleStyle() }
}

/// Pages draw their own large in-content title. On iOS the navigation bar would repeat it, so root
/// pages hide the bar and pushed pages keep only a small inline title next to the back button.
private struct DSPageTitle: ViewModifier {
    var title: String
    @Environment(\.isPresented) private var isPushed

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(isPushed ? .visible : .hidden, for: .navigationBar)
        #else
        content.navigationTitle(title)
        #endif
    }
}

extension View {
    func dsPageTitle(_ title: String) -> some View { modifier(DSPageTitle(title: title)) }
}
