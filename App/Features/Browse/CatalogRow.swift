import SwiftUI
import Observation

/// An (addon, catalog) pair with a stable identity for ForEach.
struct CatalogRef: Identifiable, Hashable, Sendable {
    let addon: Addon
    let catalog: ManifestCatalog

    init(_ pair: (addon: Addon, catalog: ManifestCatalog)) {
        addon = pair.addon
        catalog = pair.catalog
    }

    /// Includes a hash of the manifest URL so a reconfigured addon reloads its rows.
    var id: String { "\(addon.id)|\(addon.manifestURL.hashValue)|\(catalog.stableID)" }

    /// Identifies the catalog across manifest refreshes (for persisted / pushed selections).
    var selectionKey: String { "\(addon.id)|\(catalog.stableID)" }

    var title: String {
        "\(catalog.displayName) — \(DisplayFormat.typeLabel(catalog.type))"
    }

    var homeRowID: HomeRowID { HomeRowID(addon: addon, catalog: catalog) }
}

/// Context-menu actions on a Home row's title.
struct HomeRowActions {
    var hide: () -> Void
    var moveUp: (() -> Void)?
    var moveDown: (() -> Void)?
    var customize: () -> Void
}

/// Paged contents of one catalog (optionally filtered by genre). Pages via `skip` = number of items the addon
/// has returned so far.
@MainActor @Observable
final class CatalogRowModel: Identifiable {
    let ref: CatalogRef
    let genre: String?
    private(set) var items: [MetaPreview] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var reachedEnd = false
    private(set) var didLoad = false

    @ObservationIgnored private var rawCount = 0
    @ObservationIgnored private var seen = Set<String>()

    nonisolated var id: String { genre.map { "\(ref.id)|genre=\($0)" } ?? ref.id }

    init(ref: CatalogRef, genre: String? = nil) {
        self.ref = ref
        self.genre = genre
    }

    @ObservationIgnored private var initialLoad: Task<Void, Never>?

    /// The first load runs in its own task so a view's `.task` being cancelled (rows scrolling or
    /// re-identifying) can't abandon it half-way; every caller awaits the same load.
    func loadIfNeeded(_ registry: AddonRegistry) async {
        if let initialLoad { return await initialLoad.value }
        guard !didLoad else { return }
        let task = Task { await self.reload(registry) }
        initialLoad = task
        await task.value
    }

    /// Bumped by `reload` so a page request that was in flight can't append to the fresh list.
    @ObservationIgnored private var generation = 0

    /// Refetches the first page. Current items stay on screen until it arrives (no skeleton flash on
    /// pull-to-refresh); a failed refresh keeps them.
    func reload(_ registry: AddonRegistry) async {
        generation += 1
        didLoad = true
        if items.isEmpty { error = nil }
        await fetch(registry, replacing: true)
    }

    func loadMore(_ registry: AddonRegistry) async {
        guard !isLoading, !reachedEnd else { return }
        await fetch(registry, replacing: false)
    }

    private func fetch(_ registry: AddonRegistry, replacing: Bool) async {
        let gen = generation
        isLoading = true
        defer { if gen == generation { isLoading = false } }
        do {
            let skip = replacing || rawCount == 0 ? nil : rawCount
            let page = try await registry.catalog(ref.addon, ref.catalog, skip: skip, genre: genre)
            guard gen == generation else { return }
            if replacing {
                items = []
                seen = []
                rawCount = 0
            }
            rawCount += page.count
            let fresh = page.filter { seen.insert($0.id).inserted }
            items += fresh
            error = nil
            reachedEnd = fresh.isEmpty || !ref.catalog.supportsSkip
        } catch {
            guard gen == generation else { return }
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError {
                if items.isEmpty { didLoad = false; initialLoad = nil }
                return
            }
            if replacing && !items.isEmpty { return }
            self.error = error.localizedDescription
        }
    }

    /// Settled with nothing to show (failed or empty).
    var isSettledEmpty: Bool { didLoad && !isLoading && items.isEmpty }
}

struct CatalogRowView: View {
    let model: CatalogRowModel
    var posterWidth: CGFloat = UIMetrics.posterWidth
    var actions: HomeRowActions?
    /// Collapses the row once it has loaded with no titles (Home); errors still show.
    var hidesWhenEmpty = false
    @Environment(AddonRegistry.self) private var registry

    private var artHeight: CGFloat { posterWidth * 1.5 }

    var body: some View {
        // A catalog that loaded fine but has nothing in it is just noise between the other rows.
        if !(phase == .empty && hidesWhenEmpty) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                header
                ZStack(alignment: .topLeading) { content }
                    .animation(.easeOut(duration: 0.3), value: phase)
            }
            .task { await model.loadIfNeeded(registry) }
        }
    }

    @ViewBuilder private var header: some View {
        let header = RowHeader(title: model.ref.title, subtitle: model.ref.addon.manifest.name)
            .padding(.horizontal, UIMetrics.pagePadding)
        if let actions {
            header
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Hide This Row", systemImage: "eye.slash", action: actions.hide)
                    Button("Move Up", systemImage: "arrow.up") { actions.moveUp?() }
                        .disabled(actions.moveUp == nil)
                    Button("Move Down", systemImage: "arrow.down") { actions.moveDown?() }
                        .disabled(actions.moveDown == nil)
                    Divider()
                    Button("Customize Home…", systemImage: "slider.horizontal.3", action: actions.customize)
                }
        } else {
            header
        }
    }

    private enum Phase: Equatable { case loading, error, empty, items }

    private var phase: Phase {
        if !model.items.isEmpty { return .items }
        if model.error != nil { return .error }
        return model.isLoading || !model.didLoad ? .loading : .empty
    }

    @ViewBuilder private var content: some View {
        if model.items.isEmpty {
            if let error = model.error {
                ErrorBanner(title: "Couldn't load this catalog", messages: [error]) {
                    Task { await model.reload(registry) }
                }
                .padding(.horizontal, UIMetrics.pagePadding)
                .padding(.vertical, Theme.Space.s)
            } else if model.isLoading || !model.didLoad {
                PosterRowSkeleton(width: posterWidth)
            } else {
                Text("Nothing here yet.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .padding(.horizontal, UIMetrics.pagePadding)
                    .padding(.vertical, Theme.Space.s)
            }
        } else {
            PagedRow(items: model.items, itemWidth: posterWidth, artHeight: artHeight,
                     onReachEnd: { Task { await model.loadMore(registry) } }) { item in
                NavigationLink(value: Route.detail(item)) {
                    PosterCard(preview: item, width: posterWidth)
                }
                .buttonStyle(.dsPressable)
            } trailer: {
                trailer
            }
        }
    }

    @ViewBuilder private var trailer: some View {
        if model.isLoading {
            PosterSkeleton(width: posterWidth)
        } else if model.error != nil {
            Button {
                Task { await model.loadMore(registry) }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.ds(.secondary, compact: true))
            .frame(width: max(posterWidth, 110), height: artHeight)
        }
    }
}

/// A non-interactive row of shimmering poster placeholders.
struct PosterRowSkeleton: View {
    var count = 9
    var width: CGFloat = UIMetrics.posterWidth
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: UIMetrics.rowSpacing) {
                ForEach(0..<count, id: \.self) { _ in PosterSkeleton(width: width) }
            }
            .padding(.horizontal, UIMetrics.pagePadding)
            .padding(.vertical, Theme.Space.m)
        }
        .scrollDisabled(true)
        .scrollIndicators(.never)
        .accessibilityLabel("Loading")
    }
}
