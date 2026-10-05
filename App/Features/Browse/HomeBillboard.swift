import SwiftUI
import Observation

/// Full meta (backdrop, logo, genres) for titles shown in the billboard and Latest cards, fetched once per id.
@MainActor @Observable
final class ArtworkCache {
    static let shared = ArtworkCache()

    private(set) var details: [String: MetaDetail] = [:]
    /// Callers asking for an id that's already being fetched wait for that fetch instead of returning early.
    @ObservationIgnored private var inFlight: [String: Task<Void, Never>] = [:]

    func detail(_ id: String) -> MetaDetail? { details[id] }

    func load(type: String, id: String, registry: AddonRegistry) async {
        guard details[id] == nil else { return }
        if let pending = inFlight[id] { return await pending.value }
        let task = Task {
            if let detail = try? await registry.meta(type: type, id: id) { details[id] = detail }
            inFlight[id] = nil
        }
        inFlight[id] = task
        await task.value
    }
}

/// Netflix-style billboard: rotating backdrop with scrims, logo or title, metadata and actions.
/// On a phone the art sits at the top and the info is centered below it. Slides can be swiped (touch,
/// mouse drag or trackpad).
struct HomeBillboard: View {
    let candidates: [MetaPreview]
    /// Set once every candidate's meta has been tried and none has a backdrop to show.
    @Binding var isUnavailable: Bool
    @Environment(AddonRegistry.self) private var registry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var index = 0
    @State private var paused = false
    /// Bumped on manual navigation so the auto-advance timer restarts.
    @State private var interaction = 0
    private var cache: ArtworkCache { .shared }

    private struct Slide {
        let preview: MetaPreview
        let detail: MetaDetail
        var id: String { preview.id }
    }

    private var isPhone: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    /// iPad keeps the drag to subviews; phone and Mac (mouse drag) page from anywhere on the billboard.
    private var swipesOnBackground: Bool {
        #if os(macOS)
        true
        #else
        isPhone
        #endif
    }

    private var slides: [Slide] {
        candidates.compactMap { p in
            guard let d = cache.detail(p.id), d.background?.imageURL != nil else { return nil }
            return Slide(preview: p, detail: d)
        }
    }

    var body: some View {
        let slides = slides
        let current = slides.isEmpty ? nil : slides[index % slides.count]
        ZStack(alignment: .bottomLeading) {
            if let current {
                backdrop(current.detail)
                    .id(current.id)
                    .transition(.opacity)
                scrims
                info(current, count: slides.count)
                    .id("info-" + current.id)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
                if slides.count > 1 && !isPhone {
                    pager(count: slides.count, selected: index % slides.count)
                        .padding(.horizontal, UIMetrics.pagePadding)
                        .padding(.bottom, UIMetrics.billboardOverlap + Theme.Space.xl)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                skeleton
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .containerRelativeFrame(.vertical) { h, _ in height(for: h) }
        .clipped()
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.45), value: current == nil)
        .onHover { paused = $0 }
        .simultaneousGesture(swipe(count: slides.count), including: swipesOnBackground ? .all : .subviews)
        #if os(macOS)
        .onHorizontalScrollSwipe { forward in
            show(index % max(slides.count, 1) + (forward ? 1 : -1), count: slides.count > 1 ? slides.count : 0)
        }
        #endif
        .task(id: candidates.map(\.id)) {
            let cache = cache, registry = registry, candidates = candidates
            await withTaskGroup(of: Void.self) { group in
                for p in candidates {
                    group.addTask { await cache.load(type: p.type, id: p.id, registry: registry) }
                }
            }
            guard !Task.isCancelled, !candidates.isEmpty else { return }
            // `self.slides`, not body's `slides` snapshot taken before these loads finished.
            if self.slides.isEmpty { isUnavailable = true }
        }
        .task(id: "\(slides.count)-\(interaction)") {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                // Content that moves on its own is disorienting with Reduce Motion or VoiceOver.
                if !paused, !reduceMotion, !voiceOver, slides.count > 1 {
                    withAnimation(.easeInOut(duration: 1.0)) { index = (index + 1) % slides.count }
                }
            }
        }
    }

    private func height(for container: CGFloat) -> CGFloat {
        #if os(macOS)
        min(max(container * 0.74, 440), 720)
        #else
        isPhone ? min(max(container * 0.68, 470), 620) : min(max(container * 0.62, 380), 560)
        #endif
    }

    private func show(_ i: Int, count: Int) {
        guard count > 0 else { return }
        withAnimation(.easeInOut(duration: 0.5)) { index = (i + count) % count }
        interaction += 1
    }

    private func swipe(count: Int) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width
                guard count > 1, abs(dx) > 50, abs(dx) > abs(value.translation.height) * 1.5 else { return }
                show(index % count + (dx < 0 ? 1 : -1), count: count)
            }
    }

    @ViewBuilder private func backdrop(_ detail: MetaDetail) -> some View {
        let image = RemoteImage(url: detail.background?.imageURL, maxPixelSize: 2400) { Theme.Palette.surface }
        if isPhone {
            VStack(spacing: 0) {
                Color.clear
                    .aspectRatio(0.92, contentMode: .fit)
                    .overlay { image }
                    .clipped()
                Spacer(minLength: 0)
            }
        } else {
            Color.clear.overlay(alignment: .top) { image }
                .clipped()
        }
    }

    @ViewBuilder private var scrims: some View {
        if isPhone {
            ZStack {
                LinearGradient(stops: [.init(color: .clear, location: 0.3),
                                       .init(color: Theme.Palette.canvas.opacity(0.8), location: 0.58),
                                       .init(color: Theme.Palette.canvas, location: 0.8)],
                               startPoint: .top, endPoint: .bottom)
                LinearGradient(stops: [.init(color: .black.opacity(0.5), location: 0), .init(color: .clear, location: 0.18)],
                               startPoint: .top, endPoint: .bottom)
            }
            .allowsHitTesting(false)
        } else {
            ZStack {
                LinearGradient(stops: [.init(color: Theme.Palette.canvas.opacity(0.94), location: 0),
                                       .init(color: Theme.Palette.canvas.opacity(0.6), location: 0.32),
                                       .init(color: .clear, location: 0.68)],
                               startPoint: .leading, endPoint: .trailing)
                LinearGradient(stops: [.init(color: .clear, location: 0.45),
                                       .init(color: Theme.Palette.canvas.opacity(0.75), location: 0.82),
                                       .init(color: Theme.Palette.canvas, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .clear, location: 0.22)],
                               startPoint: .top, endPoint: .bottom)
            }
            .allowsHitTesting(false)
        }
    }

    private func info(_ slide: Slide, count: Int) -> some View {
        let d = slide.detail
        let alignment: HorizontalAlignment = isPhone ? .center : .leading
        return VStack(alignment: alignment, spacing: isPhone ? Theme.Space.s : Theme.Space.m) {
            titleArt(d)
            metaLine(d)
            if let text = d.description ?? slide.preview.description, !text.isEmpty {
                Text(text)
                    .font(.system(size: isPhone ? 14 : 15, weight: .regular))
                    .foregroundStyle(Theme.Palette.textPrimary.opacity(isPhone ? 0.75 : 0.86))
                    .multilineTextAlignment(isPhone ? .center : .leading)
                    .lineLimit(isPhone ? 2 : 3)
                    .lineSpacing(2)
                    .shadow(color: .black.opacity(0.5), radius: 4)
            }
            HStack(spacing: Theme.Space.s) {
                NavigationLink(value: Route.detail(slide.preview)) {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.ds(.primary, fullWidth: isPhone))
                NavigationLink(value: Route.detail(slide.preview)) {
                    Label("More Info", systemImage: "info.circle")
                }
                .buttonStyle(.ds(.secondary, fullWidth: isPhone))
            }
            .padding(.top, Theme.Space.xxs)
            if isPhone && count > 1 {
                pager(count: count, selected: index % count)
            }
        }
        .frame(maxWidth: isPhone ? .infinity : 540, alignment: Alignment(horizontal: alignment, vertical: .center))
        .padding(.horizontal, UIMetrics.pagePadding)
        .padding(.bottom, UIMetrics.billboardOverlap + (isPhone ? Theme.Space.l : Theme.Space.xl))
    }

    private func titleArt(_ d: MetaDetail) -> some View {
        let alignment: Alignment = isPhone ? .bottom : .bottomLeading
        return RemoteImage(url: d.logo?.imageURL, maxPixelSize: 1200, contentMode: .fit, lightensDarkCutouts: true) {
            Text(d.name)
                .font(isPhone ? .system(size: 34, weight: .heavy) : Theme.Font.display)
                .foregroundStyle(Theme.Palette.textPrimary)
                .multilineTextAlignment(isPhone ? .center : .leading)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .shadow(color: .black.opacity(0.5), radius: 8)
                .frame(maxWidth: .infinity, alignment: alignment)
        }
        .frame(maxWidth: isPhone ? 270 : 420, maxHeight: isPhone ? 96 : 130, alignment: alignment)
        .shadow(color: .black.opacity(0.45), radius: 10)
        .accessibilityLabel(d.name)
    }

    private func metaLine(_ d: MetaDetail) -> some View {
        HStack(spacing: isPhone ? Theme.Space.xs : Theme.Space.s) {
            Badge(text: DisplayFormat.singularTypeLabel(d.type).uppercased(), tint: Theme.Palette.accent)
            if let rating = DisplayFormat.rating(d.imdbRating) {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill").foregroundStyle(Theme.Palette.warning)
                    Text(rating)
                }
            }
            if let year = d.displayYear, !year.isEmpty { Text(year) }
            if let runtime = d.runtime, !runtime.isEmpty { Text(runtime) }
            if !d.allGenres.isEmpty {
                Text(d.allGenres.prefix(isPhone ? 2 : 3).joined(separator: " • "))
                    .lineLimit(1)
            }
        }
        .font(isPhone ? .system(size: 13, weight: .semibold) : Theme.Font.headline)
        .lineLimit(1)
        .foregroundStyle(Theme.Palette.textPrimary.opacity(0.9))
        .shadow(color: .black.opacity(0.5), radius: 4)
    }

    private func pager(count: Int, selected: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Button {
                    show(i, count: count)
                } label: {
                    Capsule()
                        .fill(.white.opacity(i == selected ? 0.95 : 0.3))
                        .frame(width: i == selected ? 22 : 7, height: 7)
                        .padding(.vertical, isPhone ? 10 : 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show title \(i + 1) of \(count)")
            }
        }
        .animation(Theme.Motion.content, value: selected)
    }

    private var skeleton: some View {
        #if os(macOS)
        let w: CGFloat = 480
        #else
        let w: CGFloat = 300
        #endif
        let alignment: HorizontalAlignment = isPhone ? .center : .leading
        return ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Theme.Palette.surface.opacity(0.6), Theme.Palette.canvas], startPoint: .top, endPoint: .bottom)
                .skeletonShimmer()
            VStack(alignment: alignment, spacing: Theme.Space.m) {
                SkeletonBlock(width: w * 0.7, height: 64, cornerRadius: Theme.Radius.s)
                SkeletonBlock(width: w * 0.55, height: 14, cornerRadius: 3)
                VStack(alignment: alignment, spacing: 6) {
                    SkeletonBlock(width: w, height: 11, cornerRadius: 3)
                    SkeletonBlock(width: w * 0.88, height: 11, cornerRadius: 3)
                }
                HStack(spacing: Theme.Space.s) {
                    if isPhone {
                        SkeletonBlock(height: Theme.Control.height, cornerRadius: Theme.Control.radius)
                        SkeletonBlock(height: Theme.Control.height, cornerRadius: Theme.Control.radius)
                    } else {
                        SkeletonBlock(width: 110, height: Theme.Control.height, cornerRadius: Theme.Control.radius)
                        SkeletonBlock(width: 140, height: Theme.Control.height, cornerRadius: Theme.Control.radius)
                    }
                }
            }
            .frame(maxWidth: isPhone ? .infinity : nil, alignment: Alignment(horizontal: alignment, vertical: .center))
            .padding(.horizontal, UIMetrics.pagePadding)
            .padding(.bottom, UIMetrics.billboardOverlap + (isPhone ? Theme.Space.l : Theme.Space.xl))
        }
        .accessibilityLabel("Loading")
    }
}
