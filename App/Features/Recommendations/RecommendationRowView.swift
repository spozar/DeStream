import SwiftUI

/// One suggestion row: header by kind, then the shared paged poster row.
struct RecommendationRowView: View {
    let row: RecommendationRow
    var posterWidth: CGFloat = UIMetrics.posterWidth
    var notInterested: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            header
                .padding(.horizontal, UIMetrics.pagePadding)
            PagedRow(items: row.items, itemWidth: posterWidth, artHeight: posterWidth * 1.5) { item in
                NavigationLink(value: Route.detail(item)) {
                    PosterCard(preview: item, width: posterWidth)
                }
                .buttonStyle(.dsPressable)
                .accessibilityLabel(accessibilityLabel(for: item))
                .accessibilityHint("Shows details")
                .contextMenu {
                    Button("Not Interested", systemImage: "hand.thumbsdown", role: .destructive) {
                        notInterested(item.id)
                    }
                }
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
            .animation(Theme.Motion.content, value: row.items.map(\.id))
        }
    }

    private func accessibilityLabel(for item: MetaPreview) -> String {
        [item.name, item.releaseInfo, DisplayFormat.singularTypeLabel(item.type)]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: ", ")
    }

    @ViewBuilder private var header: some View {
        switch row.kind {
        case .becauseYouWatched(let seed):
            BecauseYouWatchedHeader(seed: seed)
        case .topPicks:
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.Palette.accentGradient)
                    .accessibilityHidden(true)
                RowHeader(title: row.title.isEmpty ? "Top Picks for You" : row.title)
            }
        case .genre:
            RowHeader(title: row.title)
        }
    }
}

/// Seed mini poster + "BECAUSE YOU WATCHED" small caps + the seed's name; links to the seed title.
struct BecauseYouWatchedHeader: View {
    let seed: RecommendationSeed
    @ScaledMetric(relativeTo: .body) private var posterWidth: CGFloat = 26

    private var preview: MetaPreview {
        MetaPreview(id: seed.metaID, type: seed.type, name: seed.name, poster: seed.poster)
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            NavigationLink(value: Route.detail(preview)) {
                HStack(spacing: Theme.Space.s) {
                    MiniPoster(url: seed.poster?.imageURL, title: seed.name, width: posterWidth)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("BECAUSE YOU WATCHED")
                            .font(Theme.Font.micro)
                            .tracking(1.1)
                            .foregroundStyle(Theme.Palette.textTertiary)
                        Text(seed.name)
                            .font(Theme.Font.rowTitle)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.dsPressable)
            .help("Open \(seed.name)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Because you watched \(seed.name)")
            .accessibilityHint("Opens \(seed.name)")
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
    }
}

/// Loading layout mirroring the page: hero card, then poster rows with headers.
struct RecommendationsSkeleton: View {
    var posterWidth: CGFloat = UIMetrics.posterWidth

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            SkeletonBlock(height: heroHeight, cornerRadius: Theme.Radius.l)
                .padding(.horizontal, UIMetrics.pagePadding)
            ForEach(0..<3, id: \.self) { i in
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    HStack(spacing: Theme.Space.s) {
                        if i > 0 {
                            SkeletonBlock(width: 26, height: 39, cornerRadius: 4)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            if i > 0 { SkeletonBlock(width: 110, height: 9, cornerRadius: 3) }
                            SkeletonBlock(width: i == 0 ? 170 : 140, height: 16, cornerRadius: 4)
                        }
                    }
                    .padding(.horizontal, UIMetrics.pagePadding)
                    PosterRowSkeleton(width: posterWidth)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading suggestions")
    }

    private var heroHeight: CGFloat {
        #if os(macOS)
        360
        #else
        300
        #endif
    }
}
