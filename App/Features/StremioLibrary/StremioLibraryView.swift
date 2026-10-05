import SwiftUI

/// The signed-in Stremio account's library (bookmarked titles) as a filterable poster grid.
struct StremioLibraryView: View {
    @Environment(LibrarySync.self) private var librarySync
    @Environment(SyncCoordinator.self) private var sync
    @AppStorage("stremioLibrary.type") private var typeFilter = ""
    @AppStorage("stremioLibrary.sort") private var sortRaw = LibrarySort.recentlyWatched.rawValue
    @State private var viewport: CGFloat = 0

    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .recentlyWatched }

    /// Movies, then series, then any other type present in the library.
    private var types: [String] {
        var seen = Set<String>()
        let present = librarySync.libraryItems.map(\.type).filter { seen.insert($0).inserted }
        let rank = ["movie": 0, "series": 1]
        return present.sorted { (rank[$0] ?? 2, $0) < (rank[$1] ?? 2, $1) }
    }

    private var resolvedType: String? { types.contains(typeFilter) ? typeFilter : nil }

    private var visibleItems: [StremioLibraryItem] {
        let filtered = librarySync.libraryItems.filter { resolvedType == nil || $0.type == resolvedType }
        return sort.apply(filtered)
    }

    var body: some View {
        let grid = BrowseLayout.grid(viewport: viewport)
        let items = visibleItems
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                header
                if let error = sync.lastError, !neverLoaded {
                    ErrorBanner(title: "Couldn't sync your library", messages: [error], retry: retry)
                        .padding(.horizontal, UIMetrics.pagePadding)
                        .transition(.opacity)
                }
                if librarySync.libraryItems.isEmpty {
                    emptyState.padding(.top, Theme.Space.xl)
                } else {
                    if types.count > 1 { typeChips }
                    LazyVGrid(columns: grid.columns, alignment: .leading, spacing: Theme.Space.l) {
                        ForEach(items) { item in
                            NavigationLink(value: Route.detail(item.preview)) {
                                PosterCard(preview: item.preview, width: grid.posterWidth, showsTitle: true)
                            }
                            .buttonStyle(.dsPressable)
                            .contextMenu {
                                Button("Remove from Library", systemImage: "bookmark.slash", role: .destructive) {
                                    withAnimation(Theme.Motion.content) { librarySync.removeFromLibrary(id: item.id) }
                                    sync.scheduleSync()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, UIMetrics.pagePadding)
                    .animation(Theme.Motion.content, value: items.map(\.id))
                }
            }
            .padding(.top, topPadding)
            .padding(.bottom, Theme.Space.xxl)
        }
        .scrollIndicators(.never)
        .animation(Theme.Motion.content, value: sync.lastError)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewport = $0 }
        .dsCanvas()
        .dsPageTitle("Library")
        .refreshable { await sync.syncNow() }
        .dsSelectionHaptic(typeFilter + sortRaw)
    }

    private var topPadding: CGFloat {
        #if os(macOS)
        Theme.Space.l
        #else
        Theme.Space.s
        #endif
    }

    /// Nothing has ever arrived from the account, so an empty list means "not loaded", not "empty".
    private var neverLoaded: Bool { librarySync.libraryItems.isEmpty && sync.lastSyncedAt == nil }

    private func retry() { Task { await sync.syncNow() } }

    private var subtitle: String {
        let n = librarySync.libraryItems.count
        let base = "Titles saved to your Stremio account"
        return n == 0 ? base : "\(base) · \(n) \(n == 1 ? "title" : "titles")"
    }

    private var header: some View {
        SectionTitle(title: "Library", subtitle: subtitle) {
            if !librarySync.libraryItems.isEmpty { sortMenu }
        }
        .padding(.horizontal, UIMetrics.pagePadding)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sortRaw) {
                ForEach(LibrarySort.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
        } label: {
            FilterChip(title: sort.title, systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort library")
        .accessibilityLabel("Sort by \(sort.title)")
    }

    private var typeChips: some View {
        ChipScroller {
            chip("All", systemImage: nil, selected: resolvedType == nil) { typeFilter = "" }
            ForEach(types, id: \.self) { t in
                chip(DisplayFormat.typeLabel(t), systemImage: t == "series" ? "tv" : t == "movie" ? "film" : nil,
                     selected: t == resolvedType) { typeFilter = t }
            }
        }
    }

    private func chip(_ title: String, systemImage: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            FilterChip(title: title, systemImage: systemImage, selected: selected)
        }
        .buttonStyle(.dsPressable)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    @ViewBuilder private var emptyState: some View {
        if sync.isSyncing && sync.lastSyncedAt == nil {
            ProgressView().controlSize(.large).frame(maxWidth: .infinity).padding(.top, Theme.Space.xl)
        } else if neverLoaded, let error = sync.lastError {
            VStack(spacing: Theme.Space.s) {
                BrowsePlaceholder(systemImage: "exclamationmark.icloud", title: "Couldn't Load Your Library", message: error)
                Button(action: retry) { Label("Try Again", systemImage: "arrow.clockwise") }
                    .buttonStyle(.ds(.primary))
            }
            .frame(maxWidth: .infinity)
        } else {
            BrowsePlaceholder(systemImage: "books.vertical", title: "Your Library Is Empty",
                              message: "Add movies and series with the bookmark button on a title's page. They sync with your Stremio account.")
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case recentlyWatched, recentlyAdded, name
    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyWatched: "Recently Watched"
        case .recentlyAdded: "Recently Added"
        case .name: "A–Z"
        }
    }

    func apply(_ items: [StremioLibraryItem]) -> [StremioLibraryItem] {
        switch self {
        case .recentlyWatched:
            items.sorted {
                ($0.state.lastWatched ?? .distantPast, $0.mtime) > ($1.state.lastWatched ?? .distantPast, $1.mtime)
            }
        case .recentlyAdded:
            items.sorted { ($0.ctime ?? $0.mtime) > ($1.ctime ?? $1.mtime) }
        case .name:
            items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
}

extension StremioLibraryItem {
    var preview: MetaPreview {
        MetaPreview(id: id, type: type, name: name, poster: poster, posterShape: posterShape)
    }
}
