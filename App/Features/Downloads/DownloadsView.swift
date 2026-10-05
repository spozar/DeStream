import SwiftUI

/// Download queue: active transfers, finished files ready to play offline, and failures. OWNER: UI Agent 5.
struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(AppServices.self) private var services
    @Environment(NetworkMonitor.self) private var network
    @Environment(LibraryStore.self) private var library
    /// Completed items whose file isn't on disk; refreshed when the library or the list changes, not on every redraw.
    @State private var missingFiles: Set<UUID> = []

    private var active: [DownloadItem] {
        downloads.items.filter { [.queued, .downloading, .waiting, .paused].contains($0.state) }
            .sorted { $0.createdAt < $1.createdAt }
    }
    private var completed: [DownloadItem] {
        downloads.items.filter { $0.state == .completed }
            .sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
    }
    private var failed: [DownloadItem] {
        downloads.items.filter { $0.state == .failed }.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        ZStack {
            if downloads.items.isEmpty {
                emptyState.transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                list.transition(.opacity)
            }
        }
        .animation(LibMotion.spring, value: downloads.items.isEmpty)
        .pruningMissingDownloads(missing: $missingFiles)
        .dsCanvas()
        .dsPageTitle("Downloads")
    }

    /// Changes when an item is added, removed or changes state, so sections and cards animate together.
    private var layoutKey: [String] { downloads.items.map { "\($0.id)|\($0.state.rawValue)" } }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                LibPageHeader(title: "Downloads", subtitle: summary)
                if !active.isEmpty { activeSection.transition(.opacity) }
                if !failed.isEmpty { failedSection.transition(.opacity) }
                if !completed.isEmpty { completedSection.transition(.opacity) }
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.top, Theme.Space.l)
            .padding(.bottom, Theme.Space.xxl)
            .frame(maxWidth: 1400, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(LibMotion.spring, value: layoutKey)
        }
        .scrollContentBackground(.hidden)
    }

    private var summary: String {
        var parts: [String] = []
        if !active.isEmpty { parts.append("\(active.count) active") }
        if !completed.isEmpty { parts.append("\(completed.count) completed") }
        if !failed.isEmpty { parts.append("\(failed.count) failed") }
        let total = downloads.items.filter { $0.state != .failed }
            .reduce(Int64(0)) { $0 + max($1.bytesExpected, $1.bytesWritten) }
        if total > 0 { parts.append(LibFormat.bytes(total)) }
        return parts.joined(separator: " · ")
    }

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            LibrarySectionHeader(title: "Downloading", count: active.count)
            VStack(spacing: Self.cardSpacing) {
                ForEach(active) { ActiveDownloadCard(item: $0).transition(LibMotion.card) }
            }
        }
    }

    private var failedSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            LibrarySectionHeader(title: "Failed", count: failed.count)
            VStack(spacing: Self.cardSpacing) {
                ForEach(failed) { FailedDownloadCard(item: $0).transition(LibMotion.card) }
            }
        }
    }

    private var completedSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            LibrarySectionHeader(title: "Ready to Watch", count: completed.count) {
                Button { withAnimation(LibMotion.spring) { downloads.removeAllFinished() } } label: {
                    Label("Clear List", systemImage: "xmark.circle")
                }
                .buttonStyle(.ds(.ghost, compact: true))
                .help("Remove finished downloads from this list. Files stay in Saved.")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cardMin, maximum: 560), spacing: Self.cardSpacing, alignment: .top)],
                      alignment: .leading, spacing: Self.cardSpacing) {
                ForEach(completed) { item in
                    CompletedDownloadCard(item: item, fileExists: !missingFiles.contains(item.id), libraryAvailable: library.isAvailable)
                        .transition(LibMotion.card)
                }
            }
        }
    }

    #if os(macOS)
    private static let cardMin: CGFloat = 380
    private static let cardSpacing: CGFloat = Theme.Space.l
    private static let sectionSpacing: CGFloat = Theme.Space.xxl
    #else
    private static let cardMin: CGFloat = 300
    private static let cardSpacing: CGFloat = Theme.Space.m
    private static let sectionSpacing: CGFloat = Theme.Space.xl
    #endif

    private var emptyState: some View {
        LibraryEmptyState(
            symbol: "arrow.down",
            satellites: ["film", "tv", "sparkles.tv"],
            title: "No downloads yet",
            message: "Pick a stream and choose Download to keep it for offline viewing. Finished downloads stay in Saved and play without an internet connection."
        ) {
            if network.isOnline {
                Button { services.selection = .home } label: { Label("Browse Titles", systemImage: "sparkles") }
                    .buttonStyle(.ds(.primary))
            }
            Button { services.selection = .saved } label: { Label("Open Saved", systemImage: "square.stack.fill") }
                .buttonStyle(.ds(.secondary))
        }
    }
}

// MARK: - Shared item helpers

private extension DownloadItem {
    var episodeLine: String? {
        let parts = [episodeCode, episodeTitle].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Title folder for an item, valid before the download finishes (artwork is written at enqueue).
@MainActor private func titleFolder(_ item: DownloadItem, library: LibraryStore) -> URL {
    library.title(id: item.metaID)?.folder ?? LibraryWriter.folder(for: item.metaID, root: library.root)
}

// MARK: - Active

private struct ActiveDownloadCard: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(LibraryStore.self) private var library
    @Environment(NetworkMonitor.self) private var network
    @Environment(AppSettings.self) private var settings
    let item: DownloadItem
    @State private var confirmCancel = false

    private var isPaused: Bool { item.state == .paused }
    private var percent: Int { Int((item.progress * 100).rounded(.down)) }
    private var isMoving: Bool { item.state == .downloading && stall == nil }
    /// The file has arrived and is being moved into the library; pause/cancel no longer apply.
    private var isInstalling: Bool { item.state == .downloading && item.stagedFile != nil }

    private enum Stall { case offline, wifiOnly }

    /// Why a transfer isn't moving, when the app can tell. iOS background sessions never report
    /// "waiting for connectivity", so this also looks at the network itself.
    private var stall: Stall? {
        guard DownloadScheduler.isActive(item.state), !isInstalling else { return nil }
        if network.hasResolved, !network.isOnline { return .offline }
        #if os(iOS)
        if settings.downloadOnWiFiOnly, network.isExpensive, (downloads.bytesPerSecond(for: item.id) ?? 0) <= 0 { return .wifiOnly }
        #endif
        return item.state == .waiting ? .offline : nil
    }

    /// Cancelling throws away the partial file, so ask once there's something worth keeping.
    private func requestCancel() {
        if item.bytesWritten >= 50 * 1024 * 1024 {
            confirmCancel = true
        } else {
            withAnimation(LibMotion.spring) { downloads.cancel(item.id) }
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wide.frame(minWidth: 560)
            compact
        }
        .padding(Theme.Space.m)
        .background(card)
        .libContextMenuShape(Theme.Radius.l)
        .contextMenu { menu }
        .animation(LibMotion.snappy, value: item.state)
        .sensoryFeedback(.impact(weight: .light), trigger: item.state)
        .confirmationDialog("Cancel downloading \(item.titleName)?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel Download", role: .destructive) { withAnimation(LibMotion.spring) { downloads.cancel(item.id) } }
            Button(isPaused ? "Keep Paused" : "Keep Downloading", role: .cancel) {}
        } message: {
            Text("The \(LibFormat.bytes(item.bytesWritten)) downloaded so far will be discarded.")
        }
    }

    private var wide: some View {
        HStack(spacing: Theme.Space.l) {
            artwork
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                    titles(lineLimit: 1)
                    Spacer(minLength: Theme.Space.xs)
                    Badge(text: stateBadge.text, systemImage: stateBadge.systemImage, tint: stateBadge.tint)
                        .id(stateBadge.text)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                LibBadgeRow(items: infoBadges)
                LibTransferBar(fraction: item.progress, paused: !isMoving)
                    .padding(.top, Theme.Space.xxs)
                HStack(spacing: Theme.Space.s) {
                    statusRow(showsPercent: false)
                    controls(compact: true, expands: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var compact: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                LibArtwork(folder: titleFolder(item, library: library), name: item.titleName, kind: .poster, maxPixelSize: 300)
                    .frame(width: 60, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    titles(lineLimit: 2)
                    LibBadgeRow(items: [stateBadge] + infoBadges)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                LibTransferBar(fraction: item.progress, paused: !isMoving)
                statusRow(showsPercent: true)
            }
            controls(compact: false, expands: true)
        }
    }

    private var artwork: some View {
        LibArtwork(folder: titleFolder(item, library: library), name: item.titleName, kind: .landscape, maxPixelSize: 600)
            .frame(width: 240, height: 135)
            .overlay(LibScrim(strength: 0.7))
            .overlay(alignment: .bottomLeading) {
                Text("\(percent)%")
                    .font(.system(size: 22, weight: .heavy).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(value: Double(percent)))
                    .animation(LibMotion.snappy, value: percent)
                    .padding(Theme.Space.s)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
    }

    private func titles(lineLimit: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.titleName)
                .font(LibMetrics.isTouch ? .system(size: 17, weight: .bold) : Theme.Font.rowTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(lineLimit)
            if let line = item.episodeLine {
                Text(line).font(Theme.Font.body).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
            }
        }
    }

    private func statusRow(showsPercent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            if showsPercent, item.bytesExpected > 0 {
                Text("\(percent)%")
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .contentTransition(.numericText(value: Double(percent)))
                    .animation(LibMotion.snappy, value: percent)
            }
            Text(sizeText)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .layoutPriority(1)
            Spacer(minLength: Theme.Space.xs)
            if let detail = detailText {
                Text(detail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(stall != nil ? Theme.Palette.warning : Theme.Palette.textTertiary)
                    .transition(.opacity)
            }
        }
        .lineLimit(1)
        .monospacedDigit()
    }

    private func controls(compact: Bool, expands: Bool) -> some View {
        HStack(spacing: Theme.Space.xs) {
            Button {
                withAnimation(LibMotion.snappy) { isPaused ? downloads.resume(item.id) : downloads.pause(item.id) }
            } label: {
                Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.ds(isPaused ? .accent : .secondary, compact: compact, fullWidth: expands))
            LibIconButton(title: "Cancel Download", systemImage: "xmark",
                          size: compact ? LibMetrics.compactControl : LibMetrics.control, role: .destructive,
                          accessibilityTitle: "Cancel downloading \(item.titleName)") {
                requestCancel()
            }
        }
        .disabled(isInstalling)
    }

    @ViewBuilder private var menu: some View {
        if !isInstalling {
            if isPaused {
                Button("Resume Download", systemImage: "play") { downloads.resume(item.id) }
            } else {
                Button("Pause", systemImage: "pause") { downloads.pause(item.id) }
            }
            Button("Cancel Download", systemImage: "xmark", role: .destructive) { requestCancel() }
        }
    }

    private var stateBadge: LibBadgeRow.Item {
        switch stall {
        case .offline: return LibBadgeRow.Item(text: "Waiting for network", systemImage: "wifi.slash", tint: Theme.Palette.warning)
        case .wifiOnly: return LibBadgeRow.Item(text: "Waiting for Wi‑Fi", systemImage: "wifi", tint: Theme.Palette.warning)
        case nil: break
        }
        if isInstalling { return LibBadgeRow.Item(text: "Saving", systemImage: "tray.and.arrow.down.fill", tint: Theme.Palette.success) }
        return switch item.state {
        case .downloading: LibBadgeRow.Item(text: "Downloading", systemImage: "arrow.down", tint: Theme.Palette.accent)
        case .paused: LibBadgeRow.Item(text: "Paused", systemImage: "pause.fill", tint: Theme.Palette.textSecondary)
        case .waiting: LibBadgeRow.Item(text: "Waiting for network", systemImage: "wifi.slash", tint: Theme.Palette.warning)
        default: LibBadgeRow.Item(text: "Queued", systemImage: "clock", tint: Theme.Palette.textSecondary)
        }
    }

    private var infoBadges: [LibBadgeRow.Item] {
        [LibBadgeRow.Item(text: item.addonName, systemImage: "puzzlepiece.extension.fill", tint: Theme.Palette.textSecondary)]
            + LibReleaseTags.from(item.filename ?? item.filenameHint).map { LibBadgeRow.Item(text: $0) }
    }

    private var sizeText: String {
        if item.bytesExpected > 0 { return "\(LibFormat.bytes(item.bytesWritten)) of \(LibFormat.bytes(item.bytesExpected))" }
        if item.bytesWritten > 0 { return LibFormat.bytes(item.bytesWritten) }
        return isMoving ? "Starting…" : ""
    }

    private var detailText: String? {
        switch stall {
        case .offline: return "Resumes when online"
        case .wifiOnly: return "Wi‑Fi only is on in Settings"
        case nil: break
        }
        if isInstalling { return "Moving into your library…" }
        switch item.state {
        case .queued: return "Queued"
        case .waiting: return "Resumes when online"
        case .paused: return "Paused"
        default:
            var parts: [String] = []
            if let rate = downloads.bytesPerSecond(for: item.id), rate > 0 { parts.append("\(LibFormat.bytes(Int64(rate)))/s") }
            if let eta = downloads.eta(for: item), eta.isFinite { parts.append("\(LibFormat.eta(eta)) left") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
            .fill(Theme.Palette.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
                .strokeBorder(isMoving ? Theme.Palette.accent.opacity(0.3) : Theme.Palette.stroke))
    }
}

// MARK: - Completed

private struct CompletedDownloadCard: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(ProgressStore.self) private var progress
    @Environment(LibraryStore.self) private var library
    @Environment(\.play) private var play
    let item: DownloadItem
    let fileExists: Bool
    let libraryAvailable: Bool
    @State private var hovering = false

    private var savedItem: SidecarMeta.SidecarItem? {
        library.title(id: item.metaID)?.meta.items.first { $0.videoId == item.videoId }
    }
    private var watch: LibWatchState { LibWatchState.resolve(videoId: item.videoId, sidecar: savedItem, progress: progress) }
    private var fileURL: URL? { downloads.fileURL(for: item) }

    var body: some View {
        let watch = watch
        let request = playbackRequest(watch)
        VStack(alignment: .leading, spacing: 0) {
            Button { if let request { play(request) } } label: { hero(watch, canPlay: request != nil) }
                .buttonStyle(DSPressableStyle(scale: 0.99, haptic: false))
                .disabled(request == nil)
                .accessibilityLabel("\(primaryTitle(watch)) \(item.titleName)")
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                statusLine(watch)
                actions(watch, request: request)
            }
            .padding(Theme.Space.m)
        }
        .background(Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
            .strokeBorder(hovering ? Color.white.opacity(0.18) : Theme.Palette.stroke))
        .scaleEffect(hovering ? 1.015 : 1)
        .shadow(color: .black.opacity(hovering ? 0.5 : 0.25), radius: hovering ? 22 : 8, y: hovering ? 12 : 4)
        .animation(Theme.Motion.hover, value: hovering)
        .animation(LibMotion.snappy, value: watch)
        .onHover { hovering = $0 }
        .libContextMenuShape(Theme.Radius.l)
        .contextMenu { menu(watch) }
    }

    private func primaryTitle(_ watch: LibWatchState) -> String {
        watch.resumeAt != nil ? "Resume" : (watch.isWatched ? "Play Again" : "Play")
    }

    private func hero(_ watch: LibWatchState, canPlay: Bool) -> some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                LibArtwork(folder: titleFolder(item, library: library), name: item.titleName, kind: .landscape, maxPixelSize: 1200)
            }
            .clipped()
            .overlay(LibScrim())
            .overlay(alignment: .topLeading) {
                LibBadgeRow(items: heroBadges)
                    .padding(Theme.Space.s)
                    .padding(.trailing, 36)
            }
            .overlay(alignment: .topTrailing) {
                if watch.isWatched { WatchedCheck(size: 26).padding(Theme.Space.s).transition(.scale.combined(with: .opacity)) }
            }
            .overlay(alignment: .center) {
                if canPlay, hovering || LibMetrics.isTouch {
                    Image(systemName: "play.fill")
                        .font(.system(size: LibMetrics.isTouch ? 18 : 24, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: LibMetrics.isTouch ? 48 : 62, height: LibMetrics.isTouch ? 48 : 62)
                        .background(Circle().fill(.white.opacity(LibMetrics.isTouch ? 0.9 : 1)))
                        .shadow(color: .black.opacity(0.4), radius: 12)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(item.titleName)
                        .font(.system(size: LibMetrics.isTouch ? 21 : 24, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let line = item.episodeLine {
                        Text(line).font(Theme.Font.headline).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    }
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.bottom, watch.isInProgress ? Theme.Space.l : Theme.Space.m)
                .shadow(color: .black.opacity(0.5), radius: 6)
            }
            .overlay(alignment: .bottom) {
                if watch.isInProgress {
                    WatchProgressBar(fraction: watch.fraction, height: 5)
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.bottom, Theme.Space.s)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
    }

    private var heroBadges: [LibBadgeRow.Item] {
        (item.bytesExpected > 0 ? [LibBadgeRow.Item(text: LibFormat.bytes(item.bytesExpected), systemImage: "internaldrive.fill")] : [])
            + LibReleaseTags.from(item.filename).map { LibBadgeRow.Item(text: $0) }
    }

    private func statusLine(_ watch: LibWatchState) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            Group {
                if watch.isWatched {
                    Label { Text("Watched") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Palette.success) }
                        .foregroundStyle(Theme.Palette.textPrimary)
                } else if let resumeAt = watch.resumeAt {
                    Label { Text("Resume at \(LibFormat.clock(resumeAt))") } icon: {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.Palette.progress)
                    }
                    .foregroundStyle(Theme.Palette.textPrimary)
                } else {
                    Label { Text("Downloaded") } icon: { Image(systemName: "checkmark.icloud.fill").foregroundStyle(Theme.Palette.success) }
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: Theme.Space.xs)
            Text(trailingStatus(watch))
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .font(Theme.Font.caption)
        .lineLimit(1)
        .monospacedDigit()
        .contentTransition(.numericText())
    }

    private func trailingStatus(_ watch: LibWatchState) -> String {
        if watch.isInProgress, let left = watch.remainingText { return left }
        return [LibFormat.runtime(watch.duration), item.addonName].compactMap { $0 }.joined(separator: " · ")
    }

    private func actions(_ watch: LibWatchState, request: PlaybackRequest?) -> some View {
        HStack(spacing: Theme.Space.xs) {
            if let request {
                LibPlayButton(title: primaryTitle(watch)) { play(request) }
                if watch.resumeAt != nil {
                    LibIconButton(title: "Play from Beginning", systemImage: "backward.end.fill") {
                        play(playbackRequest(watch, fromStart: true) ?? request)
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            } else {
                Label(libraryAvailable ? "File missing" : "Library unavailable",
                      systemImage: libraryAvailable ? "exclamationmark.triangle.fill" : "externaldrive.badge.xmark")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.warning)
            }
            if request == nil || !LibMetrics.expandsActions { Spacer(minLength: 0) }
            #if os(macOS)
            if let fileURL, fileExists {
                LibIconButton(title: "Show in Finder", systemImage: "folder") { LibFinder.show(fileURL) }
            }
            #endif
            NavigationLink(value: Route.saved(titleID: item.metaID)) {
                Image(systemName: "info")
            }
            .buttonStyle(LibIconButtonStyle())
            .disabled(library.title(id: item.metaID) == nil)
            .help("Go to Details")
            .accessibilityLabel("Go to Details")
            LibIconButton(title: "Remove from List", systemImage: "xmark", role: .destructive,
                          accessibilityTitle: "Remove \(item.titleName) from List") {
                withAnimation(LibMotion.spring) { downloads.remove(item.id) }
            }
        }
    }

    @ViewBuilder private func menu(_ watch: LibWatchState) -> some View {
        if let request = playbackRequest(watch) {
            Button(watch.resumeAt == nil ? primaryTitle(watch) : "Resume at \(LibFormat.clock(watch.resumeAt ?? 0))", systemImage: "play.fill") {
                play(request)
            }
            if watch.resumeAt != nil, let fromStart = playbackRequest(watch, fromStart: true) {
                Button("Play from Beginning", systemImage: "backward.end") { play(fromStart) }
            }
        }
        if library.title(id: item.metaID) != nil {
            NavigationLink(value: Route.saved(titleID: item.metaID)) { Label("Go to Details", systemImage: "info.circle") }
        }
        #if os(macOS)
        if let fileURL, fileExists {
            Button("Show in Finder", systemImage: "folder") { LibFinder.show(fileURL) }
        }
        #endif
        Divider()
        Button("Remove from List", systemImage: "xmark", role: .destructive) { downloads.remove(item.id) }
    }

    private func playbackRequest(_ watch: LibWatchState, fromStart: Bool = false) -> PlaybackRequest? {
        guard let url = fileURL, fileExists else { return nil }
        let title = library.title(id: item.metaID)
        return PlaybackRequest(
            url: url,
            title: item.titleName,
            subtitle: item.episodeLine,
            metaID: item.metaID,
            metaType: item.metaType,
            videoId: item.videoId,
            isLocal: true,
            filenameHint: item.filename,
            posterURL: title?.posterURL?.absoluteString,
            backgroundURL: title?.backdropURL?.absoluteString,
            startAt: fromStart ? 0 : (watch.resumeAt ?? 0)
        )
    }
}

// MARK: - Failed

private struct FailedDownloadCard: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(LibraryStore.self) private var library
    #if os(macOS)
    @Environment(\.openURL) private var openURL
    #endif
    let item: DownloadItem

    private var isOutOfSpace: Bool { item.failure == .outOfSpace }
    private var tint: Color { isOutOfSpace ? Theme.Palette.warning : Theme.Palette.progress }
    private var retryTitle: String { isOutOfSpace ? "Try Again" : "Retry" }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                poster(width: 72)
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    titles
                    details
                    buttons(compact: true, expands: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 520)
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    poster(width: 60)
                    titles.frame(maxWidth: .infinity, alignment: .leading)
                }
                details
                buttons(compact: false, expands: true)
            }
        }
        .padding(Theme.Space.m)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
                .fill(Theme.Palette.surface)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
                    .strokeBorder(tint.opacity(0.35)))
        }
        .libContextMenuShape(Theme.Radius.l)
        .contextMenu {
            Button(retryTitle, systemImage: "arrow.clockwise") { downloads.retry(item.id) }
            Button("Remove", systemImage: "trash", role: .destructive) { downloads.remove(item.id) }
        }
    }

    private func poster(width: CGFloat) -> some View {
        LibArtwork(folder: titleFolder(item, library: library), name: item.titleName, kind: .poster, maxPixelSize: 300)
            .frame(width: width, height: width * 1.5)
            .saturation(0.2)
            .overlay(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: isOutOfSpace ? "externaldrive.fill" : "exclamationmark")
                    .font(.system(size: isOutOfSpace ? 11 : 13, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(tint))
                    .overlay(Circle().strokeBorder(Theme.Palette.surface, lineWidth: 3))
                    .offset(x: 8, y: 8)
            }
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.titleName)
                .font(LibMetrics.isTouch ? .system(size: 17, weight: .bold) : Theme.Font.rowTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(2)
            Text([item.episodeLine, item.addonName].compactMap { $0 }.joined(separator: " · "))
                .font(Theme.Font.body).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
        }
    }

    @ViewBuilder private var details: some View {
        if isOutOfSpace {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Label("Not enough free space", systemImage: "externaldrive.badge.exclamationmark")
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.Palette.warning)
                if item.bytesWritten > 0, item.bytesExpected > 0 {
                    LibTransferBar(fraction: item.progress, paused: true)
                    Text("\(LibFormat.bytes(item.bytesWritten)) of \(LibFormat.bytes(item.bytesExpected)) kept")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .monospacedDigit()
                }
                errorBox
            }
        } else {
            errorBox
        }
    }

    private var errorBox: some View {
        Text(item.errorMessage ?? "The download stopped unexpectedly.")
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Palette.textPrimary.opacity(0.9))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(Theme.Space.s)
            .padding(.leading, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 3).padding(.vertical, 6)
            }
    }

    private func buttons(compact: Bool, expands: Bool) -> some View {
        HStack(spacing: Theme.Space.xs) {
            Button { withAnimation(LibMotion.spring) { downloads.retry(item.id) } } label: { Label(retryTitle, systemImage: "arrow.clockwise") }
                .buttonStyle(.ds(.primary, compact: compact, fullWidth: expands))
            #if os(macOS)
            if isOutOfSpace, let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") {
                Button { openURL(url) } label: { Label("Manage Storage", systemImage: "internaldrive") }
                    .buttonStyle(.ds(.secondary, compact: compact, fullWidth: expands))
            }
            #endif
            Button { withAnimation(LibMotion.spring) { downloads.remove(item.id) } } label: { Label("Remove", systemImage: "trash") }
                .buttonStyle(.ds(.secondary, compact: compact, fullWidth: expands))
        }
    }
}

// MARK: - Library sync

extension LibraryStore {
    /// Changes when saved files appear or disappear, but not on playback-progress updates.
    var fileFingerprint: [String] {
        [isAvailable ? "available" : "unavailable", root.path] + titles.flatMap { t in t.meta.items.map { "\(t.id)/\($0.file)" } }
    }
}

private struct PruneMissingDownloads: ViewModifier {
    @Environment(DownloadManager.self) private var downloads
    @Environment(LibraryStore.self) private var library
    var missing: Binding<Set<UUID>>?

    private struct Key: Equatable {
        var completed: [UUID]
        var library: [String]
        var loaded: Bool
    }

    func body(content: Content) -> some View {
        content.task(id: Key(completed: downloads.items.filter { $0.state == .completed }.map(\.id),
                             library: library.fileFingerprint, loaded: library.hasLoaded)) {
            guard library.hasLoaded else { return }
            let stillMissing = await downloads.pruneMissingFiles()
            missing?.wrappedValue = stillMissing
        }
    }
}

extension View {
    /// Keeps the Downloads list in step with the library: completed entries whose file was deleted
    /// (in Finder or elsewhere) are dropped; `missing` receives those that can't be checked right now.
    func pruningMissingDownloads(missing: Binding<Set<UUID>>? = nil) -> some View {
        modifier(PruneMissingDownloads(missing: missing))
    }
}
