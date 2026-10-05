import SwiftUI

extension AddonRegistry {
    /// Catalogs browsable in Discover (no required extras other than a pickable genre), in addon order.
    var discoverCatalogs: [CatalogRef] {
        var seen = Set<String>()
        return enabledAddons.flatMap { addon in
            addon.manifest.catalogs.filter(\.isDiscoverable).map { CatalogRef((addon: addon, catalog: $0)) }
        }
        .filter { seen.insert($0.selectionKey).inserted }
    }
}

extension CatalogRef {
    /// Movies, then series, then any other type in first-seen order.
    static func rankedTypes(_ refs: [CatalogRef]) -> [String] {
        var seen = Set<String>()
        let types = refs.map(\.catalog.type).filter { seen.insert($0).inserted }
        let rank = ["movie": 0, "series": 1]
        return types.enumerated()
            .sorted { (rank[$0.element] ?? 2, $0.offset) < (rank[$1.element] ?? 2, $1.offset) }
            .map(\.element)
    }
}

/// Stremio-style Discover: pick a type, a catalog (from every installed addon) and a genre; shows a paged poster grid.
struct DiscoverView: View {
    @Environment(AddonRegistry.self) private var registry
    @State private var type: String?
    @State private var catalogKey: String?
    @State private var genre: String?
    @State private var model: CatalogRowModel?
    @State private var showsAllGenres = false
    @State private var viewport: CGFloat = 0
    /// Root of a section (no back button above it) rather than pushed.
    private let isRoot: Bool

    init(seed: DiscoverSeed = DiscoverSeed(), isRoot: Bool = false) {
        _type = State(initialValue: seed.type)
        _catalogKey = State(initialValue: seed.catalogKey)
        _genre = State(initialValue: seed.genre)
        self.isRoot = isRoot
    }

    private var refs: [CatalogRef] { registry.discoverCatalogs }
    private var types: [String] { CatalogRef.rankedTypes(refs) }

    private var resolvedType: String? {
        if let type, types.contains(type) { return type }
        return types.first
    }

    private var typeRefs: [CatalogRef] { refs.filter { $0.catalog.type == resolvedType } }

    private var selectedRef: CatalogRef? {
        typeRefs.first { $0.selectionKey == catalogKey } ?? typeRefs.first
    }

    /// The chosen genre if the catalog offers it; catalogs that require a genre fall back to their first option.
    private var resolvedGenre: String? {
        guard let catalog = selectedRef?.catalog else { return nil }
        let options = catalog.genreOptions
        if let genre, options.contains(genre) { return genre }
        return catalog.requiresGenre ? options.first : nil
    }

    private var contentKey: String? { selectedRef.map { "\($0.id)|\(resolvedGenre ?? "")" } }

    /// Catalog chips name the addon only when several addons offer catalogs of this type.
    private var showsAddonNames: Bool { Set(typeRefs.map(\.addon.id)).count > 1 }

    var body: some View {
        let grid = BrowseLayout.grid(viewport: viewport)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    header.id(Self.topID)
                    if refs.isEmpty {
                        VStack(spacing: Theme.Space.s) {
                            BrowsePlaceholder(systemImage: "square.grid.2x2", title: "Nothing to Browse",
                                              message: "Add a catalog addon such as Cinemeta to browse movies and series by genre.")
                            ManageAddonsButton()
                        }
                        .padding(.top, Theme.Space.xl)
                    } else {
                        filters
                        if let model {
                            DiscoverGrid(model: model, grid: grid)
                                .id(model.id)
                                .transition(.opacity)
                        }
                    }
                }
                .padding(.top, topPadding)
                .padding(.bottom, Theme.Space.xxl)
                .animation(Theme.Motion.appear, value: model?.id)
            }
            .scrollIndicators(.never)
            .onChange(of: contentKey) {
                withAnimation(Theme.Motion.content) { proxy.scrollTo(Self.topID, anchor: .top) }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewport = $0 }
        .dsCanvas()
        .navigationTitle("Browse")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isRoot ? .hidden : .automatic, for: .navigationBar)
        #endif
        .onChange(of: contentKey, initial: true) {
            model = selectedRef.map { CatalogRowModel(ref: $0, genre: resolvedGenre) }
        }
        .onChange(of: selectedRef?.selectionKey) { showsAllGenres = false }
        .task(id: model?.id) { await model?.loadIfNeeded(registry) }
        .refreshable { await model?.reload(registry) }
        .dsSelectionHaptic(contentKey)
    }

    private static let topID = "discover-top"

    private var topPadding: CGFloat {
        #if os(macOS)
        // Clears the shell's floating back button on pushed pages.
        isRoot ? Theme.Space.l : 64
        #else
        Theme.Space.s
        #endif
    }

    @ViewBuilder private var header: some View {
        #if os(iOS)
        if isRoot { title }
        #else
        title
        #endif
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text("Browse")
                .font(Theme.Font.title)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("Every catalog from your addons, by type and genre.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .padding(.horizontal, UIMetrics.pagePadding)
    }

    // MARK: Filters

    private var filters: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ChipScroller {
                if types.count > 1 {
                    ForEach(types, id: \.self) { t in
                        chipButton(DisplayFormat.typeLabel(t), systemImage: t == "series" ? "tv" : t == "movie" ? "film" : nil,
                                   selected: t == resolvedType) { type = t }
                    }
                    Rectangle().fill(Theme.Palette.strokeStrong).frame(width: 1, height: 20)
                        .padding(.horizontal, Theme.Space.xxs)
                }
                ForEach(typeRefs) { ref in
                    chipButton(showsAddonNames ? "\(ref.catalog.displayName) · \(ref.addon.manifest.name)" : ref.catalog.displayName,
                               selected: ref.selectionKey == selectedRef?.selectionKey) { catalogKey = ref.selectionKey }
                }
            }
            genreChips
        }
    }

    @ViewBuilder private var genreChips: some View {
        if let catalog = selectedRef?.catalog, catalog.supportsGenre, !catalog.genreOptions.isEmpty {
            let options = catalog.genreOptions
            #if os(macOS)
            let limit = 24
            let visible = showsAllGenres || options.count <= limit ? options : Array(options.prefix(limit - 1))
            FlowLayout(spacing: Theme.Space.xs, lineSpacing: Theme.Space.xs) {
                if !catalog.requiresGenre {
                    chipButton("All", selected: resolvedGenre == nil) { genre = nil }
                }
                ForEach(visible, id: \.self) { g in
                    chipButton(g, selected: g == resolvedGenre) { genre = g }
                }
                if visible.count < options.count {
                    chipButton("\(options.count - visible.count) More", systemImage: "chevron.down", selected: false) {
                        withAnimation(Theme.Motion.content) { showsAllGenres = true }
                    }
                }
            }
            .padding(.horizontal, UIMetrics.pagePadding)
            #else
            ChipScroller {
                if !catalog.requiresGenre {
                    chipButton("All", selected: resolvedGenre == nil) { genre = nil }
                }
                ForEach(options, id: \.self) { g in
                    chipButton(g, selected: g == resolvedGenre) { genre = g }
                }
            }
            #endif
        }
    }

    private func chipButton(_ title: String, systemImage: String? = nil, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            FilterChip(title: title, systemImage: systemImage, selected: selected)
        }
        .buttonStyle(.dsPressable)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Paged poster grid for one catalog/genre selection.
private struct DiscoverGrid: View {
    let model: CatalogRowModel
    let grid: BrowseLayout.Grid
    @Environment(AddonRegistry.self) private var registry

    /// Starts loading the next page a little before the last poster scrolls in.
    private var prefetchID: String? {
        model.items.isEmpty ? nil : model.items[max(0, model.items.count - 8)].id
    }

    var body: some View {
        if model.items.isEmpty {
            if let error = model.error {
                ErrorBanner(title: "Couldn't load this catalog", messages: [error]) {
                    Task { await model.reload(registry) }
                }
                .padding(.horizontal, UIMetrics.pagePadding)
            } else if model.isLoading || !model.didLoad {
                skeleton
            } else {
                BrowsePlaceholder(systemImage: "film.stack", title: "Nothing Here",
                                  message: "This catalog has no titles for the selected genre.")
                    .padding(.top, Theme.Space.l)
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                LazyVGrid(columns: grid.columns, alignment: .leading, spacing: Theme.Space.l) {
                    ForEach(model.items) { item in
                        NavigationLink(value: Route.detail(item)) {
                            PosterCard(preview: item, width: grid.posterWidth, showsTitle: true)
                        }
                        .buttonStyle(.dsPressable)
                        .onAppear {
                            if item.id == prefetchID { Task { await model.loadMore(registry) } }
                        }
                    }
                }
                footer
            }
            .padding(.horizontal, UIMetrics.pagePadding)
        }
    }

    @ViewBuilder private var footer: some View {
        if model.isLoading {
            HStack(spacing: Theme.Space.xs) {
                ProgressView().controlSize(.small)
                Text("Loading more…")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .frame(maxWidth: .infinity)
        } else if model.error != nil {
            Button {
                Task { await model.loadMore(registry) }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.ds(.secondary, compact: true))
            .frame(maxWidth: .infinity)
        }
    }

    private var skeleton: some View {
        LazyVGrid(columns: grid.columns, alignment: .leading, spacing: Theme.Space.l) {
            ForEach(0..<18, id: \.self) { _ in PosterSkeleton(width: grid.posterWidth, showsTitle: true) }
        }
        .padding(.horizontal, UIMetrics.pagePadding)
        .accessibilityLabel("Loading")
    }
}

// MARK: - Genre shortcuts (Home, Search)

/// "Browse by Genre" chips for the best genre catalog of each type; each chip opens Discover pre-filtered.
struct GenreShortcuts: View {
    var title = "Browse by Genre"
    @Environment(AddonRegistry.self) private var registry
    @State private var type: String?

    /// Per type, the first catalog with genre options that also works without one (a general "Popular"-style list).
    private var sources: [CatalogRef] {
        let candidates = registry.discoverCatalogs.filter { !$0.catalog.requiresGenre && !$0.catalog.genreOptions.isEmpty }
        return CatalogRef.rankedTypes(candidates).compactMap { t in candidates.first { $0.catalog.type == t } }
    }

    var body: some View {
        let sources = sources
        if let source = sources.first(where: { $0.catalog.type == type }) ?? sources.first {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .center, spacing: Theme.Space.s) {
                    Text(title)
                        .font(Theme.Font.rowTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if sources.count > 1 {
                        HStack(spacing: Theme.Space.xxs) {
                            ForEach(sources) { ref in
                                let t = ref.catalog.type
                                Button { type = t } label: {
                                    FilterChip(title: DisplayFormat.typeLabel(t), selected: t == source.catalog.type, compact: true)
                                }
                                .buttonStyle(.dsPressable)
                                .accessibilityAddTraits(t == source.catalog.type ? [.isSelected] : [])
                            }
                        }
                    }
                    NavigationLink(value: Route.discover(DiscoverSeed(type: source.catalog.type))) {
                        HStack(spacing: 2) {
                            Text("See All")
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                        }
                        .font(Theme.Font.caption.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accentHover)
                        .frame(minHeight: max(30, Theme.Control.minHitTarget))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, UIMetrics.pagePadding)
                ChipScroller {
                    ForEach(source.catalog.genreOptions, id: \.self) { g in
                        NavigationLink(value: Route.discover(DiscoverSeed(type: source.catalog.type,
                                                                          catalogKey: source.selectionKey, genre: g))) {
                            FilterChip(title: g)
                        }
                        .buttonStyle(.dsPressable)
                    }
                }
            }
            .dsSelectionHaptic(type)
        }
    }
}

// MARK: - Addons shortcut

/// Empty-state action that opens addon management: the Addons section on macOS; on iOS (where Addons lives
/// inside Settings) it's pushed onto the current stack.
struct ManageAddonsButton: View {
    #if os(macOS)
    @Environment(AppServices.self) private var services: AppServices?
    #endif

    var body: some View {
        #if os(macOS)
        Button { services?.selection = .addons } label: { label }
            .buttonStyle(.dsAccent)
        #else
        NavigationLink(value: Route.section(.addons)) { label }
            .buttonStyle(.dsAccent)
        #endif
    }

    private var label: some View { Label("Manage Addons", systemImage: "puzzlepiece.extension") }
}

// MARK: - Chips

/// Capsule filter chip: accent gradient when selected, translucent otherwise.
struct FilterChip: View {
    let title: String
    var systemImage: String? = nil
    var selected = false
    var compact = false
    @State private var hovering = false

    #if os(macOS)
    private var height: CGFloat { compact ? 24 : 30 }
    private var fontSize: CGFloat { compact ? 11.5 : 13 }
    #else
    private var height: CGFloat { compact ? 30 : 36 }
    private var fontSize: CGFloat { compact ? 13 : 14 }
    #endif

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: fontSize - 1, weight: .bold))
            }
            Text(title).lineLimit(1)
        }
        .font(.system(size: fontSize, weight: .semibold))
        .foregroundStyle(selected ? Color.white : hovering ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
        .padding(.horizontal, compact ? 10 : 14)
        .frame(height: height)
        .background {
            if selected {
                Capsule().fill(Theme.Palette.accentGradient)
            } else {
                Capsule().fill(Color.white.opacity(hovering ? 0.12 : 0.07))
            }
        }
        .overlay(Capsule().strokeBorder(selected ? Color.clear : Theme.Palette.stroke))
        .contentShape(Capsule())
        .onHover { h in withAnimation(Theme.Motion.fast) { hovering = h } }
        .animation(Theme.Motion.hover, value: selected)
    }
}

/// Horizontally scrolling chip row aligned to the page margins.
struct ChipScroller<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Space.xs) { content }
                .padding(.vertical, 2)
        }
        .contentMargins(.horizontal, UIMetrics.pagePadding, for: .scrollContent)
        .scrollIndicators(.never)
    }
}
