import SwiftUI

/// Featured suggestion: backdrop card with an eyebrow, logo or title, metadata and a details action.
/// Full meta (backdrop, logo, genres) comes from the shared `ArtworkCache`, like the Home billboard.
struct RecommendationHero: View {
    struct Pick: Equatable {
        var preview: MetaPreview
        var eyebrow: String
        /// Used when the addon meta has no backdrop (e.g. a seed's own background).
        var fallbackBackdrop: String?
    }

    let pick: Pick?
    @Environment(AddonRegistry.self) private var registry: AddonRegistry?
    @State private var width: CGFloat = 0
    private var cache: ArtworkCache { .shared }

    private var isCompact: Bool { width > 0 && width < 520 }

    private var height: CGFloat {
        guard width > 0 else { return 320 }
        return isCompact ? min(max(width * 1.12, 380), 500) : min(max(width * 0.36, 320), 440)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous) }

    var body: some View {
        Group {
            if let pick {
                NavigationLink(value: Route.detail(pick.preview)) {
                    card(pick, detail: cache.detail(pick.preview.id))
                }
                .buttonStyle(DSPressableStyle(scale: 0.99))
                .accessibilityLabel("\(pick.eyebrow): \(pick.preview.name)")
                .accessibilityHint("Shows details")
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: pick?.preview.id) {
            guard let pick, let registry else { return }
            await cache.load(type: pick.preview.type, id: pick.preview.id, registry: registry)
        }
    }

    private func card(_ pick: Pick, detail: MetaDetail?) -> some View {
        ZStack(alignment: .bottomLeading) {
            backdrop(pick, detail: detail)
            scrims
            info(pick, detail: detail)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.Palette.stroke))
        .hoverLift(scale: 1.01)
        .animation(Theme.Motion.imageFade, value: detail?.background)
    }

    @ViewBuilder private func backdrop(_ pick: Pick, detail: MetaDetail?) -> some View {
        if let url = detail?.background?.imageURL ?? pick.fallbackBackdrop?.imageURL {
            Color.clear.overlay(alignment: .top) {
                RemoteImage(url: url, maxPixelSize: 2000) { Theme.Palette.surface }
            }
            .clipped()
        } else {
            // No backdrop: a blurred poster wash plus the crisp poster keeps the card from looking empty.
            Color.clear.overlay {
                RemoteImage(url: pick.preview.poster?.imageURL, maxPixelSize: 400) { Theme.Palette.surface }
                    .blur(radius: 40)
                    .scaleEffect(1.3)
                    .opacity(0.7)
            }
            .clipped()
            .background(Theme.Palette.surface)
            .overlay(alignment: isCompact ? .top : .trailing) { featuredPoster(pick) }
        }
    }

    private func featuredPoster(_ pick: Pick) -> some View {
        let posterHeight = isCompact ? height * 0.46 : height - Theme.Space.xl * 2
        return RemoteImage(url: pick.preview.poster?.imageURL, maxPixelSize: 800) {
            ArtworkPlaceholder(title: pick.preview.name)
        }
        .frame(width: posterHeight * 2 / 3, height: posterHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.Palette.stroke))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
        .padding(isCompact ? .top : .trailing, isCompact ? Theme.Space.l : Theme.Space.xl * 1.5)
        .accessibilityHidden(true)
    }

    private var scrims: some View {
        ZStack {
            if !isCompact {
                LinearGradient(stops: [.init(color: Theme.Palette.canvas.opacity(0.92), location: 0),
                                       .init(color: Theme.Palette.canvas.opacity(0.55), location: 0.38),
                                       .init(color: .clear, location: 0.72)],
                               startPoint: .leading, endPoint: .trailing)
            }
            LinearGradient(stops: [.init(color: .clear, location: isCompact ? 0.25 : 0.5),
                                   .init(color: Theme.Palette.canvas.opacity(0.85), location: isCompact ? 0.68 : 0.88),
                                   .init(color: Theme.Palette.canvas, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
    }

    private func info(_ pick: Pick, detail: MetaDetail?) -> some View {
        VStack(alignment: .leading, spacing: isCompact ? Theme.Space.xs : Theme.Space.s) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text(pick.eyebrow.uppercased())
                    .lineLimit(1)
            }
            .font(Theme.Font.micro)
            .tracking(1.1)
            .foregroundStyle(Theme.Palette.accentHover)
            titleArt(pick, detail: detail)
            metaLine(pick, detail: detail)
            if let text = detail?.description ?? pick.preview.description, !text.isEmpty {
                Text(text)
                    .font(.system(size: isCompact ? 13 : 15))
                    .foregroundStyle(Theme.Palette.textPrimary.opacity(0.82))
                    .lineLimit(isCompact ? 2 : 3)
                    .lineSpacing(2)
                    .shadow(color: .black.opacity(0.5), radius: 4)
            }
            Label("More Info", systemImage: "info.circle")
                .font(Theme.Control.compactFont)
                .foregroundStyle(.black)
                .padding(.horizontal, Theme.Control.compactHorizontalPadding)
                .frame(minHeight: Theme.Control.compactHeight)
                .background(.white, in: RoundedRectangle(cornerRadius: Theme.Control.compactRadius, style: .continuous))
                .padding(.top, Theme.Space.xxs)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: isCompact ? .infinity : 500, alignment: .leading)
        .padding(isCompact ? Theme.Space.m : Theme.Space.xl)
    }

    @ViewBuilder private func titleArt(_ pick: Pick, detail: MetaDetail?) -> some View {
        let title = Text(detail?.name ?? pick.preview.name)
            .font(isCompact ? .system(size: 30, weight: .heavy) : .system(size: 38, weight: .heavy))
            .foregroundStyle(Theme.Palette.textPrimary)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .shadow(color: .black.opacity(0.5), radius: 8)
        if let logo = detail?.logo?.imageURL {
            RemoteImage(url: logo, maxPixelSize: 1000, contentMode: .fit, lightensDarkCutouts: true) {
                title.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .frame(maxWidth: isCompact ? 240 : 360, maxHeight: isCompact ? 80 : 110, alignment: .bottomLeading)
            .shadow(color: .black.opacity(0.45), radius: 10)
            .accessibilityLabel(detail?.name ?? pick.preview.name)
        } else {
            title
        }
    }

    private func metaLine(_ pick: Pick, detail: MetaDetail?) -> some View {
        let type = detail?.type ?? pick.preview.type
        let year = detail?.displayYear ?? pick.preview.releaseInfo
        let genres = detail?.allGenres ?? []
        return HStack(spacing: Theme.Space.xs) {
            Badge(text: DisplayFormat.singularTypeLabel(type).uppercased(), tint: Theme.Palette.accent)
            if let rating = DisplayFormat.rating(detail?.imdbRating ?? pick.preview.imdbRating) {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill").foregroundStyle(Theme.Palette.warning)
                    Text(rating)
                }
            }
            if let year, !year.isEmpty { Text(year) }
            if !genres.isEmpty {
                Text(genres.prefix(isCompact ? 2 : 3).joined(separator: " • "))
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)
        .foregroundStyle(Theme.Palette.textPrimary.opacity(0.9))
        .shadow(color: .black.opacity(0.5), radius: 4)
    }
}
