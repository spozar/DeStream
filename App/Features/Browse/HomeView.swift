import SwiftUI
import Observation

/// Billboard, "Latest" (streamed Continue Watching), "Suggested for You" and one paged row per home catalog. OWNER: UI Agent 2.
struct HomeView: View {
    @Environment(AddonRegistry.self) private var registry
    @Environment(ProgressStore.self) private var progress
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(Recommendations.self) private var recommendations
    @State private var home = HomeModel()
    @State private var customizing = false
    @State private var detailTarget: MetaPreview?
    @State private var viewport: CGFloat = 0
    /// Fixes the billboard's random pick for this view's lifetime, so re-renders don't reshuffle it.
    @State private var billboardSeed = Int.random(in: .min ... .max)
    /// None of the current billboard candidates has a usable backdrop; the billboard collapses instead of
    /// shimmering forever. Reset whenever the candidates change.
    @State private var billboardUnavailable = false

    private var installedRefs: [CatalogRef] { registry.homeCatalogs.map(CatalogRef.init) }
    private var refs: [CatalogRef] { settings.homeRows.visible(installedRefs, id: \.homeRowID) }

    /// Streamed Continue Watching: in-progress episodes/movies plus, for series whose latest episode is finished,
    /// the next episode (once the series' meta has loaded and that episode is out).
    private var latest: ContinueWatching {
        guard settings.homeRows.showsContinueWatching else { return ContinueWatching() }
        // Entries recorded before `isLocal` existed are treated as local when the title is saved on disk.
        let local = Set(library.titles.map(\.id))
        let candidates = upNextCandidates
        let candidateIDs = Set(candidates.map(\.metaID))
        var upNext: [String: Video] = [:]
        for entry in candidates {
            guard let meta = ArtworkCache.shared.detail(entry.metaID), let next = progress.nextUp(for: meta),
                  next.id != entry.videoId, !progress.isWatched(next.id), !DetailFormat.isUpcoming(next) else { continue }
            upNext[entry.metaID] = next
        }
        let inProgress = progress.latestStreamed(localMetaIDs: local).filter { !candidateIDs.contains($0.metaID) }
        let entries = (inProgress + candidates.filter { upNext[$0.metaID] != nil }).sorted { $0.updatedAt > $1.updatedAt }
        return ContinueWatching(entries: entries, upNext: upNext)
    }

    private struct ContinueWatching {
        var entries: [ProgressStore.Entry] = []
        var upNext: [String: Video] = [:]
        var isEmpty: Bool { entries.isEmpty }
    }

    private var upNextCandidates: [ProgressStore.Entry] {
        guard settings.homeRows.showsContinueWatching else { return [] }
        return progress.upNextCandidates(localMetaIDs: Set(library.titles.map(\.id)))
    }

    /// Non-empty suggestion rows; the previous feed stays up while a refresh is in flight.
    private var suggestionRows: [RecommendationRow] {
        guard settings.homeRows.showsSuggestions else { return [] }
        let feed: RecommendationFeed?
        switch recommendations.phase {
        case .loaded(let loaded): feed = loaded
        case .idle, .loading: feed = recommendations.lastFeed
        case .noHistory, .failed: feed = nil
        }
        return feed?.rows.filter { !$0.items.isEmpty } ?? []
    }

    /// The feed's top picks, else its first row.
    private var suggested: RecommendationRow? {
        let rows = suggestionRows
        return rows.first { $0.kind == .topPicks } ?? rows.first
    }

    /// Six random titles from the strongest dozen Top Picks, stable for a given seed and feed. Drawing from every
    /// "Because you watched" row put weak matches (one-off family movies etc.) on the billboard.
    private var randomSuggestions: [MetaPreview] {
        let pool = (suggested?.items ?? []).prefix(12)
        let seed = billboardSeed
        return Array(pool.sorted { $0.id.hashValue ^ seed < $1.id.hashValue ^ seed }.prefix(6))
    }

    /// Suggestions may still arrive; holding the billboard avoids flashing catalog titles first.
    private var awaitingSuggestions: Bool {
        guard settings.homeRows.showsSuggestions else { return false }
        switch recommendations.phase {
        case .idle, .loading: return recommendations.lastFeed == nil
        default: return false
        }
    }

    /// Billboard titles: random suggestions, else the top of the first catalog that has loaded.
    private var billboardCandidates: [MetaPreview] {
        let random = randomSuggestions
        if !random.isEmpty { return random }
        if awaitingSuggestions { return [] }
        guard let row = home.rows.first(where: { !$0.items.isEmpty }) else { return [] }
        return Array(row.items.prefix(6))
    }

    private var showsBillboard: Bool {
        guard !billboardUnavailable else { return false }
        return suggested != nil || (!home.rows.isEmpty && !home.rows.allSatisfy(\.isSettledEmpty))
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if showsBillboard {
                        HomeBillboard(candidates: billboardCandidates, isUnavailable: $billboardUnavailable)
                    }
                    LazyVStack(alignment: .leading, spacing: Theme.Space.xl) {
                        if !latest.isEmpty {
                            LatestRow(entries: latest.entries, upNext: latest.upNext, detailTarget: $detailTarget,
                                      cardWidth: BrowseLayout.landscapeWidth(viewport: viewport))
                                .transition(.opacity)
                        }
                        if let suggested {
                            RecommendationRowView(row: suggestedForYou(suggested),
                                                  posterWidth: BrowseLayout.posterWidth(viewport: viewport),
                                                  notInterested: notInterested)
                                .transition(.opacity)
                        }
                        if settings.homeRows.showsGenres {
                            GenreShortcuts()
                        }
                        let rows = home.rows
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                            CatalogRowView(model: row, posterWidth: BrowseLayout.posterWidth(viewport: viewport),
                                           actions: actions(for: row.ref, isFirst: i == 0, isLast: i == rows.count - 1),
                                           hidesWhenEmpty: true)
                        }
                        if installedRefs.isEmpty {
                            noCatalogs
                        } else {
                            customizeButton
                        }
                    }
                    .animation(Theme.Motion.appear, value: latest.isEmpty)
                    .animation(Theme.Motion.appear, value: suggested == nil)
                    .padding(.top, showsBillboard ? -UIMetrics.billboardOverlap : topInset)
                    .padding(.bottom, Theme.Space.xxl)
                }
            }
            .scrollIndicators(.never)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewport = $0 }
            .ignoresSafeArea(edges: showsBillboard ? .top : [])
            #if os(iOS)
            TopBarScrim()
            #endif
        }
        .dsCanvas()
        .navigationDestination(item: $detailTarget) { DetailView(preview: $0) }
        .sheet(isPresented: $customizing) { HomeRowsView { customizing = false } }
        .navigationTitle("Home")
        .onChange(of: refs.map(\.id), initial: true) { home.sync(refs) }
        .onChange(of: billboardCandidates.map(\.id)) { billboardUnavailable = false }
        // The billboard draws from the first row, which may start below the fold of the lazy stack.
        .task(id: home.rows.first?.id) { await home.rows.first?.loadIfNeeded(registry) }
        .task(id: upNextCandidates.map(\.metaID)) {
            await withTaskGroup(of: Void.self) { group in
                for entry in upNextCandidates {
                    group.addTask { await ArtworkCache.shared.load(type: entry.metaType, id: entry.metaID, registry: registry) }
                }
            }
        }
        .task(id: recommendations.effectiveSource) {
            // Don't restart a load the Suggestions page already has in flight.
            guard recommendations.phase != .loading else { return }
            await recommendations.load()
        }
        .refreshable {
            async let catalogs: Void = home.reloadAll(registry)
            if settings.homeRows.showsSuggestions { await recommendations.load(force: true) }
            await catalogs
        }
        #if os(macOS)
        .toolbarBackground(.hidden, for: .windowToolbar)
        #else
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    private var topInset: CGFloat { Theme.Space.l }

    private func suggestedForYou(_ row: RecommendationRow) -> RecommendationRow {
        var row = row
        if row.kind == .topPicks { row.title = "Suggested for You" }
        return row
    }

    private func notInterested(_ id: String) {
        withAnimation(Theme.Motion.content) { recommendations.dismiss(metaID: id) }
    }

    /// Inline rather than an overlay, so it never sits on top of Continue Watching or suggestions.
    private var noCatalogs: some View {
        VStack(spacing: Theme.Space.s) {
            BrowsePlaceholder(systemImage: "square.grid.2x2", title: "No Catalogs",
                              message: "Add a catalog addon such as Cinemeta to fill Home with movies and series.")
            ManageAddonsButton()
        }
        .padding(.top, latest.isEmpty && suggested == nil ? Theme.Space.xxl * 2 : Theme.Space.l)
        .frame(maxWidth: .infinity)
    }

    private var customizeButton: some View {
        Button { customizing = true } label: {
            Label("Customize Home", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(.ds(.ghost, compact: true))
        .frame(maxWidth: .infinity)
    }

    private func actions(for ref: CatalogRef, isFirst: Bool, isLast: Bool) -> HomeRowActions {
        let id = ref.homeRowID
        let ids = { settings.homeRows.arranged(installedRefs, id: \.homeRowID).map(\.homeRowID) }
        return HomeRowActions(
            hide: { withAnimation(Theme.Motion.content) { settings.homeRows.setHidden(id, true) } },
            moveUp: isFirst ? nil : { withAnimation(Theme.Motion.content) { settings.homeRows.moveVisible(id, up: true, in: ids()) } },
            moveDown: isLast ? nil : { withAnimation(Theme.Motion.content) { settings.homeRows.moveVisible(id, up: false, in: ids()) } },
            customize: { customizing = true })
    }
}

@MainActor @Observable
final class HomeModel {
    private(set) var rows: [CatalogRowModel] = []

    /// Keeps loaded rows whose catalog still exists; creates models for new ones, in registry order.
    func sync(_ refs: [CatalogRef]) {
        let existing = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        rows = refs.compactMap { ref in
            guard seen.insert(ref.id).inserted else { return nil }
            return existing[ref.id] ?? CatalogRowModel(ref: ref)
        }
    }

    func reloadAll(_ registry: AddonRegistry) async {
        await withTaskGroup(of: Void.self) { group in
            for row in rows {
                group.addTask { await row.reload(registry) }
            }
        }
    }
}
