import SwiftUI

/// Merged streams from all stream addons for a movie (`video == nil`) or an episode, as quality-tagged cards.
struct StreamListView: View {
    let meta: MetaDetail
    let video: Video?
    let cache: StreamCache
    /// Called after a stream starts playing (the episode sheet closes itself).
    var onPlay: (() -> Void)? = nil
    @Environment(AddonRegistry.self) private var registry
    @AppStorage("streams.cachedOnly") private var cachedOnly = true
    @StreamQualityPreference private var quality

    private var streamID: String { video?.id ?? meta.id }
    private var result: StreamCache.Result { cache.result(for: streamID) }
    private var streams: [AddonStream] { result.streams }
    /// Streams that pass the cached-only toggle; the quality filter applies on top.
    private var base: [AddonStream] { cachedOnly ? streams.filter(\.stream.isCached) : streams }
    private var visible: [AddonStream] {
        guard let quality else { return base }
        return base.filter { $0.stream.quality == quality }
    }
    private var qualityCounts: [StreamQuality: Int] { base.reduce(into: [:]) { $0[$1.stream.quality, default: 0] += 1 } }
    private var uncachedCount: Int { streams.count - base.count }
    private var isLoading: Bool { result.isLoading || !result.hasLoaded }
    private var showsQualityFilter: Bool { !base.isEmpty && (qualityCounts.count > 1 || quality != nil) }

    private enum Phase: Equatable { case loading, empty, noneCached, noneInQuality, list }

    private var phase: Phase {
        if isLoading && streams.isEmpty { return .loading }
        if streams.isEmpty { return .empty }
        if base.isEmpty { return .noneCached }
        return visible.isEmpty ? .noneInQuality : .list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header
            if showsQualityFilter {
                QualityFilterBar(selection: $quality, counts: qualityCounts, total: base.count)
                    .transition(.opacity)
            }
            // With no streams at all the empty state explains the failure and offers the retry instead.
            if !result.errors.isEmpty, !streams.isEmpty {
                ErrorBanner(title: result.errors.count == 1 ? "An addon failed" : "\(result.errors.count) addons failed",
                            messages: result.errors, retry: reload)
            }
            ZStack(alignment: .top) { content }
                .animation(Theme.Motion.content, value: phase)
                .animation(Theme.Motion.content, value: quality)
        }
        .task(id: streamID) { await cache.load(registry: registry, type: meta.type, id: streamID) }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            Text("Streams").font(Theme.Font.rowTitle).foregroundStyle(Theme.Palette.textPrimary)
            if result.hasLoaded, !streams.isEmpty {
                Text("\(visible.count)")
                    .font(Theme.Font.caption.monospacedDigit())
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            Spacer()
            CachedOnlyChip(isOn: $cachedOnly)
            DetailIconButton(systemImage: "arrow.clockwise", help: "Reload streams", size: Self.headerControlHeight, action: reload)
                .disabled(result.isLoading)
        }
    }

    private func reload() {
        guard !result.isLoading else { return }
        Task { await cache.load(registry: registry, type: meta.type, id: streamID, force: true) }
    }

    #if os(macOS)
    static let headerControlHeight: CGFloat = 30
    #else
    static let headerControlHeight: CGFloat = 34
    #endif

    @ViewBuilder private var content: some View {
        if isLoading && streams.isEmpty {
            VStack(spacing: Theme.Space.xs) {
                ForEach(0..<3, id: \.self) { _ in StreamSkeleton() }
            }
            .accessibilityLabel("Asking addons for streams")
        } else if streams.isEmpty {
            noStreamsState
        } else if base.isEmpty {
            emptyState(icon: "bolt.slash", title: "No cached streams",
                       message: "All \(streams.count) streams would need your debrid service to download first.") {
                Button("Show uncached streams") { withAnimation(Theme.Motion.content) { cachedOnly = false } }
                    .buttonStyle(.ds(.secondary, compact: true))
            }
        } else if visible.isEmpty, let quality {
            qualityEmptyState(quality)
        } else {
            VStack(spacing: Theme.Space.m) {
                LazyVStack(spacing: Theme.Space.xs) {
                    ForEach(visible) { item in
                        StreamCard(item: item, meta: meta, video: video, onPlay: onPlay)
                            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    }
                }
                if uncachedCount > 0 {
                    Button("Show \(uncachedCount) uncached") { withAnimation(Theme.Motion.content) { cachedOnly = false } }
                        .buttonStyle(.ds(.ghost, compact: true))
                }
            }
        }
    }

    @ViewBuilder private var noStreamsState: some View {
        if registry.addons(for: "stream", type: meta.type, id: streamID).isEmpty {
            emptyState(icon: "puzzlepiece.extension", title: "No stream addons",
                       message: "Add a stream addon such as Comet in Settings to find streams.")
        } else if !result.errors.isEmpty {
            emptyState(icon: "wifi.exclamationmark", title: "Couldn't load streams",
                       message: (result.errors.count == 1 ? "An addon didn't respond" : "\(result.errors.count) addons didn't respond")
                           + ". Check your connection and try again.") {
                VStack(spacing: Theme.Space.xs) {
                    Button(action: reload) { Label("Try again", systemImage: "arrow.clockwise") }
                        .buttonStyle(.ds(.secondary, compact: true))
                    ForEach(Array(result.errors.enumerated()), id: \.offset) { _, message in
                        Text(message)
                            .font(Theme.Font.micro)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            }
        } else if let video, DetailFormat.isUpcoming(video) {
            emptyState(icon: "calendar", title: "Not out yet",
                       message: "\(video.episodeCode ?? "This episode") airs \(DisplayFormat.date(video.released) ?? "soon"). Streams usually appear shortly after.")
        } else {
            emptyState(icon: "play.slash", title: "No streams found",
                       message: "None of your addons had a stream for this. Try again later or add another stream addon.") {
                Button(action: reload) { Label("Try again", systemImage: "arrow.clockwise") }
                    .buttonStyle(.ds(.ghost, compact: true))
            }
        }
    }

    private func qualityEmptyState(_ quality: StreamQuality) -> some View {
        let uncached = streams.filter { !$0.stream.isCached && $0.stream.quality == quality }.count
        let message = uncached > 0 && cachedOnly
            ? "\(uncached) uncached \(quality.label) \(uncached == 1 ? "stream is" : "streams are") hidden."
            : "\(base.count) \(base.count == 1 ? "stream is" : "streams are") available in other qualities."
        return emptyState(icon: "line.3.horizontal.decrease.circle", title: "No \(quality.label) streams", message: message) {
            HStack(spacing: Theme.Space.xs) {
                Button("Show all qualities") { withAnimation(Theme.Motion.content) { self.quality = nil } }
                    .buttonStyle(.ds(.secondary, compact: true))
                if uncached > 0 && cachedOnly {
                    Button("Show uncached") { withAnimation(Theme.Motion.content) { cachedOnly = false } }
                        .buttonStyle(.ds(.ghost, compact: true))
                }
            }
        }
    }

    private func emptyState(icon: String, title: String, message: String,
                            @ViewBuilder action: () -> some View = { EmptyView() }) -> some View {
        VStack(spacing: Theme.Space.xs) {
            Image(systemName: icon).font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.Palette.textTertiary)
            Text(title).font(Theme.Font.headline).foregroundStyle(Theme.Palette.textPrimary)
            Text(message).font(Theme.Font.caption).foregroundStyle(Theme.Palette.textSecondary).multilineTextAlignment(.center)
            action().padding(.top, Theme.Space.xxs)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .detailCard(padding: Theme.Space.l)
    }
}

/// "All · 4K · 1080p · 720p · SD" chips with per-quality counts; qualities without streams are left out.
private struct QualityFilterBar: View {
    @Binding var selection: StreamQuality?
    let counts: [StreamQuality: Int]
    let total: Int
    @Namespace private var namespace

    private var qualities: [StreamQuality] {
        StreamQuality.allCases.filter { (counts[$0] ?? 0) > 0 || $0 == selection }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.xs) {
                QualityChip(title: "All", count: total, isSelected: selection == nil, help: "Show every quality",
                            namespace: namespace) { select(nil) }
                ForEach(qualities, id: \.self) { q in
                    QualityChip(title: q.label, count: counts[q] ?? 0, isSelected: selection == q, help: help(for: q),
                                namespace: namespace) { select(q) }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
        .dsSelectionHaptic(selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quality")
    }

    private func select(_ q: StreamQuality?) {
        withAnimation(Theme.Motion.content) { selection = selection == q ? nil : q }
    }

    private func help(for q: StreamQuality) -> String {
        switch q {
        case .uhd: "Only 4K (2160p) streams"
        case .fhd: "Only 1080p streams"
        case .hd: "Only 720p streams"
        case .sd: "Only SD streams (480p and lower) — smallest downloads"
        case .unknown: "Streams whose resolution the addon didn't state"
        }
    }
}

private struct QualityChip: View {
    var title: String
    var count: Int
    var isSelected: Bool
    var help: String
    var namespace: Namespace.ID
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.black.opacity(0.55) : Theme.Palette.textTertiary)
            }
            .font(Theme.Font.caption.weight(.semibold))
            .foregroundStyle(isSelected ? Color.black : Theme.Palette.textPrimary.opacity(hovering ? 1 : 0.85))
            .padding(.horizontal, Theme.Space.s)
            .frame(minHeight: StreamListView.headerControlHeight)
            .background {
                if isSelected {
                    Capsule().fill(Color.white).matchedGeometryEffect(id: "selectedQuality", in: namespace)
                } else {
                    Capsule().fill(Color.white.opacity(hovering ? 0.14 : 0.06))
                        .overlay(Capsule().strokeBorder(Theme.Palette.stroke))
                }
            }
            .contentShape(Capsule().inset(by: Theme.Control.hitInset(for: StreamListView.headerControlHeight)))
            .animation(Theme.Motion.hover, value: hovering)
        }
        .buttonStyle(DSPressableStyle(scale: 0.95, haptic: false))
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel("\(title), \(count) \(count == 1 ? "stream" : "streams")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct CachedOnlyChip: View {
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(Theme.Motion.content) { isOn.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "bolt.fill" : "bolt")
                Text("Cached only")
            }
            .font(Theme.Font.caption.weight(.semibold))
            .foregroundStyle(isOn ? Theme.Palette.warning : Theme.Palette.textSecondary)
            .padding(.horizontal, Theme.Space.s)
            .frame(minHeight: StreamListView.headerControlHeight)
            .background(Capsule().fill(isOn ? Theme.Palette.warning.opacity(0.16) : Color.white.opacity(hovering ? 0.12 : 0.06)))
            .overlay(Capsule().strokeBorder(isOn ? Theme.Palette.warning.opacity(0.45) : Theme.Palette.stroke))
            .contentShape(Capsule().inset(by: Theme.Control.hitInset(for: StreamListView.headerControlHeight)))
        }
        .buttonStyle(DSPressableStyle(scale: 0.95))
        .onHover { hovering = $0 }
        .help(isOn ? "Showing only instantly playable streams. Click to show all." : "Show only cached (instantly playable) streams")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct StreamSkeleton: View {
    @State private var pulse = false
    var body: some View {
        HStack(spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: 6) {
                    ForEach([38.0, 52, 44], id: \.self) { w in
                        RoundedRectangle(cornerRadius: 4).frame(width: w, height: 16)
                    }
                }
                RoundedRectangle(cornerRadius: 4).frame(maxWidth: 420).frame(height: 14)
                RoundedRectangle(cornerRadius: 4).frame(width: 180, height: 10)
            }
            Spacer()
            Capsule().frame(width: 80, height: 30)
        }
        .foregroundStyle(Color.white.opacity(pulse ? 0.09 : 0.04))
        .detailCard(padding: Theme.Space.m)
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true } }
    }
}

private struct StreamCard: View {
    let item: AddonStream
    let meta: MetaDetail
    let video: Video?
    var onPlay: (() -> Void)?
    @Environment(\.play) private var play
    @Environment(DownloadManager.self) private var downloads
    @Environment(LibraryStore.self) private var library
    @State private var lastPlayed: Date?

    private var stream: Stream { item.stream }
    private var videoId: String { video?.id ?? meta.id }
    private var url: URL? { stream.playableURL }
    private var tags: StreamTags { StreamTags(item) }
    private var downloadState: DownloadBadgeState? { DownloadBadgeState.of(videoId, library: library, downloads: downloads) }

    /// Release name: first detail line, else the filename, else the addon's stream name.
    private var title: String {
        if let first = detailLines.first {
            let trimmed = String(first.drop { !$0.isLetter && !$0.isNumber })
            return trimmed.isEmpty ? first : trimmed
        }
        if let filename = stream.filename { return (filename as NSString).deletingPathExtension }
        return nameLine
    }

    private var detailLines: [String] {
        stream.details.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var nameLine: String {
        (stream.name ?? item.addonName)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// Everything after the release name (seeders, source tracker…), on one line.
    private var secondary: String {
        guard !detailLines.isEmpty else { return "" }
        return detailLines.dropFirst().joined(separator: "  ·  ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                badges
                    .accessibilityElement(children: .combine)
                Text(title)
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(stream.details.isEmpty ? title : stream.details)
                if !secondary.isEmpty {
                    Text(secondary)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(2)
                }
                if url == nil {
                    Label(stream.infoHash != nil ? "Torrent — needs a debrid addon" : "No playable link",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.warning)
                }
            }
            Spacer(minLength: Theme.Space.xs)
            actions
        }
        .detailCard(padding: Theme.Space.m)
        .opacity(url == nil ? 0.5 : 1)
        // The whole card plays (double-click on macOS, like a list row); the buttons inside keep their own actions.
        .onTapGesture(count: Self.playTapCount, perform: startPlayback)
        .contextMenu {
            Button("Play", systemImage: "play.fill", action: startPlayback).disabled(url == nil)
            Button("Download", systemImage: "arrow.down.circle", action: download).disabled(url == nil || downloadState != nil)
        }
    }

    private var badges: some View {
        FlowLayout(spacing: 5, lineSpacing: 5) {
            if let resolution = tags.resolution {
                Text(resolution)
                    .font(Theme.Font.micro)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(tags.isPremium ? Theme.Palette.warning : Color.white.opacity(0.9),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            if stream.isCached { Badge(text: "Cached", systemImage: "bolt.fill", tint: Theme.Palette.warning) }
            ForEach(tags.hdr, id: \.self) { Badge(text: $0, tint: Theme.Palette.accent) }
            if let codec = tags.codec { Badge(text: codec) }
            if let source = tags.source { Badge(text: source) }
            ForEach(tags.audio, id: \.self) { Badge(text: $0) }
            if let size = tags.size { Badge(text: size, systemImage: "internaldrive", tint: Theme.Palette.textSecondary) }
            Badge(text: item.addonName, tint: Theme.Palette.textTertiary)
        }
        .lineLimit(1)
    }

    @ViewBuilder private var actions: some View {
        #if os(iOS)
        HStack(spacing: Theme.Space.xxs) {
            DetailIconButton(systemImage: downloadIcon, help: downloadHelp, isOn: downloadState != nil,
                             size: Theme.Control.iconCircle, action: download)
                .disabled(url == nil || downloadState != nil)
            IconCircleButton("play.fill", label: "Play this stream", size: Theme.Control.iconCircle, prominent: true,
                             action: startPlayback)
                .disabled(url == nil)
        }
        #else
        HStack(spacing: Theme.Space.xs) {
            DetailIconButton(systemImage: downloadIcon, help: downloadHelp, isOn: downloadState != nil, size: 34, action: download)
                .disabled(url == nil || downloadState != nil)
            Button(action: startPlayback) {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.ds(.primary, compact: true))
            .disabled(url == nil)
            .help("Play this stream")
        }
        #endif
    }

    private var downloadIcon: String {
        switch downloadState {
        case .saved?: "checkmark"
        case .queued?: "arrow.down.circle.dotted"
        case nil: "arrow.down"
        }
    }

    private var downloadHelp: String {
        switch downloadState {
        case .saved?: "Saved for offline viewing"
        case .queued?: "In Downloads"
        case nil: "Download for offline viewing"
        }
    }

    private func download() {
        guard url != nil, downloadState == nil else { return }
        downloads.enqueue(meta: meta, video: video, stream: item)
    }

    #if os(macOS)
    private static let playTapCount = 2
    #else
    private static let playTapCount = 1
    #endif

    private func startPlayback() {
        // Ignore repeats (double click on the Play button) so only one player opens.
        if let lastPlayed, Date.now.timeIntervalSince(lastPlayed) < 1.5 { return }
        guard let request = DetailPlayback.request(meta: meta, video: video, item: item) else { return }
        lastPlayed = .now
        play(request)
        onPlay?()
    }
}
