import SwiftUI

/// Full-bleed hero (backdrop, logo, metadata, Play/Resume), then episodes (series) or streams (movies). OWNER: UI Agent 3.
struct DetailView: View {
    let preview: MetaPreview
    @Environment(AddonRegistry.self) private var registry
    @Environment(ProgressStore.self) private var progress
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(LibrarySync.self) private var librarySync
    @Environment(\.play) private var play
    @State private var meta: MetaDetail?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var season: Int?
    /// Episode whose stream picker sheet is open.
    @State private var streamSheet: Video?
    @State private var streams = StreamCache()
    @State private var isStartingPlayback = false
    @StreamQualityPreference private var preferredQuality

    /// Loaded meta, or the catalog preview while loading / if every meta addon failed.
    private var display: MetaDetail {
        if var meta {
            meta.poster = meta.poster ?? preview.poster
            meta.description = meta.description ?? preview.description
            meta.imdbRating = meta.imdbRating ?? preview.imdbRating
            return meta
        }
        return MetaDetail(id: preview.id, type: preview.type, name: preview.name, poster: preview.poster,
                          posterShape: preview.posterShape, description: preview.description,
                          releaseInfo: preview.releaseInfo, imdbRating: preview.imdbRating)
    }

    private var isMovie: Bool { preview.type == "movie" || (display.videos ?? []).isEmpty && preview.type != "series" }
    private var hasEpisodes: Bool { !isMovie && !(display.videos ?? []).isEmpty }

    var body: some View {
        let meta = display
        let nextUp = isMovie ? nil : NextUp.resolve(meta: meta, progress: progress)
        ZStack(alignment: .top) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        DetailHero(meta: meta) {
                            actions(meta: meta, nextUp: nextUp, proxy: proxy)
                        }
                        VStack(alignment: .leading, spacing: Theme.Space.l) {
                            if let loadError {
                                ErrorBanner(title: "Showing limited info", messages: [loadError]) {
                                    Task { await load() }
                                }
                            }
                            sections(meta: meta, nextUp: nextUp)
                        }
                        .padding(.horizontal, Theme.Space.page)
                        .padding(.top, Theme.Space.l)
                        .padding(.bottom, Theme.Space.xxl)
                        .frame(maxWidth: 1180, alignment: .leading)
                    }
                }
                .scrollIndicators(.automatic)
                #if DEBUG
                .task(id: isLoading) {
                    guard !isLoading, let target = UserDefaults.standard.string(forKey: "DeStreamScrollTo") else { return }
                    try? await Task.sleep(for: .seconds(1.5))
                    proxy.scrollTo(target, anchor: .top)
                }
                #endif
            }
            .ignoresSafeArea(edges: .top)
            #if os(iOS)
            TopBarScrim(fadeBelow: 16)
            #endif
        }
        .dsCanvas()
        .navigationTitle(meta.name)
        #if os(macOS)
        .toolbarBackground(.hidden, for: .windowToolbar)
        #else
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .sheet(item: $streamSheet) { episode in
            EpisodeStreamSheet(meta: meta, video: episode, cache: streams) { streamSheet = nil }
        }
        .task(id: preview.id) { await load() }
    }

    // MARK: Sections

    @ViewBuilder private func sections(meta: MetaDetail, nextUp: NextUp?) -> some View {
        if hasEpisodes {
            EpisodeListView(
                meta: meta,
                season: $season,
                upNextID: nextUp?.video.id,
                onSelect: { streamSheet = $0 },
                onPlayBest: { video in
                    Task { await playBest(meta: meta, video: video, startAt: progress.resumePosition(for: video.id)) }
                },
                onDownloadBest: { video in Task { await downloadBest(meta: meta, video: video) } }
            )
            .id("episodes")
            .transition(.opacity)
        } else if isLoading && !isMovie {
            EpisodeListSkeleton()
                .transition(.opacity)
        } else if preview.type == "series" {
            NoEpisodesState(failed: loadError != nil) { Task { await load() } }
        } else {
            StreamListView(meta: meta, video: nil, cache: streams)
                .id("streams")
        }
    }

    // MARK: Hero actions

    @ViewBuilder private func actions(meta: MetaDetail, nextUp: NextUp?, proxy: ScrollViewProxy) -> some View {
        if isMovie {
            movieActions(meta: meta, proxy: proxy)
        } else if let nextUp {
            seriesActions(meta: meta, nextUp: nextUp)
        }
    }

    @ViewBuilder private func movieActions(meta: MetaDetail, proxy: ScrollViewProxy) -> some View {
        let entry = progress.entry(for: meta.id)
        let resume = progress.resumePosition(for: meta.id)
        let result = streams.result(for: meta.id)
        let best = streams.best(for: meta.id, preferring: preferredQuality)
        let noCached = result.hasLoaded && best == nil
        let downloadState = DownloadBadgeState.of(meta.id, library: library, downloads: downloads)
        let watched = progress.isWatched(meta.id)

        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HeroActionRow {
                if noCached {
                    HeroPlayButton(title: "Choose Stream", systemImage: "list.bullet", isBusy: false) {
                        withAnimation(Theme.Motion.appear) { proxy.scrollTo("streams", anchor: .top) }
                    }
                } else {
                    HeroPlayButton(title: resume != nil ? "Resume" : "Play",
                                   detail: resume != nil ? entry.flatMap { ProgressStore.remainingText(seconds: $0.seconds, duration: $0.duration) } : nil,
                                   systemImage: "play.fill",
                                   isBusy: isStartingPlayback) {
                        Task {
                            if await !playBest(meta: meta, video: nil, startAt: resume) {
                                withAnimation(Theme.Motion.appear) { proxy.scrollTo("streams", anchor: .top) }
                            }
                        }
                    }
                }
            } secondary: {
                DetailIconButton(systemImage: downloadState == .saved ? "arrow.down.circle.fill" : downloadState == .queued ? "arrow.down.circle.dotted" : "arrow.down",
                                 caption: downloadState == .saved ? "Downloaded" : downloadState == .queued ? "Downloading" : "Download",
                                 help: downloadState == .saved ? "Downloaded" : downloadState == .queued ? "Downloading" : "Download best stream",
                                 isOn: downloadState != nil) {
                    Task {
                        if await !downloadBest(meta: meta, video: nil) {
                            withAnimation(Theme.Motion.appear) { proxy.scrollTo("streams", anchor: .top) }
                        }
                    }
                }
                .disabled(downloadState != nil)
                DetailIconButton(systemImage: watched ? "checkmark.circle.fill" : "checkmark",
                                 caption: watched ? "Watched" : "Mark watched",
                                 help: watched ? "Mark as unwatched" : "Mark as watched", isOn: watched) {
                    toggleWatched(meta: meta, videoId: meta.id)
                }
                LibraryToggleButton(meta: meta)
            }
            if watched {
                WatchedLine()
            } else if let entry, entry.fraction > 0 {
                ProgressLine(entry: entry, label: nil)
            }
        }
        .task(id: meta.id) { await streams.load(registry: registry, type: meta.type, id: meta.id) }
    }

    @ViewBuilder private func seriesActions(meta: MetaDetail, nextUp: NextUp) -> some View {
        let video = nextUp.video
        let code = video.episodeCode ?? "E\(video.episode ?? 1)"
        let upcoming = DetailFormat.isUpcoming(video)
        let downloadState = DownloadBadgeState.of(video.id, library: library, downloads: downloads)
        let watched = progress.isWatched(video.id)

        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HeroActionRow {
                if upcoming {
                    HeroPlayButton(title: "\(code) airs \(DisplayFormat.date(video.released) ?? "soon")",
                                   systemImage: "calendar", isBusy: false) { streamSheet = video }
                        .disabled(true)
                } else {
                    HeroPlayButton(title: nextUp.isInProgress ? "Resume \(code)" : "Play \(code)",
                                   detail: nextUp.isInProgress ? nextUp.entry.flatMap { ProgressStore.remainingText(seconds: $0.seconds, duration: $0.duration) } : nil,
                                   systemImage: "play.fill",
                                   isBusy: isStartingPlayback) {
                        Task {
                            let start = nextUp.isInProgress ? progress.resumePosition(for: video.id) : nil
                            if await !playBest(meta: meta, video: video, startAt: start) { streamSheet = video }
                        }
                    }
                }
            } secondary: {
                DetailIconButton(systemImage: "list.bullet", caption: "Streams", help: "Choose a stream for \(code)") { streamSheet = video }
                DetailIconButton(systemImage: downloadState == .saved ? "arrow.down.circle.fill" : downloadState == .queued ? "arrow.down.circle.dotted" : "arrow.down",
                                 caption: downloadState == .saved ? "Downloaded" : downloadState == .queued ? "Downloading" : "Download",
                                 help: downloadState == .saved ? "\(code) downloaded" : downloadState == .queued ? "Downloading \(code)" : "Download \(code)",
                                 isOn: downloadState != nil) {
                    Task { if await !downloadBest(meta: meta, video: video) { streamSheet = video } }
                }
                .disabled(downloadState != nil || upcoming)
                DetailIconButton(systemImage: watched ? "checkmark.circle.fill" : "checkmark",
                                 caption: watched ? "Watched" : "Mark watched",
                                 help: watched ? "Mark \(code) as unwatched" : "Mark \(code) as watched", isOn: watched) {
                    toggleWatched(meta: meta, videoId: video.id)
                }
                .disabled(upcoming)
                LibraryToggleButton(meta: meta)
            }
            if nextUp.isInProgress, let entry = nextUp.entry {
                ProgressLine(entry: entry, label: "\(code) · \(video.displayTitle)")
            } else {
                Text(nextUp.isRewatch ? "You've watched every episode · start again from \(code)" : "\(code) · \(video.displayTitle)")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .task(id: video.id) {
            guard !upcoming else { return }
            await streams.load(registry: registry, type: meta.type, id: video.id)
        }
    }

    // MARK: Behaviour

    /// Plays the first cached stream. Returns false when there is none (the caller then shows the stream list).
    @discardableResult
    private func playBest(meta: MetaDetail, video: Video?, startAt: Double? = nil) async -> Bool {
        // A double click (or a second tap while streams load) must not open a second player.
        guard !isStartingPlayback else { return true }
        let id = video?.id ?? meta.id
        isStartingPlayback = true
        defer { isStartingPlayback = false }
        await streams.load(registry: registry, type: meta.type, id: id)
        guard let best = streams.best(for: id, preferring: preferredQuality),
              let request = DetailPlayback.request(meta: meta, video: video, item: best, startAt: startAt)
        else {
            if video != nil, streamSheet == nil { streamSheet = video }
            return false
        }
        play(request)
        // Stay busy while the player opens, which also swallows the second click of a double click.
        try? await Task.sleep(for: .milliseconds(800))
        return true
    }

    @discardableResult
    private func downloadBest(meta: MetaDetail, video: Video?) async -> Bool {
        let id = video?.id ?? meta.id
        guard DownloadBadgeState.of(id, library: library, downloads: downloads) == nil else { return true }
        await streams.load(registry: registry, type: meta.type, id: id)
        guard let best = streams.best(for: id, preferring: preferredQuality) else {
            if video != nil, streamSheet == nil { streamSheet = video }
            return false
        }
        downloads.enqueue(meta: meta, video: video, stream: best)
        return true
    }

    private func toggleWatched(meta: MetaDetail, videoId: String) {
        withAnimation(Theme.Motion.appear) {
            if progress.isWatched(videoId) {
                progress.markUnwatched(videoId: videoId)
            } else {
                progress.markWatched(videoId: videoId, metaID: meta.id, metaType: meta.type, title: meta.name,
                                     duration: progress.entry(for: videoId)?.duration ?? DetailFormat.runtimeSeconds(meta.runtime))
            }
        }
    }

    private func load() async {
        isLoading = true
        do {
            let loaded = try await registry.meta(type: preview.type, id: preview.id)
            withAnimation(Theme.Motion.content) {
                meta = loaded
                loadError = nil
            }
            if !(loaded.videos ?? []).isEmpty { librarySync.registerVideos(for: loaded) }
        } catch {
            if Task.isCancelled { return }
            withAnimation(Theme.Motion.content) { loadError = error.localizedDescription }
        }
        withAnimation(Theme.Motion.content) { isLoading = false }
        if season == nil || !(display.seasons.contains(season ?? -1)) {
            season = NextUp.resolve(meta: display, progress: progress)?.video.season ?? display.seasons.first
        }
        #if DEBUG
        if let target = UserDefaults.standard.string(forKey: "DeStreamOpenEpisode"),
           let video = display.videos?.first(where: { $0.id == target }) {
            streamSheet = video
        }
        if UserDefaults.standard.bool(forKey: "DeStreamAutoPlay") {
            let target = isMovie ? nil : NextUp.resolve(meta: display, progress: progress)?.video
            await playBest(meta: display, video: target, startAt: progress.resumePosition(for: target?.id ?? display.id))
        }
        #endif
    }
}

// MARK: - Hero

/// Bookmark in the signed-in Stremio account's library. Hidden when signed out, so it isn't confused with downloads ("Saved").
private struct LibraryToggleButton: View {
    let meta: MetaDetail
    @Environment(StremioAccount.self) private var account
    @Environment(LibrarySync.self) private var librarySync
    @Environment(SyncCoordinator.self) private var sync

    var body: some View {
        if account.isSignedIn {
            let inLibrary = librarySync.isInLibrary(meta.id)
            DetailIconButton(systemImage: inLibrary ? "bookmark.fill" : "bookmark",
                             caption: inLibrary ? "In Library" : "Library",
                             help: inLibrary ? "Remove from Library" : "Add to Library",
                             isOn: inLibrary) {
                withAnimation(Theme.Motion.appear) {
                    if inLibrary {
                        librarySync.removeFromLibrary(id: meta.id)
                    } else {
                        librarySync.addToLibrary(id: meta.id, type: meta.type, name: meta.name, poster: meta.poster)
                    }
                }
                sync.scheduleSync()
            }
        }
    }
}

private struct DetailHero<Actions: View>: View {
    let meta: MetaDetail
    @ViewBuilder var actions: Actions
    @State private var expanded = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    #if os(macOS)
    private let height: CGFloat = 580
    private let contentWidth: CGFloat = 620
    #else
    private let height: CGFloat = 560
    private let contentWidth: CGFloat = 560
    #endif

    private var isPhone: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        if isPhone { phoneBody } else { wideBody }
    }

    private var wideBody: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                titleView
                metaLine
                if let description = meta.description, !description.isEmpty {
                    descriptionView(description)
                }
                creditsView
                actions.padding(.top, Theme.Space.xs)
            }
            .frame(maxWidth: contentWidth, alignment: .leading)
            .padding(.horizontal, Theme.Space.page)
            .padding(.bottom, Theme.Space.l)
        }
        .frame(maxWidth: .infinity, minHeight: height, alignment: .bottomLeading)
    }

    /// Phone: art on top fading into the canvas, then title, actions and the overview stacked below.
    private var phoneBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(0.98, contentMode: .fit)
                .overlay { backdrop }
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                titleView
                metaLine
                actions
                    .padding(.top, Theme.Space.xxs)
                    .environment(\.detailActionsStacked, true)
                if let description = meta.description, !description.isEmpty {
                    descriptionView(description)
                }
                creditsView
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.top, -128)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var backdrop: some View {
        Color.clear
            .overlay {
                RemoteImage(url: (meta.background ?? meta.poster)?.imageURL, maxPixelSize: 2400) {
                    LinearGradient(colors: [Theme.Palette.accentSoft, Theme.Palette.canvas], startPoint: .topTrailing, endPoint: .bottomLeading)
                }
            }
            .clipped()
            .overlay {
                if !isPhone {
                    LinearGradient(stops: [
                        .init(color: Theme.Palette.canvas.opacity(0.92), location: 0),
                        .init(color: Theme.Palette.canvas.opacity(0.7), location: 0.32),
                        .init(color: Theme.Palette.canvas.opacity(0.0), location: 0.72),
                    ], startPoint: .leading, endPoint: .trailing)
                }
            }
            .overlay {
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.45), location: 0),
                    .init(color: .clear, location: 0.18),
                    .init(color: .clear, location: isPhone ? 0.4 : 0.5),
                    .init(color: Theme.Palette.canvas.opacity(0.85), location: 0.85),
                    .init(color: Theme.Palette.canvas, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var titleView: some View {
        RemoteImage(url: meta.logo?.imageURL, maxPixelSize: 1200, contentMode: .fit, lightensDarkCutouts: true) {
            Text(meta.name)
                .font(isPhone ? .system(size: 32, weight: .heavy) : Theme.Font.display)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: isPhone ? 280 : 440, maxHeight: isPhone ? 110 : 150, alignment: .bottomLeading)
        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
        .accessibilityLabel(meta.name)
        .accessibilityAddTraits(.isHeader)
    }

    private var metaLine: some View {
        FlowLayout(spacing: Theme.Space.xs, lineSpacing: Theme.Space.xs) {
            ForEach(Array(metaItems.enumerated()), id: \.offset) { index, item in
                HStack(spacing: Theme.Space.xs) {
                    if index > 0 { Text("·").foregroundStyle(Theme.Palette.textTertiary) }
                    item
                }
            }
            ForEach(meta.allGenres.prefix(4), id: \.self) { genre in
                Text(genre)
                    .font(Theme.Font.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textPrimary.opacity(0.85))
                    .padding(.horizontal, Theme.Space.xs).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                    .overlay(Capsule().strokeBorder(Theme.Palette.stroke))
            }
        }
        .font(isPhone ? .system(size: 14, weight: .semibold) : Theme.Font.headline)
        .foregroundStyle(Theme.Palette.textSecondary)
    }

    private var metaItems: [AnyView] {
        var items: [AnyView] = []
        if let year = meta.displayYear, !year.isEmpty { items.append(AnyView(Text(year))) }
        if let runtime = meta.runtime, !runtime.isEmpty { items.append(AnyView(Text(runtime))) }
        if let rating = meta.imdbRating, !rating.isEmpty {
            items.append(AnyView(
                HStack(spacing: 4) {
                    Image(systemName: "star.fill").foregroundStyle(Theme.Palette.warning)
                    Text(rating).foregroundStyle(Theme.Palette.textPrimary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Rated \(rating)")
            ))
        }
        return items
    }

    @ViewBuilder
    private var creditsView: some View {
        let cast = (meta.cast ?? []).prefix(4)
        let director = (meta.director ?? []).prefix(2)
        if !cast.isEmpty || !director.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if !cast.isEmpty { creditLine("Starring", cast.joined(separator: ", ")) }
                if !director.isEmpty { creditLine("Director", director.joined(separator: ", ")) }
            }
        }
    }

    private func creditLine(_ label: String, _ value: String) -> some View {
        (Text(label + "  ").foregroundStyle(Theme.Palette.textTertiary)
            + Text(value).foregroundStyle(Theme.Palette.textSecondary))
            .font(Theme.Font.caption)
            .lineLimit(1)
    }

    private func descriptionView(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text(description)
                .font(Theme.Font.body.leading(.loose))
                .foregroundStyle(Theme.Palette.textPrimary.opacity(0.82))
                .lineLimit(expanded ? nil : (isPhone ? 3 : 4))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if description.count > (isPhone ? 160 : 240) {
                Button(expanded ? "Less" : "More") {
                    withAnimation(Theme.Motion.content) { expanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(Theme.Font.caption.weight(.bold))
                .foregroundStyle(Theme.Palette.textPrimary)
                .padding(.vertical, isPhone ? 8 : 0)
                .contentShape(Rectangle())
            }
        }
    }
}

/// The big white Play / Resume button. Return triggers it on macOS.
private struct HeroPlayButton: View {
    var title: String
    var detail: String? = nil
    var systemImage: String
    var isBusy: Bool
    var action: () -> Void
    @Environment(\.detailActionsStacked) private var stacked

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs) {
                ZStack {
                    Image(systemName: systemImage).opacity(isBusy ? 0 : 1)
                    if isBusy { ProgressView().controlSize(.small).tint(.black) }
                }
                .frame(width: 18)
                Text(title)
                if let detail {
                    Text("· \(detail)").fontWeight(.medium).opacity(0.7)
                }
            }
            .font(.system(size: 17, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            #if os(macOS)
            .padding(.horizontal, Theme.Space.xs)
            .frame(minHeight: 46)
            #endif
        }
        .buttonStyle(.ds(.primary, fullWidth: stacked))
        .keyboardShortcut(.defaultAction)
        .help(detail.map { "\(title) · \($0)" } ?? title)
    }
}

/// Play button beside the round secondary actions; on a phone the Play button spans the width and the
/// secondary actions share the row below it equally.
private struct HeroActionRow<Primary: View, Secondary: View>: View {
    @ViewBuilder var primary: Primary
    @ViewBuilder var secondary: Secondary
    @Environment(\.detailActionsStacked) private var stacked

    var body: some View {
        if stacked {
            VStack(spacing: Theme.Space.m) {
                primary
                HStack(alignment: .top, spacing: Theme.Space.xs) { secondary }
            }
        } else {
            HStack(spacing: Theme.Space.s) {
                primary
                secondary
            }
        }
    }
}

/// Shown for a series whose addons returned no episode list.
private struct NoEpisodesState: View {
    var failed: Bool
    var retry: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            Image(systemName: "rectangle.stack.badge.minus")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text("No episodes listed")
                .font(Theme.Font.headline)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(failed ? "The episode list couldn't be loaded. Use Retry above to try again." : "Your addons didn't return any episodes for this series.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
            if !failed {
                Button(action: retry) { Label("Try again", systemImage: "arrow.clockwise") }
                    .buttonStyle(.ds(.secondary, compact: true))
                    .padding(.top, Theme.Space.xxs)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .detailCard(padding: Theme.Space.l)
    }
}

/// Placeholder rows shown while a series' episodes load.
private struct EpisodeListSkeleton: View {
    #if os(macOS)
    private let thumbWidth: CGFloat = 232
    #else
    private let thumbWidth: CGFloat = 136
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            SkeletonBlock(width: 150, height: 26, cornerRadius: Theme.Radius.s)
            VStack(spacing: Theme.Space.xs) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        SkeletonBlock(width: thumbWidth, height: thumbWidth * 9 / 16, cornerRadius: Theme.Radius.m)
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            SkeletonBlock(width: 140, height: 14, cornerRadius: 3)
                            SkeletonBlock(width: 90, height: 10, cornerRadius: 3)
                        }
                        .padding(.top, 4)
                        Spacer(minLength: 0)
                    }
                    .detailCard(padding: Theme.Space.s)
                }
            }
        }
        .accessibilityLabel("Loading episodes")
    }
}

/// Thin progress bar + "34 min left" under the hero actions.
private struct ProgressLine: View {
    let entry: ProgressStore.Entry
    var label: String?

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            WatchProgressBar(fraction: entry.fraction, height: 4).frame(width: 180)
            if let left = ProgressStore.remainingText(seconds: entry.seconds, duration: entry.duration) {
                Text(left)
                    .font(Theme.Font.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .monospacedDigit()
            }
            if let label {
                Text(label).font(Theme.Font.caption).foregroundStyle(Theme.Palette.textTertiary).lineLimit(1)
            }
        }
    }
}

private struct WatchedLine: View {
    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            WatchedCheck(size: 18)
            Text("Watched").font(Theme.Font.caption.weight(.semibold)).foregroundStyle(Theme.Palette.success)
        }
    }
}

// MARK: - Episode stream sheet

private struct EpisodeStreamSheet: View {
    let meta: MetaDetail
    let video: Video
    let cache: StreamCache
    var dismiss: () -> Void
    @Environment(ProgressStore.self) private var progress

    #if os(macOS)
    private static let padding: CGFloat = Theme.Space.l
    #else
    private static let padding: CGFloat = Theme.Space.page
    #endif

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                StreamListView(meta: meta, video: video, cache: cache, onPlay: dismiss)
                    .padding(Self.padding)
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, idealWidth: 780, minHeight: 480, idealHeight: 640)
        #else
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .dsCanvas()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            RemoteImage(url: (video.thumbnail ?? meta.background)?.imageURL, maxPixelSize: 400) {
                Theme.Palette.surfaceHigh
            }
            .frame(width: 112, height: 63)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(meta.name).font(Theme.Font.caption).foregroundStyle(Theme.Palette.textTertiary)
                Text(DetailPlayback.episodeSubtitle(video))
                    .font(Theme.Font.rowTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                if let entry = progress.entry(for: video.id) {
                    if entry.isFinished {
                        Text("Watched").font(Theme.Font.caption.weight(.semibold)).foregroundStyle(Theme.Palette.success)
                    } else if let left = ProgressStore.remainingText(seconds: entry.seconds, duration: entry.duration) {
                        Text(left).font(Theme.Font.caption.weight(.semibold)).foregroundStyle(Theme.Palette.progress)
                    }
                }
            }
            Spacer()
            DetailIconButton(systemImage: "xmark", help: "Close", size: 32, action: dismiss)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Self.padding)
        .padding(.vertical, Theme.Space.m)
        .background(Theme.Palette.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.Palette.stroke).frame(height: 1) }
    }
}
