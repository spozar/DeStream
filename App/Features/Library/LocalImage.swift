import SwiftUI
import ImageIO

/// Displays an image from a local file (decoded and downsampled off the main thread). No network.
/// OWNER: Agent 5 (Library).
struct LocalImage<Placeholder: View>: View {
    let url: URL?
    var maxPixelSize: Int = 800
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: CGImage?

    init(url: URL?, maxPixelSize: Int = 800, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.maxPixelSize = maxPixelSize
        self.placeholder = placeholder
        _image = State(initialValue: LocalImageLoader.recent(url, maxPixelSize: maxPixelSize))
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().transition(.opacity)
            } else {
                placeholder().transition(.opacity)
            }
        }
        .task(id: url) {
            let loaded = await LocalImageLoader.load(url, maxPixelSize: maxPixelSize)
            guard loaded !== image else { return }
            withAnimation(image == nil ? Theme.Motion.imageFade : nil) { image = loaded }
        }
    }
}

enum LocalImageLoader {
    @MainActor private static var cache: [String: CGImage] = [:]
    /// Last decoded image per file and size, so re-created views show it immediately instead of flashing the placeholder.
    @MainActor private static var latest: [String: CGImage] = [:]

    @MainActor
    static func recent(_ url: URL?, maxPixelSize: Int) -> CGImage? {
        url.flatMap { latest["\($0.path)|\(maxPixelSize)"] }
    }

    @MainActor
    static func load(_ url: URL?, maxPixelSize: Int) async -> CGImage? {
        guard let url else { return nil }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(mtime)|\(maxPixelSize)"
        if let cached = cache[key] {
            latest["\(url.path)|\(maxPixelSize)"] = cached
            return cached
        }
        let image = await Task.detached(priority: .utility) { decode(url, maxPixelSize: maxPixelSize) }.value
        if let image {
            cache[key] = image
            latest["\(url.path)|\(maxPixelSize)"] = image
        }
        return image
    }

    nonisolated static func decode(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
