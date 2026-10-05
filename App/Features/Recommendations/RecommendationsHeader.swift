import SwiftUI

/// "For You" title, refresh control, source switcher and the "Based on N titles" seed strip.
struct RecommendationsHeader: View {
    let state: RecommendationsState
    let actions: RecommendationsActions

    private var isRefreshing: Bool { state.isLoading && state.feed != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionTitle(title: "For You") {
                refreshControl
            }
            if !state.isEmptyHistory {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Space.m) {
                        seedSummary
                        Spacer(minLength: 0)
                        switcher
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        switcher
                        seedSummary
                    }
                }
            }
        }
    }

    @ViewBuilder private var refreshControl: some View {
        if isRefreshing {
            ProgressView()
                .controlSize(.small)
                .frame(width: Theme.Control.iconCircle, height: Theme.Control.iconCircle)
                .accessibilityLabel("Refreshing suggestions")
                .transition(.opacity)
        } else {
            IconCircleButton("arrow.clockwise", label: "Refresh Suggestions", size: Theme.Control.compactHeight + 6,
                             action: actions.refresh)
                .disabled(state.isLoading)
                .transition(.opacity)
        }
    }

    private var switcher: some View {
        SourceSwitcher(selected: state.selectedSource, tmdbAvailable: state.tmdbAvailable,
                       select: actions.selectSource)
    }

    @ViewBuilder private var seedSummary: some View {
        if !state.seeds.isEmpty {
            NavigationLink(value: Route.watchHistory) {
                HStack(spacing: Theme.Space.xs) {
                    SeedPosterStack(seeds: Array(state.seeds.prefix(4)))
                    Text("Based on \(state.seeds.count) \(state.seeds.count == 1 ? "title" : "titles") you watched")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.dsPressable)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Based on \(state.seeds.count) titles you watched")
            .accessibilityHint("Shows your watch history")
            .accessibilityAddTraits(.isButton)
            .transition(.opacity)
        }
    }
}

/// Segmented TMDB / Cinemeta control. TMDB shows a lock and opens the key screen while no key is stored.
struct SourceSwitcher: View {
    let selected: RecommendationSource
    let tmdbAvailable: Bool
    let select: (RecommendationSource) -> Void
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(RecommendationSource.allCases) { source in
                segment(source)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Palette.stroke))
        .fixedSize()
        .animation(Theme.Motion.hover, value: selected)
        .dsSelectionHaptic(selected)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggestion source")
    }

    private func segment(_ source: RecommendationSource) -> some View {
        let isSelected = source == selected
        let locked = source == .tmdb && !tmdbAvailable
        return Button {
            select(source)
        } label: {
            HStack(spacing: 5) {
                if locked {
                    Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold))
                }
                Text(source.title)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isSelected ? Color.white : locked ? Theme.Palette.textTertiary : Theme.Palette.textSecondary)
            .padding(.horizontal, 12)
            .frame(minHeight: segmentHeight)
            .background {
                if isSelected {
                    Capsule().fill(Theme.Palette.accentGradient)
                        .matchedGeometryEffect(id: "selection", in: selection)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.dsPressable)
        .help(locked ? "Add a free TMDB key for personalised picks" : "Suggestions from \(source.title)")
        .accessibilityLabel(source.title)
        .accessibilityHint(locked ? "Requires a TMDB key. Opens TMDB setup." : "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var segmentHeight: CGFloat {
        #if os(macOS)
        24
        #else
        30
        #endif
    }
}

extension RecommendationSource {
    var title: String {
        switch self {
        case .tmdb: "TMDB"
        case .cinemeta: "Cinemeta"
        }
    }
}

/// Overlapping mini posters of the watched titles suggestions are based on.
struct SeedPosterStack: View {
    let seeds: [RecommendationSeed]
    @ScaledMetric(relativeTo: .caption) private var width: CGFloat = 18

    var body: some View {
        HStack(spacing: -width * 0.45) {
            ForEach(Array(seeds.enumerated()), id: \.element.id) { i, seed in
                MiniPoster(url: seed.poster?.imageURL, title: seed.name, width: width)
                    .zIndex(Double(seeds.count - i))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Tiny rounded poster with a dark hairline so overlapping stacks stay readable.
struct MiniPoster: View {
    let url: URL?
    let title: String
    var width: CGFloat

    var body: some View {
        RemoteImage(url: url, maxPixelSize: Int(width * 4)) {
            ArtworkPlaceholder(title: "")
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: max(2, width * 0.14), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: max(2, width * 0.14), style: .continuous)
            .strokeBorder(Theme.Palette.canvas.opacity(0.9), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }
}

/// Dismissible prompt to connect TMDB while suggestions come from Cinemeta.
struct TMDBUpsellCard: View {
    let connect: () -> Void
    let dismiss: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.m) {
                icon
                // A modest ideal width lets the copy wrap instead of forcing the stacked layout on narrow windows.
                text.frame(minWidth: 0, idealWidth: 280, maxWidth: .infinity, alignment: .leading)
                connectButton
                closeButton.padding(.trailing, -Theme.Space.xs)
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    icon
                    text
                    Spacer(minLength: 0)
                    closeButton.padding(-Theme.Space.xs)
                }
                connectButton
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s + 2)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
                .fill(Theme.Palette.surface)
                .overlay(
                    LinearGradient(colors: [Theme.Palette.accent.opacity(0.22), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)))
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
            .strokeBorder(Theme.Palette.accent.opacity(0.35)))
    }

    private var icon: some View {
        Image(systemName: "wand.and.stars")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(Theme.Palette.accentGradient, in: Circle())
            .accessibilityHidden(true)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Get personalised picks")
                .font(Theme.Font.headline)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("Connect a free TMDB key for “Because you watched” suggestions.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectButton: some View {
        Button(action: connect) {
            Label("Connect TMDB", systemImage: "key.fill")
        }
        .buttonStyle(.ds(.accent, compact: true))
    }

    private var closeButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(width: 24, height: 24)
                .padding(Theme.Space.xs)
                .contentShape(Circle())
        }
        .buttonStyle(.dsPressable)
        .help("Dismiss")
        .accessibilityLabel("Dismiss TMDB suggestion")
    }
}
