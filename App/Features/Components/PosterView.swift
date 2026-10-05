import SwiftUI

/// Rounded poster image with a title placeholder. Height follows `shape` (Stremio posterShape).
struct PosterImage: View {
    let url: URL?
    let title: String
    var width: CGFloat = UIMetrics.posterWidth
    var shape: String? = nil

    static func aspect(for shape: String?) -> CGFloat {
        switch shape {
        case "landscape": 9.0 / 16.0
        case "square": 1
        default: 1.5
        }
    }

    var body: some View {
        RemoteImage(url: url, maxPixelSize: Int(width * 3)) {
            ArtworkPlaceholder(title: title)
        }
        .frame(width: width, height: width * Self.aspect(for: shape))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.Palette.stroke))
    }
}

/// Shown while artwork loads and when a title has none.
struct ArtworkPlaceholder: View {
    var title: String

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.Palette.surfaceHigh, Theme.Palette.surface],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(title)
                .font(Theme.Font.caption.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.Palette.textTertiary)
                .padding(Theme.Space.xs)
        }
    }
}

/// Watch state of a title as shown on its poster.
struct PosterWatchState: Equatable {
    var fraction: Double?
    var watched = false
    static let none = PosterWatchState()
}

extension ProgressStore {
    /// Progress bar for an unfinished title, a check for a watched movie, from its most recent entry.
    func posterWatchState(metaID: String, type: String) -> PosterWatchState {
        var latest: Entry?
        for e in entries.values where e.metaID == metaID {
            if latest.map({ e.updatedAt > $0.updatedAt }) ?? true { latest = e }
        }
        guard let latest else { return .none }
        if latest.isFinished { return type == "movie" ? PosterWatchState(watched: true) : .none }
        return latest.isStarted ? PosterWatchState(fraction: latest.fraction) : .none
    }
}

/// Poster with hover zoom and an info reveal (title, year, rating). Watch progress / watched tick come
/// from the ProgressStore unless `progress` is passed explicitly.
struct PosterCard: View {
    let preview: MetaPreview
    var width: CGFloat = UIMetrics.posterWidth
    var progress: Double? = nil
    /// Title and year under the poster (search grids); rows rely on the hover reveal instead.
    var showsTitle = false

    @Environment(ProgressStore.self) private var progressStore: ProgressStore?
    @State private var hovering = false

    private var watchState: PosterWatchState {
        if let progress { return PosterWatchState(fraction: progress) }
        return progressStore?.posterWatchState(metaID: preview.id, type: preview.type) ?? .none
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous) }

    var body: some View {
        let state = watchState
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            PosterImage(url: preview.poster?.imageURL, title: preview.name, width: width, shape: preview.posterShape)
                .overlay { reveal(state) }
                .overlay(alignment: .topTrailing) {
                    if state.watched { WatchedCheck(size: 20).padding(Theme.Space.xs) }
                }
                .overlay {
                    shape.strokeBorder(.white.opacity(hovering ? 0.45 : 0), lineWidth: 1.5)
                }
                .scaleEffect(hovering ? 1.06 : 1)
                .shadow(color: .black.opacity(hovering ? 0.6 : 0.25), radius: hovering ? 18 : 5, y: hovering ? 10 : 3)
            if showsTitle {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.name)
                        .font(Theme.Font.caption.weight(.semibold))
                        .foregroundStyle(hovering ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                        .lineLimit(1)
                    if let year = preview.releaseInfo, !year.isEmpty {
                        Text(year).font(Theme.Font.caption).foregroundStyle(Theme.Palette.textTertiary).lineLimit(1)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .zIndex(hovering ? 1 : 0)
        .onHover { h in withAnimation(Theme.Motion.hover) { hovering = h } }
        .help(preview.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(preview.name)
        .accessibilityAddTraits(.isButton)
    }

    /// Bottom gradient with progress always visible, plus title/year/rating while hovering.
    private func reveal(_ state: PosterWatchState) -> some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.92), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .opacity(hovering ? 1 : 0)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                if hovering {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preview.name)
                            .font(Theme.Font.headline)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            if let rating = DisplayFormat.rating(preview.imdbRating) {
                                HStack(spacing: 2) {
                                    Image(systemName: "star.fill").foregroundStyle(Theme.Palette.warning)
                                    Text(rating)
                                }
                            }
                            if let year = preview.releaseInfo, !year.isEmpty { Text(year) }
                            Text(DisplayFormat.singularTypeLabel(preview.type))
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                    }
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }
                if let fraction = state.fraction, fraction > 0 {
                    WatchProgressBar(fraction: fraction, height: 3)
                }
            }
            .padding(Theme.Space.s - 2)
        }
        .clipShape(shape)
        .allowsHitTesting(false)
    }
}

/// Watch progress bar (kept for existing call sites; same look as `WatchProgressBar`).
struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        WatchProgressBar(fraction: fraction, height: 4)
    }
}

/// Shimmering placeholder shown while a poster row loads.
struct PosterSkeleton: View {
    var width: CGFloat = UIMetrics.posterWidth
    var showsTitle = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            SkeletonBlock(width: width, height: width * 1.5, cornerRadius: Theme.Radius.m)
            if showsTitle {
                SkeletonBlock(width: width * 0.7, height: 10, cornerRadius: 3)
            }
        }
    }
}

/// Shimmering placeholder for a 16:9 landscape card.
struct LandscapeSkeleton: View {
    var width: CGFloat = UIMetrics.landscapeWidth

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            SkeletonBlock(width: width, height: width * 9 / 16, cornerRadius: Theme.Radius.m)
            SkeletonBlock(width: width * 0.55, height: 12, cornerRadius: 3)
            SkeletonBlock(width: width * 0.35, height: 10, cornerRadius: 3)
        }
    }
}
