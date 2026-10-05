import SwiftUI

/// Horizontal card row with smooth scrolling. On macOS, hovering the row reveals chevron buttons at
/// its edges that page by one screen width. `onReachEnd` fires when the last card appears (infinite paging).
struct PagedRow<Item: Identifiable, Card: View, Trailer: View>: View {
    let items: [Item]
    let itemWidth: CGFloat
    /// Height of the card artwork; the paging arrows span it.
    let artHeight: CGFloat
    var spacing: CGFloat = UIMetrics.rowSpacing
    var onReachEnd: (() -> Void)? = nil
    @ViewBuilder var card: (Item) -> Card
    @ViewBuilder var trailer: () -> Trailer

    @State private var position: Item.ID?
    @State private var viewport: CGFloat = 0
    @State private var hovering = false

    /// Vertical room so the hover zoom and shadow aren't clipped.
    private let verticalInset: CGFloat = Theme.Space.m

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: spacing) {
                ForEach(items) { item in
                    card(item)
                        .onAppear {
                            if item.id == items.last?.id { onReachEnd?() }
                        }
                }
                trailer()
            }
            .scrollTargetLayout()
            .padding(.vertical, verticalInset)
        }
        .contentMargins(.horizontal, UIMetrics.pagePadding, for: .scrollContent)
        .scrollIndicators(.never)
        .scrollPosition(id: $position, anchor: .leading)
        #if os(iOS)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
        #endif
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewport = $0 }
        #if os(macOS)
        .overlay(alignment: .topLeading) { arrow(forward: false) }
        .overlay(alignment: .topTrailing) { arrow(forward: true) }
        .onHover { h in withAnimation(Theme.Motion.appear) { hovering = h } }
        #endif
    }

    private var pageSize: Int {
        max(1, Int((viewport - 2 * UIMetrics.pagePadding + spacing) / (itemWidth + spacing)))
    }

    private var currentIndex: Int {
        guard let position else { return 0 }
        return items.firstIndex { $0.id == position } ?? 0
    }

    private var canGoBack: Bool { currentIndex > 0 }
    private var canGoForward: Bool { currentIndex + pageSize < items.count }

    private func page(forward: Bool) {
        guard !items.isEmpty else { return }
        let step = forward ? pageSize : -pageSize
        let target = min(max(0, currentIndex + step), items.count - 1)
        withAnimation(.smooth(duration: 0.55)) { position = items[target].id }
    }

    #if os(macOS)
    @ViewBuilder private func arrow(forward: Bool) -> some View {
        let enabled = forward ? canGoForward : canGoBack
        if hovering && enabled {
            RowPagingArrow(forward: forward) { page(forward: forward) }
                .frame(height: artHeight)
                .padding(.top, verticalInset)
                .transition(.opacity)
        }
    }
    #endif
}

extension PagedRow where Trailer == EmptyView {
    init(items: [Item], itemWidth: CGFloat, artHeight: CGFloat, spacing: CGFloat = UIMetrics.rowSpacing,
         onReachEnd: (() -> Void)? = nil, @ViewBuilder card: @escaping (Item) -> Card) {
        self.init(items: items, itemWidth: itemWidth, artHeight: artHeight, spacing: spacing,
                  onReachEnd: onReachEnd, card: card, trailer: { EmptyView() })
    }
}

/// Netflix-style edge strip with a chevron.
private struct RowPagingArrow: View {
    let forward: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                LinearGradient(colors: [Theme.Palette.canvas.opacity(0.92), Theme.Palette.canvas.opacity(0)],
                               startPoint: forward ? .trailing : .leading, endPoint: forward ? .leading : .trailing)
                Image(systemName: forward ? "chevron.right" : "chevron.left")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 6)
                    .scaleEffect(hovering ? 1.25 : 1)
            }
            .frame(width: 56)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Theme.Motion.hover) { hovering = h } }
        .help(forward ? "Next" : "Previous")
        .accessibilityLabel(forward ? "Scroll forward" : "Scroll back")
    }
}

/// Card sizing for horizontal rows. On a phone the poster width is derived from the screen so ~3⅓ cards
/// fit and the next one peeks in; elsewhere the fixed `UIMetrics` sizes apply.
enum BrowseLayout {
    static func posterWidth(viewport: CGFloat) -> CGFloat {
        #if os(iOS)
        guard viewport > 0, viewport < 600 else { return UIMetrics.posterWidth }
        let available = viewport - UIMetrics.pagePadding - 3 * UIMetrics.rowSpacing
        return (available / 3.3).rounded(.down)
        #else
        return UIMetrics.posterWidth
        #endif
    }

    /// Poster grid (search results, Discover): exactly three posters per row on phones, filling the width;
    /// fixed-size adaptive columns elsewhere.
    struct Grid {
        let columns: [GridItem]
        let posterWidth: CGFloat
        let spacing: CGFloat
    }

    static func grid(viewport: CGFloat) -> Grid {
        #if os(iOS)
        if viewport > 0 && viewport < 600 {
            let n = 3
            let spacing = Theme.Space.s
            let available = viewport - 2 * UIMetrics.pagePadding - CGFloat(n - 1) * spacing
            let width = (available / CGFloat(n)).rounded(.down)
            return Grid(columns: Array(repeating: GridItem(.fixed(width), spacing: spacing, alignment: .top), count: n),
                        posterWidth: width, spacing: spacing)
        }
        #endif
        let spacing = Theme.Space.m
        return Grid(columns: [GridItem(.adaptive(minimum: UIMetrics.posterWidth, maximum: UIMetrics.posterWidth),
                                       spacing: spacing, alignment: .top)],
                    posterWidth: UIMetrics.posterWidth, spacing: spacing)
    }

    static func landscapeWidth(viewport: CGFloat) -> CGFloat {
        #if os(iOS)
        guard viewport > 0, viewport < 600 else { return UIMetrics.landscapeWidth }
        let available = viewport - UIMetrics.pagePadding - UIMetrics.rowSpacing
        return min(UIMetrics.landscapeWidth, (available / 1.42).rounded(.down))
        #else
        return UIMetrics.landscapeWidth
        #endif
    }
}

/// Darkens the status bar (and navigation bar, if shown) area so scrolled content doesn't clash with it.
/// Place at the top of a ZStack that respects the safe area.
struct TopBarScrim: View {
    var fadeBelow: CGFloat = 12

    var body: some View {
        Color.clear
            .frame(height: fadeBelow)
            .background {
                LinearGradient(stops: [.init(color: Theme.Palette.canvas.opacity(0.9), location: 0),
                                       .init(color: Theme.Palette.canvas.opacity(0.65), location: 0.6),
                                       .init(color: Theme.Palette.canvas.opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(edges: .top)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
