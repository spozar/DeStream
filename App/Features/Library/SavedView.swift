import SwiftUI

/// Grid of saved titles with local posters; works fully offline. OWNER: UI Agent 5.
struct SavedView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ProgressStore.self) private var progress
    @Environment(AppServices.self) private var services
    @Environment(NetworkMonitor.self) private var network
    @Environment(DownloadManager.self) private var downloads
    @State private var pendingDelete: SavedTitle?
    @State private var errorMessage: String?

    #if os(macOS)
    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: Theme.Space.l, alignment: .top)]
    #else
    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 180), spacing: Theme.Space.s, alignment: .top)]
    #endif

    var body: some View {
        content
            .animation(LibMotion.spring, value: phase)
            .dsCanvas()
            .dsPageTitle("Saved")
            .refreshable { await library.reload() }
            .pruningMissingDownloads()
            .confirmationDialog(
                "Delete \(pendingDelete?.meta.name ?? "")?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { title in
                Button(LibraryDeletion.verb, role: .destructive) {
                    Task {
                        do { try await LibraryDeletion.delete(title: title, library: library, downloads: downloads) }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
            } message: { title in
                Text(LibraryDeletion.titleMessage(title, downloads: downloads))
            }
            .alert("Couldn't delete", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    @ViewBuilder private var content: some View {
        if !library.isAvailable {
            LibraryEmptyState(
                symbol: "externaldrive.badge.xmark",
                satellites: ["externaldrive", "folder", "bolt.horizontal"],
                title: "Library unavailable",
                message: "The library folder at \(library.root.path) can't be reached. Connect the drive it's on, or choose another folder in Settings.",
                tint: Theme.Palette.warning
            ) {
                Button { Task { await library.reload() } } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                    .buttonStyle(.ds(.primary))
            }
            .transition(.opacity)
        } else if library.titles.isEmpty {
            LibraryEmptyState(
                symbol: "square.stack.fill",
                satellites: ["film", "tv", "arrow.down.circle"],
                title: "Nothing saved yet",
                message: "Movies and episodes you download appear here with their artwork and details, and play without an internet connection."
            ) {
                if network.isOnline {
                    Button { services.selection = .home } label: { Label("Browse Titles", systemImage: "sparkles") }
                        .buttonStyle(.ds(.primary))
                }
                Button { services.selection = .downloads } label: { Label("View Downloads", systemImage: "arrow.down.circle") }
                    .buttonStyle(.ds(.secondary))
            }
            .transition(.opacity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    LibPageHeader(title: "Saved", subtitle: summary) {
                        if activeDownloads > 0 {
                            Button { services.selection = .downloads } label: {
                                Label("\(activeDownloads) in progress", systemImage: "arrow.down.circle")
                                    .contentTransition(.numericText(value: Double(activeDownloads)))
                            }
                            .buttonStyle(.ds(.ghost, compact: true))
                            .help("Show downloads in progress")
                            .accessibilityLabel("\(activeDownloads) \(activeDownloads == 1 ? "download" : "downloads") in progress")
                        }
                        #if os(macOS)
                        Button { LibFinder.show(library.root) } label: { Label("Show in Finder", systemImage: "folder") }
                            .buttonStyle(.ds(.ghost, compact: true))
                        #endif
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Self.rowSpacing) {
                        ForEach(library.titles) { title in
                            NavigationLink(value: Route.saved(titleID: title.id)) {
                                SavedPosterCell(title: title)
                            }
                            .buttonStyle(.dsPressable)
                            .libContextMenuShape(Theme.Radius.m)
                            .contextMenu { contextMenu(for: title) }
                            .transition(LibMotion.card)
                        }
                    }
                    .animation(LibMotion.spring, value: library.titles.map(\.id))
                }
                .padding(.horizontal, Theme.Space.page)
                .padding(.top, Theme.Space.l)
                .padding(.bottom, Theme.Space.xxl)
            }
            .transition(.opacity)
        }
    }

    private enum Phase { case unavailable, empty, grid }
    private var phase: Phase { !library.isAvailable ? .unavailable : (library.titles.isEmpty ? .empty : .grid) }

    #if os(macOS)
    private static let rowSpacing: CGFloat = Theme.Space.xl
    #else
    private static let rowSpacing: CGFloat = Theme.Space.l
    #endif

    private var activeDownloads: Int {
        downloads.items.filter { [.queued, .downloading, .waiting, .paused].contains($0.state) }.count
    }

    private var summary: String {
        let n = library.titles.count
        let bytes = library.titles.reduce(Int64(0)) { $0 + $1.totalBytes }
        return ["\(n) \(n == 1 ? "title" : "titles")", bytes > 0 ? "\(LibFormat.bytes(bytes)) on disk" : nil, "Available offline"]
            .compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private func contextMenu(for title: SavedTitle) -> some View {
        NavigationLink(value: Route.saved(titleID: title.id)) { Label("Go to Details", systemImage: "info.circle") }
        #if os(macOS)
        Button("Show in Finder", systemImage: "folder") { LibFinder.show(title.folder) }
        #endif
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { pendingDelete = title }
    }
}

enum LibraryDeletion {
    static let verb = "Delete Permanently"
    static let phrase = "permanently deleted. This can't be undone"

    @MainActor static func titleMessage(_ title: SavedTitle, downloads: DownloadManager) -> String {
        var text = "All saved files for \(title.meta.name) (\(LibFormat.bytes(title.totalBytes))) will be \(phrase)."
        let n = downloads.inProgressCount(forTitle: title.id)
        if n > 0 { text += "\n\n\(n == 1 ? "1 download" : "\(n) downloads") in progress for this title will be cancelled." }
        return text
    }

    /// Cancels the title's unfinished downloads first so nothing writes into the folder while it's removed.
    @MainActor static func delete(title: SavedTitle, library: LibraryStore, downloads: DownloadManager) async throws {
        await downloads.cancelDownloads(forTitle: title.id)
        try await library.delete(title: title)
        downloads.forgetCompleted(metaID: title.id)
    }

    @MainActor static func itemMessage(_ item: SidecarMeta.SidecarItem, in title: SavedTitle, downloads: DownloadManager) -> String {
        let size = item.sizeBytes.map { " (\(LibFormat.bytes($0)))" } ?? ""
        var text = "The file\(size) will be \(phrase)."
        let n = title.meta.items.count == 1 ? downloads.inProgressCount(forTitle: title.id) : 0
        if n > 0 { text += "\n\n\(n == 1 ? "1 download" : "\(n) downloads") in progress for this title will be cancelled." }
        return text
    }

    /// Deleting the last item removes the title folder, so unfinished downloads are cancelled first (as for a whole title).
    @MainActor static func delete(_ item: SidecarMeta.SidecarItem, in title: SavedTitle,
                                  library: LibraryStore, downloads: DownloadManager) async throws {
        if title.meta.items.count == 1 { await downloads.cancelDownloads(forTitle: title.id) }
        try await library.delete(item, in: title)
        downloads.forgetCompleted(metaID: title.id, videoId: item.videoId)
    }
}

extension SavedTitle {
    var totalBytes: Int64 { meta.items.reduce(0) { $0 + ($1.sizeBytes ?? 0) } }

    /// "3 episodes · 12.3 GB", "Movie · 8.5 GB".
    var captionText: String {
        let size = totalBytes > 0 ? LibFormat.bytes(totalBytes) : nil
        return [itemsSubtitle, size].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Watch states for every saved item, plus the item to offer as "Resume"/"Play next".
struct SavedTitleProgress {
    var states: [String: LibWatchState]
    var nextUp: SidecarMeta.SidecarItem?

    var allWatched: Bool { !states.isEmpty && states.values.allSatisfy(\.isWatched) }
    func state(_ item: SidecarMeta.SidecarItem) -> LibWatchState { states[item.videoId] ?? LibWatchState() }

    @MainActor
    init(title: SavedTitle, progress: ProgressStore) {
        let items = title.meta.sortedItems
        var states: [String: LibWatchState] = [:]
        for item in items { states[item.videoId] = LibWatchState.resolve(videoId: item.videoId, sidecar: item, progress: progress) }
        self.states = states
        let inProgress = items.filter { states[$0.videoId]?.isInProgress == true }
            .max { (progress.entry(for: $0.videoId)?.updatedAt ?? .distantPast) < (progress.entry(for: $1.videoId)?.updatedAt ?? .distantPast) }
        nextUp = inProgress ?? items.first { states[$0.videoId]?.isWatched != true } ?? items.first
    }
}

private struct SavedPosterCell: View {
    @Environment(ProgressStore.self) private var progress
    let title: SavedTitle
    @State private var hovering = false

    var body: some View {
        let state = SavedTitleProgress(title: title, progress: progress)
        let current = state.nextUp.map(state.state)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay { LibArtwork(folder: title.folder, name: title.meta.name, kind: .poster, maxPixelSize: 600) }
                .clipped()
                .overlay(alignment: .bottom) {
                    if let current, current.isInProgress {
                        LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 44)
                            .overlay(alignment: .bottom) {
                                WatchProgressBar(fraction: current.fraction, height: 4)
                                    .padding(.horizontal, Theme.Space.s)
                                    .padding(.bottom, Theme.Space.s)
                            }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if state.allWatched { WatchedCheck(size: 24).padding(Theme.Space.xs) }
                }
                .overlay(alignment: .topLeading) {
                    if title.meta.isSeries, title.meta.items.count > 1 {
                        Badge(text: "\(title.meta.items.count) EP").padding(Theme.Space.xs)
                    }
                }
                .overlay {
                    if hovering {
                        ZStack {
                            Color.black.opacity(0.25)
                            Image(systemName: "chevron.right.circle.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(.white, .white.opacity(0.25))
                        }
                        .transition(.opacity)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                    .strokeBorder(hovering ? Color.white.opacity(0.35) : Theme.Palette.stroke, lineWidth: hovering ? 1.5 : 1))
                .scaleEffect(hovering ? 1.04 : 1)
                .shadow(color: .black.opacity(hovering ? 0.5 : 0.25), radius: hovering ? 18 : 6, y: hovering ? 10 : 3)

            VStack(alignment: .leading, spacing: 3) {
                Text(title.meta.name)
                    .font(LibMetrics.isTouch ? .system(size: 14, weight: .semibold) : Theme.Font.headline)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Text(title.captionText)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                if let current, current.isInProgress, let left = current.remainingText {
                    Text([state.nextUp?.episodeCode, left].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.progress)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .animation(Theme.Motion.hover, value: hovering)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }
}
