import SwiftUI

/// Offline detail for a saved title: local hero, Resume/Play for the next unfinished item, episode cards.
/// OWNER: UI Agent 5.
struct SavedDetailView: View {
    let titleID: String

    @Environment(LibraryStore.self) private var library
    @Environment(ProgressStore.self) private var progress
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.play) private var play
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: SidecarMeta.SidecarItem?
    @State private var confirmDeleteTitle = false
    @State private var errorMessage: String?
    /// Set while deleting what's left of the title, so the page pops instead of flashing "Not saved".
    @State private var leaving = false

    #if os(macOS)
    private let heroHeight: CGFloat = 480
    #else
    private let heroHeight: CGFloat = 360
    #endif

    var body: some View {
        Group {
            if let title = library.title(id: titleID) {
                detail(title)
            } else if leaving {
                Color.clear
            } else {
                LibraryEmptyState(
                    symbol: "square.stack",
                    satellites: ["film", "tv"],
                    title: "Not saved",
                    message: "This title is no longer in your library."
                ) {
                    Button { dismiss() } label: { Label("Back", systemImage: "chevron.left") }
                        .buttonStyle(.ds(.secondary))
                }
            }
        }
        .dsCanvas()
        .navigationTitle(library.title(id: titleID)?.meta.name ?? "Saved")
        .alert("Couldn't delete", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func detail(_ title: SavedTitle) -> some View {
        let state = SavedTitleProgress(title: title, progress: progress)
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                hero(title, state: state)
                TitleDownloadsSection(metaID: title.id)
                    .padding(.horizontal, Theme.Space.page)
                items(title, state: state)
                    .padding(.horizontal, Theme.Space.page)
            }
            .padding(.bottom, Theme.Space.xxl)
        }
        .ignoresSafeArea(edges: .top)
        .confirmationDialog(
            "Delete \(pendingDelete.map { label(for: $0, in: title) } ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { item in
            Button(LibraryDeletion.verb, role: .destructive) {
                let isLast = title.meta.items.count == 1
                leaving = isLast
                Task {
                    do {
                        try await LibraryDeletion.delete(item, in: title, library: library, downloads: downloads)
                        if isLast { dismiss() }
                    } catch {
                        leaving = false
                        errorMessage = error.localizedDescription
                    }
                }
            }
        } message: { item in
            Text(LibraryDeletion.itemMessage(item, in: title, downloads: downloads))
        }
        .confirmationDialog("Delete \(title.meta.name)?", isPresented: $confirmDeleteTitle, titleVisibility: .visible) {
            Button(LibraryDeletion.verb, role: .destructive) {
                leaving = true
                Task {
                    do {
                        try await LibraryDeletion.delete(title: title, library: library, downloads: downloads)
                        dismiss()
                    } catch {
                        leaving = false
                        errorMessage = error.localizedDescription
                    }
                }
            }
        } message: {
            Text(LibraryDeletion.titleMessage(title, downloads: downloads))
        }
    }

    // MARK: Hero

    private func hero(_ title: SavedTitle, state: SavedTitleProgress) -> some View {
        // The text drives the height (min heroHeight), so long titles/metadata on a phone push the
        // artwork taller instead of overflowing up under the navigation bar.
        heroContent(title, state: state)
            .padding(.horizontal, Theme.Space.page)
            .padding(.bottom, Theme.Space.s)
            .padding(.top, 110)
            .frame(maxWidth: .infinity, minHeight: heroHeight, alignment: .bottomLeading)
            .background {
                Color.clear
                    .overlay {
                        LibArtwork(folder: title.folder, name: title.meta.name, kind: .landscape, maxPixelSize: 2000)
                    }
                    .clipped()
                    .overlay {
                        LinearGradient(colors: [Theme.Palette.canvas.opacity(0.95), Theme.Palette.canvas.opacity(0.55), .clear],
                                       startPoint: .leading, endPoint: UnitPoint(x: 0.75, y: 0.5))
                    }
                    .overlay {
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0.3),
                            .init(color: Theme.Palette.canvas.opacity(0.7), location: 0.75),
                            .init(color: Theme.Palette.canvas, location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                    }
            }
    }

    private func heroContent(_ title: SavedTitle, state: SavedTitleProgress) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.xs) {
                Badge(text: "Downloaded", systemImage: "arrow.down.circle.fill", tint: Theme.Palette.success)
                Badge(text: "Plays offline", systemImage: "wifi.slash", tint: Theme.Palette.textSecondary)
            }
            Text(title.meta.name)
                .font(LibMetrics.isTouch ? .system(size: 34, weight: .heavy) : Theme.Font.display)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .shadow(color: .black.opacity(0.4), radius: 10)
            Text(metadataLine(title))
                .font(Theme.Font.headline)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(2)
            if let description = title.meta.description, !description.isEmpty {
                Text(description)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textPrimary.opacity(0.85))
                    .lineLimit(3)
                    .frame(maxWidth: 620, alignment: .leading)
                    .textSelection(.enabled)
            }
            if let next = state.nextUp {
                let watch = state.state(next)
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    HStack(spacing: Theme.Space.xs) {
                        LibPlayButton(title: primaryTitle(next, watch: watch, title: title)) {
                            play(request(for: next, in: title, startAt: watch.resumeAt ?? 0))
                        }
                        if watch.resumeAt != nil {
                            LibIconButton(title: "Play from Beginning", systemImage: "backward.end.fill") {
                                play(request(for: next, in: title, startAt: 0))
                            }
                            .transition(.scale.combined(with: .opacity))
                        }
                        #if os(macOS)
                        LibIconButton(title: "Show in Finder", systemImage: "folder") { LibFinder.show(title.folder) }
                        #endif
                        LibIconButton(title: "Delete Title…", systemImage: "trash", role: .destructive) {
                            confirmDeleteTitle = true
                        }
                    }
                    .frame(maxWidth: LibMetrics.expandsActions ? 520 : nil, alignment: .leading)
                    if let resumeAt = watch.resumeAt {
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Resume at \(LibFormat.clock(resumeAt))")
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                Spacer(minLength: Theme.Space.xs)
                                if let left = watch.remainingText {
                                    Text(left).foregroundStyle(Theme.Palette.textSecondary)
                                }
                            }
                            .font(Theme.Font.caption)
                            .monospacedDigit()
                            .lineLimit(1)
                            WatchProgressBar(fraction: watch.fraction, height: 4)
                        }
                        .frame(maxWidth: LibMetrics.expandsActions ? 520 : 360, alignment: .leading)
                        .transition(.opacity)
                    }
                }
                .padding(.top, Theme.Space.xs)
                .animation(LibMotion.spring, value: watch)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    private func metadataLine(_ title: SavedTitle) -> String {
        var parts: [String] = []
        if let year = title.meta.year { parts.append(year) }
        parts.append(title.meta.isSeries ? "Series" : "Movie")
        if title.meta.isSeries { parts.append(title.itemsSubtitle) }
        if title.totalBytes > 0 { parts.append(LibFormat.bytes(title.totalBytes)) }
        if let genres = title.meta.genres, !genres.isEmpty { parts.append(genres.prefix(3).joined(separator: ", ")) }
        return parts.joined(separator: "  ·  ")
    }

    private func primaryTitle(_ item: SidecarMeta.SidecarItem, watch: LibWatchState, title: SavedTitle) -> String {
        let verb = watch.resumeAt != nil ? "Resume" : (watch.isWatched ? "Play Again" : "Play")
        guard title.meta.isSeries, let code = item.episodeCode else { return verb }
        return "\(verb) \(code)"
    }

    // MARK: Items

    @ViewBuilder private func items(_ title: SavedTitle, state: SavedTitleProgress) -> some View {
        let sorted = title.meta.sortedItems
        if !title.meta.isSeries {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                LibrarySectionHeader(title: sorted.count == 1 ? "Your Download" : "Your Downloads", count: nil)
                ForEach(sorted) { card($0, in: title, state: state).transition(LibMotion.card) }
            }
            .animation(LibMotion.spring, value: sorted.map(\.videoId))
        } else {
            let seasons = Dictionary(grouping: sorted, by: { $0.season ?? 0 })
            let order = seasons.keys.filter { $0 > 0 }.sorted() + (seasons[0] != nil ? [0] : [])
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                ForEach(order, id: \.self) { season in
                    let episodes = seasons[season] ?? []
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        LibrarySectionHeader(title: season == 0 ? "Specials" : "Season \(season)", count: episodes.count)
                        ForEach(episodes) { card($0, in: title, state: state).transition(LibMotion.card) }
                    }
                    .transition(.opacity)
                }
            }
            .animation(LibMotion.spring, value: sorted.map(\.videoId))
        }
    }

    private func card(_ item: SidecarMeta.SidecarItem, in title: SavedTitle, state: SavedTitleProgress) -> some View {
        SavedItemCard(
            title: title,
            item: item,
            label: label(for: item, in: title),
            watch: state.state(item),
            isNextUp: state.nextUp?.videoId == item.videoId,
            onPlay: { startAt in play(request(for: item, in: title, startAt: startAt)) },
            onDelete: { pendingDelete = item }
        )
    }

    private func label(for item: SidecarMeta.SidecarItem, in title: SavedTitle) -> String {
        if !title.meta.isSeries { return item.title ?? title.meta.name }
        switch (item.episodeCode, item.title) {
        case let (c?, t?): return "\(c) · \(t)"
        case let (c?, nil): return c
        case let (nil, t?): return t
        default: return item.file
        }
    }

    private func request(for item: SidecarMeta.SidecarItem, in title: SavedTitle, startAt: Double) -> PlaybackRequest {
        PlaybackRequest(
            url: title.fileURL(for: item),
            title: title.meta.name,
            subtitle: title.meta.isSeries ? label(for: item, in: title) : title.meta.year,
            metaID: title.meta.id,
            metaType: title.meta.type,
            videoId: item.videoId,
            isLocal: true,
            filenameHint: item.file,
            posterURL: title.posterURL?.absoluteString,
            backgroundURL: title.backdropURL?.absoluteString,
            startAt: startAt
        )
    }
}

/// One saved episode/movie file: thumbnail with progress, metadata, and actions.
private struct SavedItemCard: View {
    let title: SavedTitle
    let item: SidecarMeta.SidecarItem
    let label: String
    let watch: LibWatchState
    let isNextUp: Bool
    let onPlay: (Double) -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    #if os(macOS)
    private let thumbWidth: CGFloat = 240
    #else
    private let thumbWidth: CGFloat = 128
    #endif

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            Button { onPlay(watch.resumeAt ?? 0) } label: {
                HStack(alignment: .center, spacing: Theme.Space.m) {
                    thumbnail
                    info
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(DSPressableStyle(scale: 0.98))
            .accessibilityLabel("\(watch.resumeAt == nil ? "Play" : "Resume") \(label)")

            actions
        }
        .padding(Theme.Space.s)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
                .fill(hovering ? Theme.Palette.surfaceHigh : Theme.Palette.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
                .strokeBorder(isNextUp ? Theme.Palette.accent.opacity(0.45) : Theme.Palette.stroke)
        }
        .animation(Theme.Motion.hover, value: hovering)
        .animation(LibMotion.snappy, value: watch)
        .onHover { hovering = $0 }
        .libContextMenuShape(Theme.Radius.l)
        .contextMenu {
            Button(watch.resumeAt == nil ? "Play" : "Resume at \(LibFormat.clock(watch.resumeAt ?? 0))", systemImage: "play.fill") {
                onPlay(watch.resumeAt ?? 0)
            }
            if watch.resumeAt != nil {
                Button("Play from Beginning", systemImage: "backward.end") { onPlay(0) }
            }
            #if os(macOS)
            Button("Show in Finder", systemImage: "folder") { LibFinder.show(title.fileURL(for: item)) }
            #endif
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }

    private var thumbnail: some View {
        Color.clear
            .frame(width: thumbWidth, height: thumbWidth * 9 / 16)
            .overlay { LibArtwork(folder: title.folder, name: title.meta.name, kind: .landscape, maxPixelSize: 700) }
            .clipped()
            .overlay(Color.black.opacity(hovering ? 0.35 : 0.12))
            .overlay {
                Image(systemName: "play.fill")
                    .font(.system(size: LibMetrics.isTouch ? 13 : 18, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: LibMetrics.isTouch ? 32 : 44, height: LibMetrics.isTouch ? 32 : 44)
                    .background(Circle().fill(.white.opacity(0.9)))
                    .shadow(color: .black.opacity(0.4), radius: 8)
                    .scaleEffect(hovering || LibMetrics.isTouch ? 1 : 0.85)
                    .opacity(hovering || LibMetrics.isTouch ? 1 : 0.0)
            }
            .overlay(alignment: .topTrailing) {
                if watch.isWatched { WatchedCheck(size: 22).padding(Theme.Space.xs) }
            }
            .overlay(alignment: .bottomLeading) {
                if let code = item.episodeCode {
                    Text(code)
                        .font(Theme.Font.micro)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(Theme.Space.xs)
                        .padding(.bottom, watch.fraction > 0 && !watch.isWatched ? 6 : 0)
                }
            }
            .overlay(alignment: .bottom) {
                if watch.fraction > 0, !watch.isWatched {
                    WatchProgressBar(fraction: watch.fraction, height: 4)
                        .padding(.horizontal, Theme.Space.xs)
                        .padding(.bottom, Theme.Space.xs)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if isNextUp, !watch.isWatched {
                Badge(text: watch.isInProgress ? "CONTINUE" : "UP NEXT", tint: Theme.Palette.accent)
            }
            Text(displayTitle)
                .font(LibMetrics.isTouch ? .system(size: 16, weight: .semibold) : Theme.Font.rowTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(2)
            Text(metaLine)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .lineLimit(1)
            let tags = LibReleaseTags.from(item.file)
            if !tags.isEmpty { LibBadgeRow(items: tags.map { LibBadgeRow.Item(text: $0) }) }
            if watch.isWatched {
                Label("Watched", systemImage: "checkmark.circle.fill")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.success)
                    .transition(.opacity)
            } else if let text = watch.statusText {
                ViewThatFits(in: .horizontal) {
                    Text(text)
                    if let left = watch.remainingText { Text(left) }
                }
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.progress)
                .monospacedDigit()
                .lineLimit(1)
                .transition(.opacity)
            }
        }
    }

    private var displayTitle: String {
        guard title.meta.isSeries else { return item.title ?? title.meta.name }
        switch (item.episode, item.title) {
        case let (e?, t?): return "\(e). \(t)"
        case let (e?, nil): return "Episode \(e)"
        default: return label
        }
    }

    private var metaLine: String {
        [title.meta.isSeries ? item.episodeCode : title.meta.year,
         LibFormat.runtime(watch.duration ?? item.durationSeconds),
         item.sizeBytes.map(LibFormat.bytes)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.xs) {
            #if os(macOS)
            LibIconButton(title: "Show in Finder", systemImage: "folder", size: LibMetrics.compactControl,
                          accessibilityTitle: "Show \(label) in Finder") { LibFinder.show(title.fileURL(for: item)) }
            #endif
            LibIconButton(title: "Delete…", systemImage: "trash", size: LibMetrics.compactControl, role: .destructive,
                          accessibilityTitle: "Delete \(label)", action: onDelete)
        }
        .padding(.trailing, LibMetrics.isTouch ? 0 : Theme.Space.xs)
    }
}

/// Unfinished downloads of this title, so episodes still on their way don't look missing.
private struct TitleDownloadsSection: View {
    let metaID: String
    @Environment(DownloadManager.self) private var downloads
    @Environment(AppServices.self) private var services

    private var active: [DownloadItem] {
        downloads.items
            .filter { $0.metaID == metaID && [.queued, .downloading, .waiting, .paused].contains($0.state) }
            .sorted { ($0.season ?? 0, $0.episode ?? 0, $0.createdAt) < ($1.season ?? 0, $1.episode ?? 0, $1.createdAt) }
    }

    var body: some View {
        let active = active
        if !active.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                LibrarySectionHeader(title: "Downloading", count: active.count) {
                    Button { services.selection = .downloads } label: { Label("View Downloads", systemImage: "arrow.down.circle") }
                        .buttonStyle(.ds(.ghost, compact: true))
                }
                VStack(spacing: Theme.Space.xs) {
                    ForEach(active) { row($0).transition(LibMotion.card) }
                }
            }
            .animation(LibMotion.spring, value: active.map(\.id))
        }
    }

    private func row(_ item: DownloadItem) -> some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text([item.episodeCode, item.episodeTitle].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? item.titleName)
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                LibTransferBar(fraction: item.progress, paused: item.state != .downloading, height: 6)
            }
            Text(status(item))
                .font(Theme.Font.caption)
                .foregroundStyle(item.state == .waiting ? Theme.Palette.warning : Theme.Palette.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
                .frame(minWidth: 72, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.Palette.stroke))
        .accessibilityElement(children: .combine)
    }

    private func status(_ item: DownloadItem) -> String {
        switch item.state {
        case .paused: "Paused"
        case .queued: "Queued"
        case .waiting: "Waiting for network"
        default: item.bytesExpected > 0 ? "\(Int((item.progress * 100).rounded(.down)))%" : "Starting…"
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
