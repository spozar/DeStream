import SwiftUI

/// Building blocks for the custom (non-Form) settings screens. OWNER: UI Agent 1.

/// Scrollable page on the dark canvas with a large title.
struct SettingsPage<Content: View, Accessory: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                SectionTitle(title: title, subtitle: subtitle) { accessory }
                    .padding(.bottom, Theme.Space.xxs)
                content
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, SettingsMetrics.pageGutter)
            .padding(.top, SettingsMetrics.pageTop)
            .padding(.bottom, Theme.Space.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .dsCanvas()
        .dsPageTitle(title)
    }
}

extension SettingsPage where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

/// Titled group card ("Library", "Playback").
struct SettingsCard<Content: View>: View {
    var title: String
    var systemImage: String
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.Palette.accentHover)
                    .frame(width: 30, height: 30)
                    .background(Theme.Palette.accentSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title)
                    .font(Theme.Font.rowTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            if let footer {
                Text(footer)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .dsCard(padding: SettingsMetrics.cardPadding)
    }
}

/// One labeled row inside a SettingsCard, with a hairline divider above all but the first.
struct SettingsRow<Trailing: View>: View {
    var title: String
    var detail: String?
    var divider = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            if divider { Rectangle().fill(Theme.Palette.stroke).frame(height: 1) }
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(Theme.Font.headline)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    if let detail {
                        Text(detail)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Theme.Space.m)
                trailing
            }
            .padding(.vertical, SettingsMetrics.rowPadding)
            .frame(minHeight: SettingsMetrics.rowMinHeight)
        }
    }
}

/// Accent-tinted switch.
struct DSToggle: View {
    var label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) { EmptyView() }
            .toggleStyle(.dsSwitch)
            .accessibilityLabel(label)
    }
}

/// Compact − value + stepper with custom chrome.
struct DSStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var label: String

    var body: some View {
        HStack(spacing: 0) {
            step("minus", enabled: value > range.lowerBound) { value -= 1 }
            Text("\(value)")
                .font(Theme.Font.headline.monospacedDigit())
                .foregroundStyle(Theme.Palette.textPrimary)
                .contentTransition(.numericText(value: Double(value)))
                .animation(.snappy(duration: 0.25), value: value)
                .frame(minWidth: 34)
            step("plus", enabled: value < range.upperBound) { value += 1 }
        }
        .padding(3)
        .background(Color.black.opacity(0.35), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Palette.strokeStrong))
        .dsSelectionHaptic(value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if value < range.upperBound { value += 1 }
            case .decrement: if value > range.lowerBound { value -= 1 }
            @unknown default: break
            }
        }
    }

    private func step(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: SettingsMetrics.smallGlyph, weight: .heavy))
                .frame(width: SettingsMetrics.smallButton, height: SettingsMetrics.smallButton)
                .foregroundStyle(Theme.Palette.textPrimary)
                .background(Color.white.opacity(0.1), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(SettingsPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .animation(Theme.Motion.fast, value: enabled)
    }
}

/// Pop-up menu showing the current choice in a capsule, for picking one of a list of values.
struct DSMenuPicker<Value: Hashable>: View {
    var label: String
    @Binding var selection: Value
    var options: [(value: Value, title: String)]

    var body: some View {
        Menu {
            Picker(label, selection: $selection) {
                ForEach(options.indices, id: \.self) { i in
                    Text(options[i].title).tag(options[i].value)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: Theme.Space.xxs + 2) {
                Text(options.first { $0.value == selection }?.title ?? "")
                    .font(Theme.Font.headline)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.horizontal, Theme.Space.s)
            .frame(minHeight: SettingsMetrics.smallButton + 6)
            .background(Color.black.opacity(0.35), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.Palette.strokeStrong))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .dsSelectionHaptic(selection)
        .accessibilityLabel(label)
    }
}

/// Shared sizes for the settings screens; iPhone gets touch-sized controls and tighter cards.
enum SettingsMetrics {
    #if os(macOS)
    static let pageGutter: CGFloat = Theme.Space.page + Theme.Space.xxs
    static let pageTop: CGFloat = Theme.Space.xxl
    static let sectionSpacing: CGFloat = Theme.Space.l
    static let cardPadding: CGFloat = Theme.Space.l
    static let cardSpacing: CGFloat = Theme.Space.m
    static let rowPadding: CGFloat = Theme.Space.s + 2
    static let rowMinHeight: CGFloat = 0
    static let smallButton: CGFloat = 28
    static let smallGlyph: CGFloat = 11
    #else
    static let pageGutter: CGFloat = Theme.Space.page
    static let pageTop: CGFloat = Theme.Space.m
    static let sectionSpacing: CGFloat = Theme.Space.m + 4
    static let cardPadding: CGFloat = Theme.Space.m
    static let cardSpacing: CGFloat = Theme.Space.s
    static let rowPadding: CGFloat = Theme.Space.s
    static let rowMinHeight: CGFloat = 56
    static let smallButton: CGFloat = 34
    static let smallGlyph: CGFloat = 13
    #endif
    static let listSpring = Theme.Motion.content
}

/// Springy press for the small round icon buttons in settings; on iPhone the hit area extends past the
/// visible circle to about 44 pt without changing layout.
struct SettingsPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle().inset(by: Theme.Control.hitInset(for: SettingsMetrics.smallButton)))
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(configuration.isPressed ? Theme.Motion.press : Theme.Motion.release, value: configuration.isPressed)
            .dsPressHaptic(configuration.isPressed)
    }
}

/// Row-sized press highlight for navigation rows.
struct SettingsRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.07 : 0))
                    .padding(.horizontal, -Theme.Space.xs)
            )
            .animation(Theme.Motion.fast, value: configuration.isPressed)
            .dsPressHaptic(configuration.isPressed)
    }
}

/// Inline status line (error / success / warning) used inside cards.
struct StatusLine: View {
    enum Kind { case error, success, warning }
    var kind: Kind
    var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            Image(systemName: icon)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.Font.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.xs)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
    }

    private var icon: String {
        switch kind {
        case .error: "exclamationmark.triangle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        }
    }

    private var color: Color {
        switch kind {
        case .error: Theme.Palette.danger
        case .success: Theme.Palette.success
        case .warning: Theme.Palette.warning
        }
    }
}
