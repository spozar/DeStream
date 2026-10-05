import SwiftUI

/// Everything suggestions can be based on. Titles can be excluded from suggestions (e.g. someone else watched them)
/// or removed from history entirely, which also clears them on the Stremio account.
struct WatchHistoryView: View {
    @Environment(Recommendations.self) private var recommendations
    @Environment(LibrarySync.self) private var librarySync
    @Environment(ProgressStore.self) private var progress
    @State private var filter = Filter.all
    @State private var pendingRemoval: RecommendationSeed?

    enum Filter: String, CaseIterable, Identifiable {
        case all, counted, ignored
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All"
            case .counted: "Used for suggestions"
            case .ignored: "Not counted"
            }
        }
        var systemImage: String? {
            switch self {
            case .all: nil
            case .counted: "sparkles"
            case .ignored: "eye.slash"
            }
        }
    }

    private var history: [RecommendationSeed] {
        // Reading these registers observation, so the list refreshes after syncs, playback and removals.
        _ = (librarySync.items.count, progress.entries.count, recommendations.historyVersion)
        return recommendations.watchHistory()
    }

    var body: some View {
        let all = history
        let ignored = recommendations.ignoredSeedIDs
        let visible = all.filter {
            switch filter {
            case .all: true
            case .counted: !ignored.contains($0.metaID)
            case .ignored: ignored.contains($0.metaID)
            }
        }
        let seeds = Set(recommendations.seeds.map(\.metaID))

        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                SectionTitle("Watch History",
                             subtitle: "Turn off anything someone else watched so it stops shaping your suggestions.")
                    .padding(.horizontal, UIMetrics.pagePadding)

                if all.isEmpty {
                    BrowsePlaceholder(systemImage: "clock.arrow.circlepath", title: "No watch history yet",
                                      message: "Titles you watch here or in Stremio show up here.")
                        .padding(.top, Theme.Space.xl)
                } else {
                    ChipScroller {
                        ForEach(Filter.allCases) { f in
                            Button { filter = f } label: {
                                FilterChip(title: chipTitle(f, all: all, ignored: ignored), systemImage: f.systemImage,
                                           selected: filter == f)
                            }
                            .buttonStyle(.dsPressable)
                            .accessibilityAddTraits(filter == f ? [.isSelected] : [])
                        }
                    }

                    if visible.isEmpty {
                        Text(filter == .ignored ? "Every title counts toward your suggestions."
                                                : "Every title is turned off, so suggestions have nothing to go on.")
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .padding(.horizontal, UIMetrics.pagePadding)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(visible.enumerated()), id: \.element.metaID) { index, item in
                                WatchHistoryRow(item: item,
                                                counts: !ignored.contains(item.metaID),
                                                isShapingSuggestions: seeds.contains(item.metaID),
                                                divider: index > 0,
                                                setCounts: { counts in setCounts(counts, item) },
                                                remove: { pendingRemoval = item })
                            }
                        }
                        .dsCard(padding: 0)
                        .padding(.horizontal, UIMetrics.pagePadding)
                        .animation(Theme.Motion.content, value: visible.map(\.metaID))
                    }
                }
            }
            .padding(.top, topPadding)
            .padding(.bottom, Theme.Space.xxl)
        }
        .scrollIndicators(.never)
        .dsCanvas()
        .dsPageTitle("Watch History")
        .dsSelectionHaptic(filter)
        .confirmationDialog("Remove \(pendingRemoval?.name ?? "title") from your history?",
                            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible, presenting: pendingRemoval) { item in
            Button("Remove from History", role: .destructive) {
                withAnimation(Theme.Motion.content) { recommendations.removeFromHistory(metaID: item.metaID) }
                Task { await recommendations.load() }
            }
        } message: { _ in
            Text("This clears its progress and watched episodes here and in your Stremio account. It stays in your Library if you saved it.")
        }
    }

    private func chipTitle(_ f: Filter, all: [RecommendationSeed], ignored: Set<String>) -> String {
        switch f {
        case .all: "All \(all.count)"
        case .counted: f.title
        case .ignored: ignored.isEmpty ? f.title : "\(f.title) \(all.filter { ignored.contains($0.metaID) }.count)"
        }
    }

    private func setCounts(_ counts: Bool, _ item: RecommendationSeed) {
        withAnimation(Theme.Motion.content) { recommendations.setCountsTowardSuggestions(counts, metaID: item.metaID) }
        Task { await recommendations.load() }
    }

    private var topPadding: CGFloat {
        #if os(macOS)
        // Always pushed: clears the shell's floating back button.
        64
        #else
        Theme.Space.s
        #endif
    }
}

private struct WatchHistoryRow: View {
    let item: RecommendationSeed
    let counts: Bool
    let isShapingSuggestions: Bool
    let divider: Bool
    let setCounts: (Bool) -> Void
    let remove: () -> Void

    private var preview: MetaPreview {
        MetaPreview(id: item.metaID, type: item.type, name: item.name, poster: item.poster, posterShape: "poster")
    }

    var body: some View {
        VStack(spacing: 0) {
            if divider { Rectangle().fill(Theme.Palette.stroke).frame(height: 1).padding(.leading, 76) }
            HStack(spacing: Theme.Space.s) {
                NavigationLink(value: Route.detail(preview)) {
                    HStack(spacing: Theme.Space.s) {
                        poster
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name)
                                .font(Theme.Font.headline)
                                .foregroundStyle(Theme.Palette.textPrimary)
                                .lineLimit(1)
                            Text(subtitle)
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .lineLimit(1)
                            if !counts {
                                Pill(text: "Not counted", systemImage: "eye.slash", tint: Theme.Palette.textSecondary)
                            } else if isShapingSuggestions {
                                Pill(text: "Shaping your picks", systemImage: "sparkles", tint: Theme.Palette.accent)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .opacity(counts ? 1 : 0.55)
                }
                .buttonStyle(.dsPressable)
                .accessibilityLabel("\(item.name), \(subtitle)\(counts ? "" : ", not counted toward suggestions")")

                DSToggle(label: "Use \(item.name) for suggestions", isOn: Binding(get: { counts }, set: setCounts))
                    .help(counts ? "Counts toward suggestions" : "Ignored for suggestions")
                actionsMenu
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
        }
        .contextMenu { menuItems }
    }

    private var poster: some View {
        RemoteImage(url: item.poster?.imageURL, maxPixelSize: 160) {
            ZStack {
                Theme.Palette.surfaceHigh
                Image(systemName: item.type == "series" ? "tv" : "film").foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .frame(width: 44, height: 66)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
        .saturation(counts ? 1 : 0)
    }

    private var actionsMenu: some View {
        Menu { menuItems } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: max(32, Theme.Control.minHitTarget), height: max(32, Theme.Control.minHitTarget))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions for \(item.name)")
    }

    @ViewBuilder private var menuItems: some View {
        Button(counts ? "Don't Use for Suggestions" : "Use for Suggestions",
               systemImage: counts ? "eye.slash" : "sparkles") { setCounts(!counts) }
        Divider()
        Button("Remove from History…", systemImage: "trash", role: .destructive, action: remove)
    }

    private var subtitle: String {
        let type = DisplayFormat.singularTypeLabel(item.type)
        let when = item.lastWatched.formatted(.relative(presentation: .named))
        return "\(type) · Watched \(when)"
    }
}
