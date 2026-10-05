import SwiftUI

/// Home "Latest": titles the user started streaming, as landscape Continue Watching cards.
struct LatestRow: View {
    let entries: [ProgressStore.Entry]
    /// Next episode to offer, by meta id, for series whose last played episode is finished.
    var upNext: [String: Video] = [:]
    /// Set by "Go to Details"; the owner registers the destination outside the lazy stack.
    @Binding var detailTarget: MetaPreview?
    var cardWidth: CGFloat = UIMetrics.landscapeWidth
    @Environment(ProgressStore.self) private var progress

    private struct Item: Identifiable {
        let entry: ProgressStore.Entry
        var id: String { entry.metaID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            RowHeader(title: "Continue Watching", subtitle: "Pick up where you left off")
                .padding(.horizontal, UIMetrics.pagePadding)
            PagedRow(items: entries.map(Item.init), itemWidth: cardWidth,
                     artHeight: cardWidth * 9 / 16) { item in
                NavigationLink(value: Route.detail(item.entry.detailPreview)) {
                    LatestCard(entry: item.entry, upNext: upNext[item.entry.metaID], width: cardWidth)
                }
                .buttonStyle(.dsPressable)
                .contextMenu {
                    Button {
                        detailTarget = item.entry.detailPreview
                    } label: {
                        Label("Go to Details", systemImage: "info.circle")
                    }
                    Divider()
                    Button(role: .destructive) {
                        withAnimation(Theme.Motion.appear) { progress.removeFromContinueWatching(metaID: item.entry.metaID) }
                    } label: {
                        Label("Remove from Continue Watching", systemImage: "eye.slash")
                    }
                }
            }
        }
    }
}

extension ProgressStore.Entry {
    var detailPreview: MetaPreview {
        MetaPreview(id: metaID, type: metaType, name: title, poster: posterURL)
    }
}

/// 16:9 backdrop card with a red progress bar along the art's bottom edge and the time remaining.
struct LatestCard: View {
    let entry: ProgressStore.Entry
    /// Shown instead of the entry's own episode when that one is finished.
    var upNext: Video? = nil
    var width: CGFloat = UIMetrics.landscapeWidth

    @Environment(AddonRegistry.self) private var registry
    @Environment(\.dsIsPressed) private var pressed
    @State private var hovering = false
    private var cache: ArtworkCache { .shared }

    private var artURL: URL? {
        entry.backgroundURL?.imageURL
            ?? cache.detail(entry.metaID)?.background?.imageURL
            ?? entry.posterURL?.imageURL
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s - 2) {
            art
                .scaleEffect(hovering ? 1.04 : 1)
                .shadow(color: .black.opacity(hovering ? 0.6 : 0.3), radius: hovering ? 18 : 6, y: hovering ? 10 : 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                if let episodeLine {
                    Text(episodeLine)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
                Label(remaining, systemImage: upNext == nil ? "clock" : "play.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary.opacity(0.88))
                    .labelStyle(RemainingLabelStyle())
                    .padding(.top, 1)
            }
            .padding(.horizontal, 2)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .zIndex(hovering ? 1 : 0)
        .onHover { h in withAnimation(Theme.Motion.hover) { hovering = h } }
        .task(id: entry.metaID) {
            if entry.backgroundURL?.imageURL == nil {
                await cache.load(type: entry.metaType, id: entry.metaID, registry: registry)
            }
        }
        .help("\(entry.title) — \(remaining)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([entry.title, episodeLine, remaining].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
    }

    private var remaining: String {
        if upNext != nil { return "Next episode" }
        return ProgressStore.remainingText(seconds: entry.seconds, duration: entry.duration) ?? "Resume"
    }

    private var episodeCode: String? { upNext.map { $0.episodeCode } ?? entry.episodeCode }

    private var episodeLine: String? {
        if let upNext {
            guard let code = upNext.episodeCode else { return upNext.displayTitle }
            return "\(code) · \(upNext.displayTitle)"
        }
        guard let code = entry.episodeCode else { return nil }
        guard let title = entry.episodeTitle, !title.isEmpty else { return code }
        return "\(code) · \(title)"
    }

    private var art: some View {
        RemoteImage(url: artURL, maxPixelSize: Int(width * 2.5)) {
            ArtworkPlaceholder(title: entry.title)
        }
        .frame(width: width, height: width * 9 / 16)
        .overlay {
            LinearGradient(stops: [.init(color: .clear, location: 0.55), .init(color: .black.opacity(0.65), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .overlay {
            ZStack {
                Color.black.opacity(0.3)
                Image(systemName: "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.black)
                    .offset(x: 2)
                    .frame(width: 52, height: 52)
                    .background(.white, in: Circle())
                    .shadow(color: .black.opacity(0.4), radius: 10)
                    .scaleEffect(hovering || pressed ? 1 : 0.8)
            }
            .opacity(hovering || pressed ? 1 : 0)
            .animation(Theme.Motion.press, value: pressed)
        }
        .overlay(alignment: .topLeading) {
            if let code = episodeCode {
                Text(code)
                    .font(Theme.Font.micro)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(Theme.Space.xs)
            }
        }
        .overlay(alignment: .bottom) {
            if upNext == nil { ProgressEdge(fraction: entry.fraction) }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(hovering ? 0.45 : 0.08), lineWidth: hovering ? 1.5 : 1))
    }
}

/// Square-ended bar flush with the bottom of the artwork (Netflix style).
private struct ProgressEdge: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.28))
                Rectangle().fill(Theme.Palette.progress)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 4)
        .accessibilityLabel("\(Int(fraction * 100)) percent watched")
    }
}

private struct RemainingLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(Theme.Palette.progress)
            configuration.title
        }
    }
}
