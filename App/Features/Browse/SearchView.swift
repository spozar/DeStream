import SwiftUI

/// Search across all addons with a search catalog; results deduplicated by id and grouped by type. OWNER: UI Agent 2.
struct SearchView: View {
    @Environment(AddonRegistry.self) private var registry
    @State private var query: String
    /// Results per search catalog (index into the refs of `resultsQuery`'s search).
    @State private var results: [Int: [MetaPreview]] = [:]
    /// The query `results` belong to; differs from the field while a newer search is in flight.
    @State private var resultsQuery = ""
    @State private var errors: [String] = []
    @State private var pending = 0
    @State private var typeFilter: String?
    @State private var viewport: CGFloat = 0
    @FocusState private var fieldFocused: Bool
    @State private var didAutoFocus = false

    struct ResultGroup: Identifiable, Equatable {
        let type: String
        let items: [MetaPreview]
        var id: String { type }
    }

    init(initialQuery: String = "") {
        _query = State(initialValue: initialQuery)
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isStale: Bool { !results.isEmpty && resultsQuery != trimmed }

    /// Re-runs the search when the query or the set of search catalogs changes.
    private var searchKey: [String] { [trimmed] + registry.searchCatalogs.map { CatalogRef($0).id } }

    private var groups: [ResultGroup] {
        Self.group(results.keys.sorted().map { results[$0] ?? [] }, query: resultsQuery)
    }

    /// Merges per-catalog results (in catalog order), keeps the first occurrence of each id, groups Movies,
    /// Series, then other types; within a group exact title matches come first, then prefix matches.
    static func group(_ lists: [[MetaPreview]], query: String) -> [ResultGroup] {
        var order: [String] = []
        var byType: [String: [MetaPreview]] = [:]
        var seen = Set<String>()
        for list in lists {
            for item in list where seen.insert(item.id).inserted {
                if byType[item.type] == nil { order.append(item.type) }
                byType[item.type, default: []].append(item)
            }
        }
        let q = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        func tier(_ item: MetaPreview) -> Int {
            let name = item.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            if name == q { return 0 }
            return name.hasPrefix(q) ? 1 : 2
        }
        let rank = ["movie": 0, "series": 1]
        return order
            .sorted { (rank[$0] ?? 2, $0) < (rank[$1] ?? 2, $1) }
            .map { type in
                let items = (byType[type] ?? []).enumerated()
                    .sorted { (tier($0.element), $0.offset) < (tier($1.element), $1.offset) }
                    .map(\.element)
                return ResultGroup(type: type, items: items)
            }
    }

    var body: some View {
        let groups = groups
        let filter = groups.count > 1 && groups.contains { $0.type == typeFilter } ? typeFilter : nil
        let grid = BrowseLayout.grid(viewport: viewport)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    header
                    if groups.count > 1 { typeChips(groups, selected: filter) }
                }
                if !errors.isEmpty {
                    ErrorBanner(title: errors.count == 1 ? "An addon failed to search" : "Some addons failed to search",
                                messages: errors)
                        .padding(.horizontal, UIMetrics.pagePadding)
                }
                ForEach(groups.filter { filter == nil || $0.type == filter }) { group in
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        RowHeader(title: DisplayFormat.typeLabel(group.type),
                                  subtitle: group.items.count == 1 ? "1 result" : "\(group.items.count) results")
                        LazyVGrid(columns: grid.columns, alignment: .leading, spacing: Theme.Space.l) {
                            ForEach(group.items) { item in
                                NavigationLink(value: Route.detail(item)) {
                                    PosterCard(preview: item, width: grid.posterWidth, showsTitle: true)
                                }
                                .buttonStyle(.dsPressable)
                            }
                        }
                    }
                    .padding(.horizontal, UIMetrics.pagePadding)
                    .opacity(isStale ? 0.45 : 1)
                    .transition(.opacity.combined(with: .offset(y: 12)))
                }
                if pending > 0 && !trimmed.isEmpty {
                    if groups.isEmpty {
                        loadingGrid(grid)
                    } else if !isStale {
                        HStack(spacing: Theme.Space.xs) {
                            ProgressView().controlSize(.small)
                            Text("Searching more addons…")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                        .padding(.horizontal, UIMetrics.pagePadding)
                    }
                }
                emptyState
            }
            .padding(.top, Theme.Space.l)
            .padding(.bottom, Theme.Space.xxl)
            .animation(Theme.Motion.appear, value: isStale)
            .animation(Theme.Motion.content, value: filter)
        }
        .scrollIndicators(.never)
        .scrollDismissesKeyboard(.immediately)
        .contentShape(Rectangle())
        .onTapGesture { fieldFocused = false }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewport = $0 }
        .dsCanvas()
        .navigationTitle("Search")
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .task(id: searchKey) { await search(trimmed) }
        .onAppear {
            guard !didAutoFocus else { return }
            didAutoFocus = true
            if query.isEmpty { fieldFocused = true }
        }
        .onDisappear { fieldFocused = false }
        // Find (Cmd-F) or picking Search again while already here.
        .onReceive(NotificationCenter.default.publisher(for: .reselectSection)) { note in
            if note.object as? AppSection == .search { fieldFocused = true }
        }
    }

    private func typeChips(_ groups: [ResultGroup], selected: String?) -> some View {
        ChipScroller {
            chip("All", count: groups.reduce(0) { $0 + $1.items.count }, selected: selected == nil) { typeFilter = nil }
            ForEach(groups) { group in
                chip(DisplayFormat.typeLabel(group.type), count: group.items.count, selected: selected == group.type) {
                    typeFilter = group.type
                }
            }
        }
        .dsSelectionHaptic(selected)
    }

    private func chip(_ title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            FilterChip(title: "\(title)  \(count)", selected: selected)
        }
        .buttonStyle(.dsPressable)
        .accessibilityLabel("\(title), \(count) results")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Search")
                .font(Theme.Font.title)
                .foregroundStyle(Theme.Palette.textPrimary)
            HStack(spacing: Theme.Space.s) {
                searchField
                #if os(iOS)
                if fieldFocused {
                    Button("Cancel") { fieldFocused = false }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.Palette.accentHover)
                        .frame(minHeight: Self.fieldMinHeight)
                        .contentShape(Rectangle())
                        .buttonStyle(.plain)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                #endif
            }
            .animation(Theme.Motion.hover, value: fieldFocused)
        }
        .padding(.horizontal, UIMetrics.pagePadding)
    }

    private var searchField: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Self.fieldIconSize, weight: .semibold))
                .foregroundStyle(fieldFocused ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
            TextField("", text: $query, prompt: Text("Movies, series…").foregroundStyle(Theme.Palette.textTertiary))
                .textFieldStyle(.plain)
                .font(.system(size: Self.fieldFontSize, weight: .semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
                .focused($fieldFocused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
                .onSubmit { fieldFocused = false }
                #if os(macOS)
                .onExitCommand {
                    if query.isEmpty { fieldFocused = false } else { query = "" }
                }
                #endif
            if pending > 0 {
                ProgressView().controlSize(.small)
            }
            if !query.isEmpty {
                Button {
                    query = ""
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, Theme.Space.m + 2)
        .padding(.trailing, query.isEmpty ? Theme.Space.m + 2 : Theme.Space.xxs)
        .padding(.vertical, 4)
        .frame(minHeight: Self.fieldMinHeight)
        .frame(maxWidth: 760)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
                .strokeBorder(fieldFocused ? Theme.Palette.accent.opacity(0.8) : Theme.Palette.stroke, lineWidth: fieldFocused ? 2 : 1)
        }
        .shadow(color: fieldFocused ? Theme.Palette.accent.opacity(0.25) : .clear, radius: 14)
        .animation(Theme.Motion.appear, value: fieldFocused)
        .contentShape(Rectangle())
        .onTapGesture { fieldFocused = true }
    }

    #if os(iOS)
    private static let fieldFontSize: CGFloat = 17
    private static let fieldIconSize: CGFloat = 17
    private static let fieldMinHeight: CGFloat = 50
    #else
    private static let fieldFontSize: CGFloat = 22
    private static let fieldIconSize: CGFloat = 20
    private static let fieldMinHeight: CGFloat = 58
    #endif

    private func loadingGrid(_ grid: BrowseLayout.Grid) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SkeletonBlock(width: 120, height: 18, cornerRadius: 4)
            LazyVGrid(columns: grid.columns, alignment: .leading, spacing: Theme.Space.l) {
                ForEach(0..<12, id: \.self) { _ in PosterSkeleton(width: grid.posterWidth, showsTitle: true) }
            }
        }
        .padding(.horizontal, UIMetrics.pagePadding)
        .accessibilityLabel("Searching")
    }

    @ViewBuilder private var emptyState: some View {
        if registry.searchCatalogs.isEmpty {
            VStack(spacing: Theme.Space.s) {
                BrowsePlaceholder(systemImage: "magnifyingglass", title: "No Search Addons",
                                  message: "Add an addon with a searchable catalog, such as Cinemeta, to search movies and series.")
                ManageAddonsButton()
            }
            .padding(.top, Theme.Space.xxl)
        } else if trimmed.isEmpty {
            if registry.discoverCatalogs.contains(where: { $0.catalog.supportsGenre }) {
                GenreShortcuts(title: "Or Browse by Genre")
            } else {
                BrowsePlaceholder(systemImage: "film.stack", title: "Find something to watch",
                                  message: "Search movies and series across all your addons.")
                    .padding(.top, Theme.Space.xxl)
            }
        } else if results.isEmpty && resultsQuery == trimmed && pending == 0 && errors.isEmpty {
            BrowsePlaceholder(systemImage: "questionmark.circle", title: "No results",
                              message: "Nothing matched “\(trimmed)”. Check the spelling or try another title.")
                .padding(.top, Theme.Space.xxl)
        }
    }

    private func search(_ q: String) async {
        guard !q.isEmpty else {
            results = [:]; resultsQuery = ""; errors = []; pending = 0
            return
        }
        if q != resultsQuery {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
        }

        let refs = registry.searchCatalogs.map(CatalogRef.init)
        var fresh: [Int: [MetaPreview]] = [:]
        errors = []
        pending = refs.count
        await withTaskGroup(of: (Int, Result<[MetaPreview], any Error>).self) { group in
            for (i, ref) in refs.enumerated() {
                group.addTask {
                    do { return (i, .success(try await registry.catalog(ref.addon, ref.catalog, search: q))) }
                    catch { return (i, .failure(error)) }
                }
            }
            for await (i, result) in group {
                guard !Task.isCancelled else { return }
                pending -= 1
                switch result {
                case .success(let items) where !items.isEmpty:
                    fresh[i] = items
                    // The previous query's results stay (dimmed) until the first new ones arrive.
                    withAnimation(Theme.Motion.appear) {
                        results = fresh
                        resultsQuery = q
                    }
                case .success:
                    break
                case .failure(let error):
                    if (error as? URLError)?.code == .cancelled || error is CancellationError { continue }
                    let name = refs[i].addon.manifest.name
                    let description = error.localizedDescription
                    // Addon errors usually name the addon already.
                    let message = description.contains(name) ? description : "\(name): \(description)"
                    if !errors.contains(message) { errors.append(message) }
                }
            }
        }
        guard !Task.isCancelled else { return }
        if fresh.isEmpty {
            withAnimation(Theme.Motion.appear) {
                results = [:]
                resultsQuery = q
            }
        }
    }
}
