import SwiftUI
import Observation

/// Finds the episode after the one playing and builds its playback request: the next saved file for local
/// playback, otherwise the next aired episode with a stream from the same release (Stremio `bingeGroup`) or the
/// best cached one.
@MainActor @Observable
final class NextEpisodeModel {
    struct Target: Equatable {
        var code: String?
        var title: String
        var thumbnail: String?

        var label: String { [code, title].compactMap { $0 }.joined(separator: " · ") }
    }

    enum Phase: Equatable {
        case idle, loading
        case failed(String)
    }

    private(set) var target: Target?
    private(set) var phase: Phase = .idle

    private enum Source {
        case local(PlaybackRequest)
        case remote(meta: MetaDetail, video: Video)
    }

    @ObservationIgnored private let request: PlaybackRequest
    @ObservationIgnored private let registry: AddonRegistry
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private var source: Source?
    @ObservationIgnored private var prepared: Task<PlaybackRequest?, Never>?

    init(request: PlaybackRequest, registry: AddonRegistry, library: LibraryStore) {
        self.request = request
        self.registry = registry
        self.library = library
    }

    func resolve() async {
        guard source == nil else { return }
        if request.isLocal {
            resolveLocal()
        } else if request.metaType == "series", let meta = try? await registry.meta(type: request.metaType, id: request.metaID) {
            resolveRemote(meta)
        }
    }

    /// Looks up the stream ahead of time so pressing Next starts right away.
    func prepare() {
        guard prepared == nil, let source else { return }
        let request = request, registry = registry
        prepared = Task { await Self.makeRequest(source, after: request, registry: registry) }
    }

    /// The request for the next episode, or nil (with `phase` explaining why) when no stream was found.
    func nextRequest() async -> PlaybackRequest? {
        guard phase != .loading else { return nil }
        prepare()
        phase = .loading
        let next = await prepared?.value
        if next == nil {
            prepared = nil
            phase = .failed("No cached stream found for \(target?.code ?? "the next episode"). Pick one from the episode list.")
        } else {
            phase = .idle
        }
        return next
    }

    private func resolveLocal() {
        guard let title = library.title(id: request.metaID), title.meta.isSeries else { return }
        let items = title.meta.items.sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
        guard let index = items.firstIndex(where: { $0.videoId == request.videoId }), index + 1 < items.count else { return }
        let item = items[index + 1]
        let name = item.title ?? item.episodeCode ?? item.file
        target = Target(code: item.episodeCode, title: name, thumbnail: nil)
        source = .local(PlaybackRequest(
            url: title.fileURL(for: item),
            title: title.meta.name,
            subtitle: [item.episodeCode, item.title].compactMap { $0 }.joined(separator: " · "),
            metaID: title.meta.id,
            metaType: title.meta.type,
            videoId: item.videoId,
            isLocal: true,
            filenameHint: item.file,
            posterURL: title.posterURL?.absoluteString,
            backgroundURL: title.backdropURL?.absoluteString
        ))
    }

    private func resolveRemote(_ meta: MetaDetail) {
        let episodes = ProgressStore.orderedEpisodes(meta)
        guard let index = episodes.firstIndex(where: { $0.id == request.videoId }), index + 1 < episodes.count else { return }
        let video = episodes[index + 1]
        guard !DetailFormat.isUpcoming(video) else { return }
        target = Target(code: video.episodeCode, title: video.displayTitle, thumbnail: video.thumbnail)
        source = .remote(meta: meta, video: video)
    }

    private static func makeRequest(_ source: Source, after current: PlaybackRequest, registry: AddonRegistry) async -> PlaybackRequest? {
        switch source {
        case .local(let request):
            return FileManager.default.fileExists(atPath: request.url.path) ? request : nil
        case .remote(let meta, let video):
            let streams = await registry.streams(type: meta.type, id: video.id).streams
            let sameRelease = current.bingeGroup.flatMap { group in
                streams.first { $0.stream.behaviorHints?.bingeGroup == group && $0.stream.playableURL != nil }
            }
            let quality = UserDefaults.standard.string(forKey: "streams.quality").flatMap(StreamQuality.init(rawValue:))
            guard let item = sameRelease ?? StreamCache.best(in: streams, preferring: quality) else { return nil }
            return DetailPlayback.request(meta: meta, video: video, item: item)
        }
    }
}

/// Netflix-style prompt shown over the end credits: the next episode with a large play button.
struct PlayerUpNextCard: View {
    let target: NextEpisodeModel.Target
    let phase: NextEpisodeModel.Phase
    let onPlay: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                if let thumbnail = target.thumbnail, let url = URL(string: thumbnail) {
                    RemoteImage(url: url, maxPixelSize: 360) { Color.white.opacity(0.08) }
                        .frame(width: 120, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Up Next")
                        .font(Theme.Font.micro)
                        .textCase(.uppercase)
                        .tracking(1.2)
                        .foregroundStyle(Theme.Palette.textTertiary)
                    if let code = target.code {
                        Text(code)
                            .font(Theme.Font.caption.weight(.semibold))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Text(target.title)
                        .font(Theme.Font.headline)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            if case .failed(let message) = phase {
                Text(message)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Space.xs) {
                Button(action: onPlay) {
                    HStack(spacing: Theme.Space.xs) {
                        if phase == .loading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text(phase == .loading ? "Finding Stream…" : "Next Episode")
                    }
                }
                .buttonStyle(.ds(.primary, fullWidth: true))
                .disabled(phase == .loading)
                Button("Watch Credits", action: onDismiss)
                    .buttonStyle(.ds(.secondary, fullWidth: true))
            }
        }
        .foregroundStyle(Theme.Palette.textPrimary)
        .padding(Theme.Space.m)
        .frame(width: 360)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(Theme.Palette.stroke))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
        .environment(\.colorScheme, .dark)
        // Swallows taps on the padding so they don't reach the video (pause / show controls).
        .onTapGesture {}
    }
}

/// Subtitle timing: nudges subtitles earlier or later in 0.1 s steps.
struct PlayerSubtitleTimingRow: View {
    let engine: any PlayerEngine
    let onChange: () -> Void

    var body: some View {
        let enabled = engine.selectedSubtitleTrackID != nil
        HStack(spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Subtitle Timing")
                    .font(Theme.Font.headline)
                Text(enabled ? PlayerSubtitleTiming.description(engine.subtitleDelay) : "Turn on subtitles to adjust timing")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Space.xs)
            HStack(spacing: 2) {
                step(-0.1, systemName: "minus", help: "Show subtitles earlier (Z)")
                Button {
                    engine.setSubtitleDelay(0); onChange()
                } label: {
                    Text(PlayerSubtitleTiming.label(engine.subtitleDelay))
                        .font(Theme.Font.headline.monospacedDigit())
                        .contentTransition(.numericText())
                        .frame(minWidth: 64, minHeight: PlayerMetrics.hit)
                        .contentShape(Rectangle())
                }
                .help("Reset subtitle timing")
                .accessibilityLabel("Subtitle delay")
                .accessibilityValue(PlayerSubtitleTiming.description(engine.subtitleDelay))
                .accessibilityHint("Resets the delay")
                step(0.1, systemName: "plus", help: "Show subtitles later (X)")
            }
            .animation(Theme.Motion.fast, value: engine.subtitleDelay)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
    }

    private func step(_ delta: Double, systemName: String, help: String) -> some View {
        PlayerIconButton(systemName: systemName, size: 15, help: help) {
            engine.setSubtitleDelay(engine.subtitleDelay + delta); onChange()
        }
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(help)
    }
}

enum PlayerSubtitleTiming {
    /// "+0.3 s", "−1.2 s", "0.0 s"
    static func label(_ delay: Double) -> String {
        let magnitude = String(format: "%.1f s", abs(delay))
        if abs(delay) < 0.05 { return "0.0 s" }
        return (delay > 0 ? "+" : "−") + magnitude
    }

    static func description(_ delay: Double) -> String {
        if abs(delay) < 0.05 { return "In sync with the video" }
        return String(format: "Shown %.1f s %@", abs(delay), delay > 0 ? "later" : "earlier")
    }
}
