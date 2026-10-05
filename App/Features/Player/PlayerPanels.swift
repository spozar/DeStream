import SwiftUI

/// Netflix-style "Audio & Subtitles" panel: two columns of tracks with checkmarks.
struct PlayerTracksPanel: View {
    let engine: any PlayerEngine
    let onSelect: () -> Void
    var onDelayChange: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            columns
            if engine.supportsSubtitleDelay {
                Rectangle().fill(Theme.Palette.stroke).frame(height: 1).padding(.horizontal, Theme.Space.m)
                PlayerSubtitleTimingRow(engine: engine, onChange: onDelayChange)
            }
        }
        .frame(maxWidth: PlayerPanelMetrics.tracksWidth)
        .playerPanelChrome()
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 0) {
            PlayerPanelColumn(title: "Audio") {
                if engine.audioTracks.isEmpty {
                    PlayerPanelRow(title: "Default", detail: nil, isSelected: true) {}
                        .disabled(true)
                } else {
                    ForEach(engine.audioTracks) { track in
                        let label = Self.label(for: track)
                        PlayerPanelRow(title: label.title, detail: label.detail, isSelected: engine.selectedAudioTrackID == track.id) {
                            engine.selectAudioTrack(track.id); onSelect()
                        }
                    }
                }
            }
            Rectangle().fill(Theme.Palette.stroke).frame(width: 1).padding(.vertical, Theme.Space.m)
            PlayerPanelColumn(title: "Subtitles") {
                PlayerPanelRow(title: "Off", detail: nil, isSelected: engine.selectedSubtitleTrackID == nil) {
                    engine.selectSubtitleTrack(nil); onSelect()
                }
                ForEach(engine.subtitleTracks) { track in
                    let label = Self.label(for: track)
                    PlayerPanelRow(title: label.title, detail: label.detail, isSelected: engine.selectedSubtitleTrackID == track.id) {
                        engine.selectSubtitleTrack(track.id); onSelect()
                    }
                }
                if engine.subtitleTracks.isEmpty, engine.isLoaded {
                    Text("No subtitles available.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Theme.Space.xs + 16 + Theme.Space.xs)
                        .padding(.top, Theme.Space.xxs)
                }
            }
        }
    }

    /// Language (or title) as the main line; title, codec, channels and flags as the detail line.
    static func label(for track: PlayerTrack) -> (title: String, detail: String?) {
        var title: String?
        if let language = track.language, !language.isEmpty {
            title = LanguageCodes.displayName(language)
        }
        var detail: [String] = []
        if let name = track.title, !name.isEmpty {
            if title == nil {
                title = name
            } else if name.lowercased() != track.language?.lowercased(), name.caseInsensitiveCompare(title ?? "") != .orderedSame {
                detail.append(name)
            }
        }
        if let codec = track.codec, !codec.isEmpty { detail.append(codec.uppercased()) }
        if let channels = track.channels, !channels.isEmpty { detail.append(channels) }
        if track.isForced { detail.append("Forced") }
        if track.isExternal { detail.append("External") }
        return (title ?? "Track \(track.id)", detail.isEmpty ? nil : detail.joined(separator: " · "))
    }
}

struct PlayerSpeedPanel: View {
    let engine: any PlayerEngine
    let onSelect: () -> Void

    var body: some View {
        PlayerPanelColumn(title: "Playback Speed") {
            ForEach(PlayerSpeed.options, id: \.self) { speed in
                PlayerPanelRow(title: speed == 1 ? "1× (Normal)" : PlayerSpeed.label(speed), detail: nil, isSelected: abs(engine.speed - speed) < 0.01) {
                    engine.setSpeed(speed); onSelect()
                }
            }
        }
        .frame(width: PlayerPanelMetrics.speedWidth)
        .playerPanelChrome()
    }
}

private enum PlayerPanelMetrics {
    #if os(macOS)
    static let tracksWidth: CGFloat = 540
    static let speedWidth: CGFloat = 220
    static let listHeight: CGFloat = 300
    static let rowHeight: CGFloat = 34
    #else
    static let tracksWidth: CGFloat = 480
    static let speedWidth: CGFloat = 240
    static let rowHeight: CGFloat = 44
    #endif
}

private struct PlayerPanelColumn<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title)
                .font(Theme.Font.rowTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .padding(.horizontal, Theme.Space.m)
            #if os(macOS)
            ScrollView { list }
                .scrollIndicators(.automatic)
                .frame(maxHeight: PlayerPanelMetrics.listHeight)
                .fixedSize(horizontal: false, vertical: true)
            #else
            // Hugs short lists; scrolls only when the panel would outgrow the screen.
            ViewThatFits(in: .vertical) {
                list
                ScrollView { list }.scrollIndicators(.automatic)
            }
            #endif
        }
        .padding(.vertical, Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) { content }
            .padding(.horizontal, Theme.Space.xs)
    }
}

private struct PlayerPanelRow: View {
    let title: String
    let detail: String?
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.Palette.accentHover)
                    .opacity(isSelected ? 1 : 0)
                    .scaleEffect(isSelected ? 1 : 0.4)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(isSelected ? Theme.Font.headline : Theme.Font.body)
                        .foregroundStyle(isSelected || isHovering ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.xs)
            .padding(.vertical, 6)
            .frame(minHeight: PlayerPanelMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelRowStyle(isHovering: isHovering, isSelected: isSelected))
        .foregroundStyle(Theme.Palette.textPrimary)
        .onHover { isHovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct PanelRowStyle: ButtonStyle {
    let isHovering: Bool
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.14 : isHovering ? 0.08 : isSelected ? 0.05 : 0))
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Theme.Motion.fast, value: configuration.isPressed)
    }
}

private extension View {
    func playerPanelChrome() -> some View {
        background(Theme.Palette.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(Theme.Palette.stroke))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
            // Swallows taps on the panel's padding so they don't reach the video (which would close it / toggle pause).
            .onTapGesture {}
    }
}
