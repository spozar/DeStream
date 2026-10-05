import SwiftUI

/// Season tabs + Netflix-style episode cards. Selecting an episode opens its streams (DetailView shows the sheet).
struct EpisodeListView: View {
    let meta: MetaDetail
    @Binding var season: Int?
    /// The episode the hero's Play button targets; gets an "Up next" marker.
    var upNextID: String?
    var onSelect: (Video) -> Void
    var onPlayBest: (Video) -> Void
    var onDownloadBest: (Video) -> Void
    @Environment(ProgressStore.self) private var progress
    @Environment(LibrarySync.self) private var librarySync
    @Namespace private var pillNamespace
    /// Direction of the last season change, so the new list slides in from the matching side.
    @State private var forward = true
    @State private var selections = 0

    private var currentSeason: Int? { season ?? meta.seasons.first }

    private var episodes: [Video] {
        guard let currentSeason else { return meta.videos ?? [] }
        return meta.episodes(season: currentSeason)
    }

    /// Episodes marked watched on the Stremio account (empty when signed out).
    private var accountWatched: Set<String> {
        librarySync.watchedVideoIDs(metaID: meta.id, videoIDs: LibrarySync.bitfieldVideoIDs(meta))
    }

    private func isWatched(_ id: String, _ accountWatched: Set<String>) -> Bool {
        progress.isWatched(id) || accountWatched.contains(id)
    }

    private var watchedCount: Int {
        let remote = accountWatched
        return episodes.filter { isWatched($0.id, remote) }.count
    }

    var body: some View {
        let remote = accountWatched
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                Text("Episodes").font(Theme.Font.title).foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
            }
            if meta.seasons.count > 1 { seasonSelector }
            seasonHeader
            LazyVStack(alignment: .leading, spacing: Theme.Space.xs) {
                ForEach(episodes) { episode in
                    Button { onSelect(episode) } label: {
                        EpisodeCard(meta: meta, video: episode, isUpNext: episode.id == upNextID,
                                    isAccountWatched: remote.contains(episode.id))
                    }
                    .buttonStyle(DSPressableStyle(scale: 0.98))
                    .contextMenu { menu(for: episode, watched: isWatched(episode.id, remote)) }
                }
            }
            .id(currentSeason)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(x: forward ? 28 : -28)),
                removal: .identity))
        }
        .dsSelectionHaptic(selections)
    }

    private func select(_ s: Int) {
        guard s != currentSeason else { return }
        forward = s > (currentSeason ?? 0)
        selections += 1
        withAnimation(Theme.Motion.content) { season = s }
    }

    // MARK: Seasons

    private func seasonName(_ s: Int) -> String { s == 0 ? "Specials" : "Season \(s)" }

    @ViewBuilder private var seasonSelector: some View {
        if meta.seasons.count <= 10 {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.xs) {
                        ForEach(meta.seasons, id: \.self) { s in
                            SeasonPill(title: seasonName(s), isSelected: s == currentSeason,
                                       isComplete: isSeasonWatched(s), namespace: pillNamespace) {
                                select(s)
                            }
                            .id(s)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: currentSeason) { _, s in
                    withAnimation(Theme.Motion.content) { proxy.scrollTo(s, anchor: .center) }
                }
            }
        } else {
            Menu {
                ForEach(meta.seasons, id: \.self) { s in
                    Button(seasonName(s) + (isSeasonWatched(s) ? "  ✓" : "")) { select(s) }
                }
            } label: {
                HStack(spacing: Theme.Space.xs) {
                    Text(currentSeason.map(seasonName) ?? "Season")
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                }
                .font(Theme.Font.headline)
                .foregroundStyle(Theme.Palette.textPrimary)
                .padding(.horizontal, Theme.Space.m)
                .frame(minHeight: Theme.Control.compactHeight)
                .background(Capsule().fill(Theme.Palette.surfaceHigh))
                .overlay(Capsule().strokeBorder(Theme.Palette.stroke))
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func isSeasonWatched(_ s: Int) -> Bool {
        let eps = meta.episodes(season: s).filter { !DetailFormat.isUpcoming($0) }
        let remote = accountWatched
        return !eps.isEmpty && eps.allSatisfy { isWatched($0.id, remote) }
    }

    private var seasonHeader: some View {
        HStack(spacing: Theme.Space.s) {
            if let currentSeason {
                Text(seasonName(currentSeason)).font(Theme.Font.rowTitle).foregroundStyle(Theme.Palette.textPrimary)
            }
            if !episodes.isEmpty {
                HStack(spacing: Theme.Space.xs) {
                    WatchProgressBar(fraction: Double(watchedCount) / Double(episodes.count), height: 4)
                        .frame(width: Self.seasonBarWidth)
                        .animation(Theme.Motion.content, value: watchedCount)
                    Text("\(watchedCount) of \(episodes.count) watched")
                        .font(Theme.Font.caption)
                        .foregroundStyle(watchedCount == episodes.count ? Theme.Palette.success : Theme.Palette.textSecondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            Menu {
                Button("Mark season as watched", systemImage: "checkmark.circle") { markSeason(watched: true) }
                Button("Mark season as unwatched", systemImage: "arrow.uturn.backward.circle") { markSeason(watched: false) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .frame(minWidth: Theme.Control.minHitTarget, minHeight: Theme.Control.minHitTarget)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Season options")
            .accessibilityLabel("Season options")
        }
    }

    #if os(macOS)
    private static let seasonBarWidth: CGFloat = 80
    #else
    private static let seasonBarWidth: CGFloat = 52
    #endif

    private func markSeason(watched: Bool) {
        withAnimation(Theme.Motion.content) { applySeasonMark(watched: watched) }
    }

    private func applySeasonMark(watched: Bool) {
        for episode in episodes where !DetailFormat.isUpcoming(episode) {
            if watched {
                guard !progress.isWatched(episode.id) else { continue }
                progress.markWatched(videoId: episode.id, metaID: meta.id, metaType: meta.type, title: meta.name,
                                     duration: progress.entry(for: episode.id)?.duration ?? DetailFormat.runtimeSeconds(meta.runtime))
            } else {
                progress.markUnwatched(videoId: episode.id)
            }
        }
    }

    // MARK: Context menu

    @ViewBuilder private func menu(for episode: Video, watched: Bool) -> some View {
        Button("Play", systemImage: "play.fill") { onPlayBest(episode) }
        Button("Choose Stream…", systemImage: "list.bullet") { onSelect(episode) }
        Divider()
        if watched {
            Button("Mark as Unwatched", systemImage: "arrow.uturn.backward.circle") {
                progress.markUnwatched(videoId: episode.id)
            }
        } else {
            Button("Mark as Watched", systemImage: "checkmark.circle") {
                progress.markWatched(videoId: episode.id, metaID: meta.id, metaType: meta.type, title: meta.name,
                                     duration: progress.entry(for: episode.id)?.duration ?? DetailFormat.runtimeSeconds(meta.runtime))
            }
            if progress.entry(for: episode.id) != nil {
                Button("Clear Progress", systemImage: "xmark.circle") { progress.markUnwatched(videoId: episode.id) }
            }
        }
        Divider()
        Button("Download Best Stream", systemImage: "arrow.down.circle") { onDownloadBest(episode) }
    }
}

private struct SeasonPill: View {
    var title: String
    var isSelected: Bool
    var isComplete: Bool
    var namespace: Namespace.ID
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(isSelected ? Color.black.opacity(0.7) : Theme.Palette.success)
                }
            }
            .font(Theme.Font.headline)
            .foregroundStyle(isSelected ? Color.black : Theme.Palette.textPrimary.opacity(hovering ? 1 : 0.8))
            .padding(.horizontal, Theme.Space.m)
            .frame(minHeight: Theme.Control.compactHeight)
            .background {
                if isSelected {
                    Capsule().fill(Color.white).matchedGeometryEffect(id: "selectedSeason", in: namespace)
                } else {
                    Capsule().fill(Color.white.opacity(hovering ? 0.16 : 0.08))
                        .overlay(Capsule().strokeBorder(Theme.Palette.stroke))
                }
            }
            .contentShape(Capsule().inset(by: Theme.Control.hitInset(for: Theme.Control.compactHeight)))
            .animation(Theme.Motion.hover, value: hovering)
        }
        .buttonStyle(DSPressableStyle(scale: 0.95, haptic: false))
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(isComplete ? "Watched" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct EpisodeCard: View {
    let meta: MetaDetail
    let video: Video
    var isUpNext: Bool
    var isAccountWatched = false
    @Environment(ProgressStore.self) private var progress
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dsIsPressed) private var pressed
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var hovering = false

    #if os(macOS)
    private let thumbWidth: CGFloat = 232
    #else
    private let thumbWidth: CGFloat = 136
    #endif

    /// Phone: badges and the overview move below the thumbnail row so the title keeps its width.
    private var isPhone: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    private var entry: ProgressStore.Entry? { progress.entry(for: video.id) }
    private var isWatched: Bool { (entry?.isFinished ?? false) || isAccountWatched }
    private var inProgress: Bool { (entry?.fraction ?? 0) > 0 && !isWatched }
    private var isUpcoming: Bool { DetailFormat.isUpcoming(video) }
    private var downloadState: DownloadBadgeState? { DownloadBadgeState.of(video.id, library: library, downloads: downloads) }

    private var metaLine: String {
        var parts: [String] = []
        if let code = video.episodeCode { parts.append(code) }
        if let d = entry?.duration, d > 60 { parts.append(DetailFormat.duration(d)) }
        else if let r = DetailFormat.runtimeSeconds(meta.runtime) { parts.append(DetailFormat.duration(r)) }
        if let date = DisplayFormat.date(video.released) { parts.append(date) }
        return parts.joined(separator: " · ")
    }

    private var overview: String? {
        guard let text = video.overview ?? video.description, !text.isEmpty else { return nil }
        return text
    }

    private var hasBadges: Bool { (isUpNext && !isUpcoming) || isUpcoming || downloadState != nil }

    private var titleText: some View {
        Text(video.displayTitle)
            .font(Theme.Font.headline)
            .foregroundStyle(isWatched ? Theme.Palette.textSecondary : Theme.Palette.textPrimary)
            .lineLimit(2)
    }

    private var metaText: some View {
        Text(metaLine)
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textTertiary)
            .monospacedDigit()
            .lineLimit(1)
    }

    private func overviewText(_ text: String, lines: Int) -> some View {
        Text(text)
            .foregroundStyle(Theme.Palette.textSecondary.opacity(isWatched ? 0.75 : 1))
            .lineLimit(lines)
    }

    @ViewBuilder private var remainingLabel: some View {
        if inProgress, let entry, let left = ProgressStore.remainingText(seconds: entry.seconds, duration: entry.duration) {
            Label(left, systemImage: "clock")
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(Theme.Palette.progress)
        }
    }

    var body: some View {
        Group {
            if isPhone { phoneLayout } else { wideLayout }
        }
        .detailCard(highlighted: isUpNext, padding: Theme.Space.s)
        .opacity(isUpcoming ? 0.55 : 1)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows streams for this episode")
    }

    private var wideLayout: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            thumbnail
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                    titleText
                    Spacer(minLength: Theme.Space.xs)
                    statusBadges
                }
                metaText
                if let overview { overviewText(overview, lines: 2).font(Theme.Font.body).padding(.top, 2) }
                remainingLabel.padding(.top, 2)
            }
            .padding(.vertical, 2)
        }
    }

    private var phoneLayout: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .center, spacing: Theme.Space.s) {
                thumbnail
                VStack(alignment: .leading, spacing: 4) {
                    titleText
                    metaText
                    remainingLabel
                    if hasBadges { statusBadges.padding(.top, 2) }
                }
                Spacer(minLength: 0)
            }
            if let overview { overviewText(overview, lines: 3).font(.system(size: 13)) }
        }
    }

    @ViewBuilder private var statusBadges: some View {
        HStack(spacing: 5) {
            if isUpNext && !isUpcoming { Badge(text: inProgress ? "Continue" : "Up next", systemImage: "play.fill", tint: Theme.Palette.accent) }
            if isUpcoming { Badge(text: "Upcoming", tint: Theme.Palette.warning) }
            switch downloadState {
            case .saved?: Badge(text: "Downloaded", systemImage: "arrow.down.circle.fill", tint: Theme.Palette.success)
            case .queued?: Badge(text: "Downloading", systemImage: "arrow.down.circle", tint: Theme.Palette.textSecondary)
            case nil: EmptyView()
            }
        }
        .fixedSize()
    }

    private var thumbnail: some View {
        RemoteImage(url: video.thumbnail?.imageURL, maxPixelSize: Int(thumbWidth * 2)) {
            ZStack {
                LinearGradient(colors: [Theme.Palette.surfaceHigh, Theme.Palette.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "film").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .frame(width: thumbWidth, height: thumbWidth * 9 / 16)
        .saturation(isWatched ? 0.35 : 1)
        .brightness(isWatched ? -0.12 : 0)
        .overlay {
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
        }
        .overlay(alignment: .bottomLeading) {
            if let n = video.episode {
                Text("\(n)")
                    .font(.system(size: thumbWidth > 180 ? 26 : 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 4)
                    .padding(.horizontal, Theme.Space.xs)
                    .padding(.bottom, inProgress ? 10 : 4)
            }
        }
        .overlay(alignment: .bottom) {
            if inProgress, let entry {
                WatchProgressBar(fraction: entry.fraction, height: 4)
                    .padding(.horizontal, Theme.Space.xs)
                    .padding(.bottom, 6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isWatched { WatchedCheck(size: 22).padding(6) }
        }
        .overlay {
            Image(systemName: "play.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Circle().fill(.black.opacity(0.45)))
                .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
                .opacity((hovering || pressed) && !isUpcoming ? 1 : 0)
                .scaleEffect(hovering || pressed ? 1 : 0.85)
                .animation(Theme.Motion.hover, value: hovering || pressed)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.Palette.stroke))
    }
}
