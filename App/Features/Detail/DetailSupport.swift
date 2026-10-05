import SwiftUI

/// Streams per video id, shared by the hero Play button and the stream lists so each id is fetched once.
@MainActor @Observable
final class StreamCache {
    struct Result {
        var streams: [AddonStream] = []
        var errors: [String] = []
        var isLoading = false
        var hasLoaded = false
    }

    private(set) var results: [String: Result] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    func result(for id: String) -> Result { results[id] ?? Result() }

    /// Loads streams for `id`, joining a request that is already in flight unless `force` is set.
    func load(registry: AddonRegistry, type: String, id: String, force: Bool = false) async {
        if !force, let running = tasks[id] { return await running.value }
        if !force, results[id]?.hasLoaded == true { return }
        results[id, default: Result()].isLoading = true
        let task = Task { @MainActor in
            let fetched = await registry.streams(type: type, id: id)
            var seen = Set<String>()
            results[id] = Result(streams: fetched.streams.filter { seen.insert($0.id).inserted },
                                 errors: fetched.errors, isLoading: false, hasLoaded: true)
        }
        tasks[id] = task
        await task.value
        if tasks[id] == task { tasks[id] = nil }
    }

    /// The stream the big Play / Download buttons use: the first cached (⚡) stream with a playable link, in addon
    /// order, preferring `quality` (the stream list's filter) when one of that quality exists.
    func best(for id: String, preferring quality: StreamQuality? = nil) -> AddonStream? {
        Self.best(in: results[id]?.streams ?? [], preferring: quality)
    }

    nonisolated static func best(in streams: [AddonStream], preferring quality: StreamQuality?) -> AddonStream? {
        let candidates = streams.filter { $0.stream.isCached && $0.stream.playableURL != nil }
        if let quality, let match = candidates.first(where: { $0.stream.quality == quality }) { return match }
        return candidates.first
    }
}

enum DetailPlayback {
    static func request(meta: MetaDetail, video: Video?, item: AddonStream, startAt: Double? = nil) -> PlaybackRequest? {
        guard let url = item.stream.playableURL else { return nil }
        return PlaybackRequest(
            url: url,
            title: meta.name,
            subtitle: video.map(episodeSubtitle),
            metaID: meta.id,
            metaType: meta.type,
            videoId: video?.id ?? meta.id,
            isLocal: false,
            filenameHint: item.stream.filename,
            posterURL: meta.poster,
            bingeGroup: item.stream.behaviorHints?.bingeGroup,
            backgroundURL: meta.background ?? video?.thumbnail,
            startAt: startAt
        )
    }

    /// "S01E03 · Title"
    static func episodeSubtitle(_ video: Video) -> String {
        [video.episodeCode, video.displayTitle].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Saved / queued state of a video, for download buttons.
enum DownloadBadgeState {
    case saved, queued

    @MainActor static func of(_ videoId: String, library: LibraryStore, downloads: DownloadManager) -> DownloadBadgeState? {
        if library.isSaved(videoId: videoId) { return .saved }
        if downloads.items.contains(where: { $0.videoId == videoId && $0.state != .failed && $0.state != .completed }) { return .queued }
        return downloads.items.contains(where: { $0.videoId == videoId && $0.state == .completed }) ? .saved : nil
    }
}

enum DetailFormat {
    /// "49 min", "2h 16min", "136", "1 h 5 min" → seconds.
    static func runtimeSeconds(_ runtime: String?) -> Double? {
        guard let runtime = runtime?.lowercased(), !runtime.isEmpty else { return nil }
        var minutes = 0.0
        var matched = false
        if let h = firstNumber(in: runtime, before: "h") { minutes += h * 60; matched = true }
        if let m = firstNumber(in: runtime, before: "m") { minutes += m; matched = true }
        if !matched, let n = Double(runtime.trimmingCharacters(in: .whitespaces)) { minutes = n; matched = true }
        return matched && minutes > 0 ? minutes * 60 : nil
    }

    private static func firstNumber(in s: String, before unit: String) -> Double? {
        guard let r = s.range(of: #"(\d+(?:\.\d+)?)\s*"# + unit, options: .regularExpression) else { return nil }
        let digits = s[r].prefix { $0.isNumber || $0 == "." }
        return Double(digits)
    }

    /// "52 min", "1 h 4 min"
    static func duration(_ seconds: Double) -> String {
        let total = Int((seconds / 60).rounded())
        let h = total / 60, m = total % 60
        if h == 0 { return "\(max(1, m)) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    static func isUpcoming(_ video: Video) -> Bool {
        guard let date = DisplayFormat.parseDate(video.released) else { return false }
        return date > .now
    }
}

/// Which episode the series Play button targets.
struct NextUp {
    var video: Video
    var entry: ProgressStore.Entry?
    /// True when every episode has been watched and we're offering a rewatch.
    var isRewatch = false

    var isInProgress: Bool {
        guard let entry, !entry.isFinished else { return false }
        return entry.seconds > ProgressStore.minimumResumeSeconds
    }

    /// The most recently touched episode if unfinished, else the one after the last watched one, else the first.
    @MainActor static func resolve(meta: MetaDetail, progress: ProgressStore) -> NextUp? {
        let all = meta.videos ?? []
        let regular = all.filter { ($0.season ?? 1) > 0 }
        let ordered = (regular.isEmpty ? all : regular).sorted {
            ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0)
        }
        guard let first = ordered.first else { return nil }
        let entries = progress.entries(forMeta: meta.id)
        guard let latest = entries.values
            .filter({ e in ordered.contains { $0.id == e.videoId } })
            .max(by: { $0.updatedAt < $1.updatedAt }),
              let index = ordered.firstIndex(where: { $0.id == latest.videoId })
        else { return NextUp(video: first, entry: entries[first.id]) }

        if !latest.isFinished { return NextUp(video: ordered[index], entry: latest) }
        if let next = ordered[(index + 1)...].first(where: { !(entries[$0.id]?.isFinished ?? false) }) {
            return NextUp(video: next, entry: entries[next.id])
        }
        return NextUp(video: first, entry: nil, isRewatch: true)
    }
}

// MARK: - Stream quality filter

/// The stream list's quality filter, remembered across titles. `nil` shows every quality.
@propertyWrapper
struct StreamQualityPreference: DynamicProperty {
    @AppStorage("streams.quality") private var raw = ""

    var wrappedValue: StreamQuality? {
        get { StreamQuality(rawValue: raw) }
        nonmutating set { raw = newValue?.rawValue ?? "" }
    }

    var projectedValue: Binding<StreamQuality?> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}

// MARK: - Stream quality tags

struct StreamTags {
    var resolution: String?
    var hdr: [String] = []
    var codec: String?
    var audio: [String] = []
    var source: String?
    var size: String?

    init(_ item: AddonStream) {
        let stream = item.stream
        let text = [stream.name, stream.details, stream.filename].compactMap { $0 }.joined(separator: " ")
        func has(_ pattern: String) -> Bool {
            text.range(of: #"(^|[^a-z0-9])(?:"# + pattern + #")([^a-z0-9]|$)"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        let quality = stream.quality
        resolution = quality == .unknown ? nil : quality.label

        if has("dv|dovi|dolby[ .]?vision") { hdr.append("DV") }
        if has(#"hdr10\+|hdr10plus"#) { hdr.append("HDR10+") }
        else if has("hdr|hdr10") { hdr.append("HDR") }

        if has("x265|h[ .]?265|hevc") { codec = "HEVC" }
        else if has("av1") { codec = "AV1" }

        if has("atmos") { audio.append("Atmos") }
        if has("truehd") { audio.append("TrueHD") }
        else if has("dts[-. ]?hd|dts[-:]?x|dts") { audio.append("DTS") }
        if has(#"7\.1"#) { audio.append("7.1") } else if has(#"5\.1"#) { audio.append("5.1") }

        if has("remux") { source = "REMUX" }
        else if has("blu[-. ]?ray|bdrip|brrip") { source = "BluRay" }
        else if has(#"web[-. ]?dl|webrip|web"#) { source = "WEB" }

        // The size the addon prints first, so the badge matches the card's detail line (addons often mean GiB).
        if let r = stream.details.range(of: #"\d+(?:[.,]\d+)?\s?(?:GB|MB|GiB|MiB)"#, options: [.regularExpression, .caseInsensitive]) {
            size = String(stream.details[r])
        } else if let bytes = stream.behaviorHints?.videoSize, bytes > 0 {
            size = DisplayFormat.bytes(bytes)
        }
    }

    var isPremium: Bool { resolution == "4K" || !hdr.isEmpty }
}

// MARK: - Small shared views

extension EnvironmentValues {
    /// Set by the phone hero: secondary action buttons share the row width equally.
    @Entry var detailActionsStacked = false
}

/// Round icon button used next to the big Play button and on stream cards. Its hit area meets the platform minimum.
struct DetailIconButton: View {
    var systemImage: String
    /// Short label under the circle (Netflix-style "My List"), so similar icons stay distinguishable.
    var caption: String? = nil
    var help: String
    var isOn = false
    var size: CGFloat = 44
    var action: () -> Void
    @Environment(\.detailActionsStacked) private var stacked
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(isOn ? Theme.Palette.success : Theme.Palette.textPrimary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color.white.opacity(hovering ? 0.22 : 0.12)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(hovering ? 0.5 : 0.28), lineWidth: 1.5))
                    .scaleEffect(hovering ? 1.06 : 1)
                    .animation(Theme.Motion.hover, value: hovering)
                if let caption {
                    Text(caption)
                        .font(Theme.Font.micro)
                        .foregroundStyle(hovering ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(minWidth: Theme.Control.minHitTarget, maxWidth: stacked ? .infinity : nil, minHeight: Theme.Control.minHitTarget)
            .contentShape(Rectangle())
            .opacity(isEnabled || isOn ? 1 : 0.4)
        }
        .buttonStyle(DSPressableStyle(scale: 0.92))
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Surface card with a hover highlight, used for episode rows and stream rows.
struct DetailCardBackground: ViewModifier {
    var highlighted = false
    var padding: CGFloat = Theme.Space.s
    @Environment(\.dsIsPressed) private var pressed
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
                    .fill(hovering || pressed ? Theme.Palette.surfaceHigh : (highlighted ? Theme.Palette.surface : Theme.Palette.surface.opacity(0.55)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
                    .strokeBorder(highlighted ? Theme.Palette.accent.opacity(0.55) : Theme.Palette.stroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func detailCard(highlighted: Bool = false, padding: CGFloat = Theme.Space.s) -> some View {
        modifier(DetailCardBackground(highlighted: highlighted, padding: padding))
    }
}

/// Wrapping horizontal layout for badge rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row(indices: [i], width: size.width, height: size.height))
            } else {
                rows[rows.count - 1].indices.append(i)
                rows[rows.count - 1].width = needed
                rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            }
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
