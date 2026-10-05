import SwiftUI

/// "For You": suggestions built from the user's watch history. Root of the Suggestions section. OWNER: Rec Agent 3.
struct RecommendationsView: View {
    /// Opens the TMDB key screen. When nil, the view presents `TMDBKeySettingsView` in a sheet itself.
    var onConnectTMDB: (() -> Void)? = nil

    @Environment(Recommendations.self) private var recommendations
    @Environment(TMDBKeyStore.self) private var keyStore
    @Environment(StremioAccount.self) private var account
    @AppStorage("recommendations.tmdbUpsellDismissed") private var upsellDismissed = false
    @State private var connectingTMDB = false
    @State private var signingIn = false

    var body: some View {
        #if DEBUG
        // QA hook (any platform): `-DeStreamSuggestionsSample tmdb|cinemeta|fallback|loading|nohistory|failed`.
        if let sample = UserDefaults.standard.string(forKey: "DeStreamSuggestionsSample") {
            RecommendationsContent(state: RecommendationsSample.state(named: sample), actions: .none)
        } else {
            live
        }
        #else
        live
        #endif
    }

    private var live: some View {
        RecommendationsContent(
            state: state,
            actions: RecommendationsActions(
                selectSource: select,
                refresh: { Task { await recommendations.load(force: true) } },
                connectTMDB: connectTMDB,
                dismissUpsell: { withAnimation(Theme.Motion.content) { upsellDismissed = true } },
                dismissTitle: { id in withAnimation(Theme.Motion.content) { recommendations.dismiss(metaID: id) } },
                signIn: { signingIn = true }))
            .refreshable { await recommendations.load(force: true) }
            .task(id: recommendations.effectiveSource) { await recommendations.load() }
            .onChange(of: keyStore.hasKey) { _, hasKey in
                // A key added from this page (or Settings) means the user wants TMDB picks.
                if hasKey { recommendations.source = .tmdb }
            }
            .sheet(isPresented: $connectingTMDB) { TMDBKeySettingsView(isPresentedAsSheet: true) }
            .sheet(isPresented: $signingIn) { StremioSignInSheet() }
    }

    /// The loaded feed, or the previous one (possibly stale or from the other source) while a load is in flight.
    private var feed: RecommendationFeed? {
        switch recommendations.phase {
        case .loaded(let feed): feed
        case .idle, .loading: recommendations.lastFeed
        case .noHistory, .failed: nil
        }
    }

    private var state: RecommendationsState {
        let phase = recommendations.phase
        var error: String?
        if case .failed(let message) = phase { error = message }
        let source = recommendations.effectiveSource
        // Once loaded, show the source that actually produced the feed (TMDB can fall back to Cinemeta).
        var selected = source
        if case .loaded(let feed) = phase { selected = feed.source }
        return RecommendationsState(
            feed: feed,
            seeds: recommendations.seeds,
            isLoading: phase == .loading || phase == .idle,
            isEmptyHistory: phase == .noHistory,
            error: error,
            notice: recommendations.notice,
            selectedSource: selected,
            tmdbAvailable: keyStore.hasKey,
            showsUpsell: !keyStore.hasKey && !upsellDismissed,
            isSignedIn: account.isSignedIn)
    }

    private func select(_ source: RecommendationSource) {
        if source == .tmdb && !keyStore.hasKey {
            connectTMDB()
        } else if source != recommendations.source {
            recommendations.source = source
        } else if source != state.selectedSource {
            // Already chosen but the feed fell back to Cinemeta: tapping TMDB again retries it.
            Task { await recommendations.load(force: true) }
        }
    }

    private func connectTMDB() {
        if let onConnectTMDB { onConnectTMDB() } else { connectingTMDB = true }
    }
}

/// Snapshot of everything the page draws, so the layout can be previewed without the engine.
struct RecommendationsState {
    /// Last loaded feed; kept on screen while a refresh or source switch is in flight.
    var feed: RecommendationFeed?
    var seeds: [RecommendationSeed]
    var isLoading: Bool
    var isEmptyHistory: Bool
    var error: String?
    /// Non-fatal note from the engine (e.g. TMDB fell back to Cinemeta), shown as a subtle inline banner.
    var notice: String? = nil
    var selectedSource: RecommendationSource
    var tmdbAvailable: Bool
    var showsUpsell: Bool
    var isSignedIn: Bool
}

struct RecommendationsActions {
    var selectSource: (RecommendationSource) -> Void
    var refresh: () -> Void
    var connectTMDB: () -> Void
    var dismissUpsell: () -> Void
    var dismissTitle: (String) -> Void
    var signIn: () -> Void

    static var none: RecommendationsActions { RecommendationsActions(selectSource: { _ in }, refresh: {}, connectTMDB: {},
                                             dismissUpsell: {}, dismissTitle: { _ in }, signIn: {}) }
}

/// Stateless page body: header, hero and suggestion rows (or the loading / empty / error states).
struct RecommendationsContent: View {
    let state: RecommendationsState
    let actions: RecommendationsActions
    /// Titles hidden via "Not interested" this session, so they leave immediately even before the engine republishes.
    @State private var hiddenIDs = Set<String>()
    @State private var viewport: CGFloat = 0

    private var rows: [RecommendationRow] {
        guard let feed = state.feed else { return [] }
        return feed.rows.compactMap { row in
            var row = row
            row.items.removeAll { hiddenIDs.contains($0.id) }
            return row.items.isEmpty ? nil : row
        }
    }

    var body: some View {
        let rows = rows
        let posterWidth = BrowseLayout.posterWidth(viewport: viewport)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                RecommendationsHeader(state: state, actions: actions)
                    .padding(.horizontal, UIMetrics.pagePadding)
                if let notice = state.notice, state.error == nil, !state.isEmptyHistory {
                    RecommendationsNotice(text: notice)
                        .padding(.horizontal, UIMetrics.pagePadding)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if let error = state.error {
                    ErrorBanner(title: "Couldn't load suggestions", messages: [error], retry: actions.refresh)
                        .padding(.horizontal, UIMetrics.pagePadding)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if state.showsUpsell && !state.isEmptyHistory {
                    TMDBUpsellCard(connect: actions.connectTMDB, dismiss: actions.dismissUpsell)
                        .padding(.horizontal, UIMetrics.pagePadding)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
                content(rows: rows, posterWidth: posterWidth)
                if state.feed?.source == .tmdb {
                    TMDBAttribution()
                        .padding(.horizontal, UIMetrics.pagePadding)
                        .padding(.top, Theme.Space.s)
                }
            }
            .padding(.top, topPadding)
            .padding(.bottom, Theme.Space.xxl)
            .animation(Theme.Motion.content, value: state.error)
            .animation(Theme.Motion.content, value: state.notice)
            .animation(Theme.Motion.content, value: state.showsUpsell)
            .animation(Theme.Motion.content, value: rows.map(\.id))
        }
        .scrollIndicators(.never)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewport = $0 }
        .dsCanvas()
        .dsPageTitle("For You")
    }

    private var topPadding: CGFloat {
        #if os(macOS)
        Theme.Space.l
        #else
        Theme.Space.s
        #endif
    }

    @ViewBuilder private func content(rows: [RecommendationRow], posterWidth: CGFloat) -> some View {
        if state.feed != nil {
            if rows.isEmpty {
                BrowsePlaceholder(systemImage: "sparkles", title: "Nothing to Suggest Yet",
                                  message: "Watch a few more titles and check back — suggestions improve as your history grows.")
                    .padding(.top, Theme.Space.xl)
            } else {
                let hero = heroPick(rows)
                RecommendationHero(pick: hero)
                    .padding(.horizontal, UIMetrics.pagePadding)
                LazyVStack(alignment: .leading, spacing: Theme.Space.xl) {
                    ForEach(Self.removingHero(hero?.preview.id, from: rows)) { row in
                        RecommendationRowView(row: row, posterWidth: posterWidth, notInterested: notInterested)
                            .transition(.opacity)
                    }
                }
                .padding(.top, Theme.Space.s)
            }
        } else if state.isEmptyHistory {
            noHistory
        } else if state.error == nil {
            RecommendationsSkeleton(posterWidth: posterWidth)
                .transition(.opacity)
        }
    }

    /// Drops the hero title from the first row that has it, so it isn't shown twice above the fold.
    static func removingHero(_ id: String?, from rows: [RecommendationRow]) -> [RecommendationRow] {
        guard let id, let index = rows.firstIndex(where: { $0.items.contains { $0.id == id } }),
              rows[index].items.count > Recommendations.minRowItems else { return rows }
        var rows = rows
        rows[index].items.removeAll { $0.id == id }
        return rows
    }

    private func notInterested(_ id: String) {
        withAnimation(Theme.Motion.content) { _ = hiddenIDs.insert(id) }
        actions.dismissTitle(id)
    }

    /// The first top pick, else the most important seed's first suggestion.
    private func heroPick(_ rows: [RecommendationRow]) -> RecommendationHero.Pick? {
        if let top = rows.first(where: { $0.kind == .topPicks }), let item = top.items.first {
            return .init(preview: item, eyebrow: "Top Pick for You", fallbackBackdrop: nil)
        }
        for row in rows {
            if case .becauseYouWatched(let seed) = row.kind, let item = row.items.first {
                return .init(preview: item, eyebrow: "Because You Watched \(seed.name)", fallbackBackdrop: nil)
            }
        }
        if let seed = state.seeds.first(where: { $0.background != nil }) ?? state.seeds.first {
            let preview = MetaPreview(id: seed.metaID, type: seed.type, name: seed.name, poster: seed.poster)
            return .init(preview: preview, eyebrow: "From Your History", fallbackBackdrop: seed.background)
        }
        return nil
    }

    private var noHistory: some View {
        DSEmptyState(systemImage: "sparkles.tv",
                     title: "Nothing to Go On Yet",
                     message: state.isSignedIn
                        ? "Watch a movie or an episode and your personal picks will show up here."
                        : "Watch something, or sign in to Stremio to bring your watch history along.") {
            if !state.isSignedIn {
                Button(action: actions.signIn) {
                    Label("Sign In to Stremio", systemImage: "person.crop.circle")
                }
                .buttonStyle(.dsAccent)
            }
        }
        .padding(.top, Theme.Space.xl)
    }
}

/// Subtle inline note for non-fatal problems, e.g. TMDB being unreachable and Cinemeta used instead.
struct RecommendationsNotice: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Theme.Palette.textTertiary)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.Font.caption)
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.xs)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.Palette.stroke))
        .accessibilityElement(children: .combine)
    }
}

/// Small, secondary TMDB attribution required by the TMDB API terms.
struct TMDBAttribution: View {
    var body: some View {
        Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textTertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
    }
}
