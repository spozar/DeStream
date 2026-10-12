import SwiftUI

/// Subtitle size, font, colors, outline, background and position, with a live preview.
struct SubtitleStyleSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        let style = settings.subtitleStyle
        SettingsCard(title: "Subtitle Appearance", systemImage: "textformat.size",
                     footer: "Changes apply right away, also during playback. With the mpv engine off, MP4 and HLS streams can't use the outline color or width.") {
            SubtitleStylePreview(style: style)
                .padding(.bottom, Theme.Space.xs)
            SettingsRow(title: "Size", detail: Self.percent(style.size), divider: false) {
                SubtitleSlider(label: "Subtitle size", value: $settings.subtitleStyle.size,
                               range: SubtitleStyle.sizeRange, step: 0.05)
            }
            SettingsRow(title: "Font") {
                DSMenuPicker(label: "Subtitle font", selection: $settings.subtitleStyle.font,
                             options: SubtitleStyle.Font.allCases.map { ($0, $0.title) })
            }
            SettingsRow(title: "Bold") {
                DSToggle(label: "Bold subtitles", isOn: $settings.subtitleStyle.bold)
            }
            SettingsRow(title: "Text color") {
                SubtitleColorPicker(label: "Text color", color: $settings.subtitleStyle.textColor,
                                    presets: [(.white, "White"), (.yellow, "Yellow"), (.lightGray, "Gray"), (.cyan, "Cyan"), (.green, "Green")])
            }
            SettingsRow(title: "Outline", detail: style.outlineWidth == 0 ? "None" : String(format: "%.1f", style.outlineWidth)) {
                SubtitleSlider(label: "Outline width", value: $settings.subtitleStyle.outlineWidth,
                               range: SubtitleStyle.outlineRange, step: 0.5)
            }
            SettingsRow(title: "Outline color") {
                SubtitleColorPicker(label: "Outline color", color: $settings.subtitleStyle.outlineColor,
                                    presets: [(.black, "Black"), (.darkGray, "Dark gray"), (.navy, "Navy"), (.white, "White")])
            }
            .disabled(style.outlineWidth == 0)
            .opacity(style.outlineWidth == 0 ? 0.5 : 1)
            SettingsRow(title: "Background box", detail: "A dark box behind the text") {
                DSToggle(label: "Background box", isOn: $settings.subtitleStyle.background)
            }
            if style.background {
                SettingsRow(title: "Box opacity", detail: Self.percent(style.backgroundOpacity)) {
                    SubtitleSlider(label: "Background box opacity", value: $settings.subtitleStyle.backgroundOpacity,
                                   range: 0.1...1, step: 0.05)
                }
            }
            SettingsRow(title: "Position", detail: style.elevation == 0 ? "Bottom of the video" : "Raised \(Self.percent(style.elevation)) of the height") {
                SubtitleSlider(label: "Subtitle position", value: $settings.subtitleStyle.elevation,
                               range: SubtitleStyle.elevationRange, step: 0.01)
            }
            SettingsRow(title: "Restyle styled subtitles",
                        detail: "Also apply this look to ASS/SSA subtitles (common in anime). May break signs and on-screen text.") {
                DSToggle(label: "Restyle styled subtitles", isOn: $settings.subtitleStyle.overrideStyledSubtitles)
            }
            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    withAnimation(Theme.Motion.content) { settings.subtitleStyle = .default }
                }
                .buttonStyle(.ds(.ghost, compact: true))
                .disabled(style.isDefault)
            }
            .padding(.top, Theme.Space.xs)
        }
        .animation(Theme.Motion.content, value: style.background)
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}

/// A frame of "video" with a sample line drawn the way the player will draw it (sizes follow mpv's 720p canvas).
struct SubtitleStylePreview: View {
    let style: SubtitleStyle
    var text = "This is how your subtitles\nwill look while you watch."

    var body: some View {
        GeometryReader { geo in
            let unit = geo.size.height / 720
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [Color(red: 0.16, green: 0.22, blue: 0.36), Color(red: 0.55, green: 0.38, blue: 0.36),
                                        Color(red: 0.12, green: 0.1, blue: 0.12)],
                               startPoint: .top, endPoint: .bottom)
                SubtitleText(text: text, style: style, unit: unit)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.bottom, 22 * unit + style.elevation * geo.size.height)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: 520)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.Palette.stroke))
        .frame(maxWidth: .infinity)
        .animation(Theme.Motion.fast, value: style)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Subtitle preview")
    }
}

private struct SubtitleText: View {
    let text: String
    let style: SubtitleStyle
    let unit: CGFloat

    var body: some View {
        let fontSize = max(6, 38 * style.size * unit)
        let outline = style.outlineWidth * unit
        ZStack {
            if outline > 0 {
                ForEach(0..<16, id: \.self) { i in
                    let angle = Double(i) / 16 * 2 * .pi
                    label(fontSize: fontSize)
                        .foregroundStyle(style.outlineColor.color)
                        .offset(x: cos(angle) * outline, y: sin(angle) * outline)
                }
            }
            label(fontSize: fontSize)
                .foregroundStyle(style.textColor.color)
        }
        .padding(.horizontal, style.background ? fontSize * 0.3 : 0)
        .padding(.vertical, style.background ? fontSize * 0.1 : 0)
        .background(style.background ? style.backgroundColor.color : .clear)
    }

    private func label(fontSize: CGFloat) -> some View {
        Text(text)
            .font(font(size: fontSize))
            .fontWeight(style.bold ? .bold : .regular)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .fixedSize()
    }

    private func font(size: CGFloat) -> Font {
        style.font.familyName.map { Font.custom($0, fixedSize: size) } ?? .system(size: size)
    }
}

private struct SubtitleSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        Slider(value: $value, in: range, step: step) { Text(label) }
            .labelsHidden()
            .tint(Theme.Palette.accent)
            .frame(width: Self.width)
            .accessibilityLabel(label)
    }

    #if os(macOS)
    private static let width: CGFloat = 220
    #else
    private static let width: CGFloat = 150
    #endif
}

/// Preset swatches plus the system color picker for anything else.
private struct SubtitleColorPicker: View {
    let label: String
    @Binding var color: SubtitleStyle.RGBA
    let presets: [(color: SubtitleStyle.RGBA, name: String)]
    @Environment(\.self) private var environment

    var body: some View {
        HStack(spacing: 6) {
            ForEach(presets, id: \.color) { preset in
                let selected = preset.color == color
                Button { color = preset.color } label: {
                    Circle()
                        .fill(preset.color.color)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                        .padding(3)
                        .overlay(Circle().strokeBorder(selected ? Theme.Palette.accentHover : .clear, lineWidth: 2))
                        .frame(width: Self.swatch, height: Self.swatch)
                        .contentShape(Circle())
                }
                .buttonStyle(SettingsPressStyle())
                .accessibilityLabel("\(label): \(preset.name)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            ColorPicker(label, selection: custom, supportsOpacity: false)
                .labelsHidden()
        }
        .dsSelectionHaptic(color)
    }

    private var custom: Binding<Color> {
        Binding {
            color.color
        } set: { new in
            let r = new.resolve(in: environment)
            color = SubtitleStyle.RGBA(red: Double(r.red), green: Double(r.green), blue: Double(r.blue))
        }
    }

    #if os(macOS)
    private static let swatch: CGFloat = 28
    #else
    private static let swatch: CGFloat = 26
    #endif
}

extension SubtitleStyle.RGBA {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}
