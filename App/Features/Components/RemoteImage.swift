import SwiftUI
import ImageIO

/// A decoded, downsampled image. Wrapped so it can cross actor boundaries.
final class LoadedImage: @unchecked Sendable {
    let cgImage: CGImage
    /// True for mostly-transparent artwork whose visible pixels are dark (e.g. black title logos),
    /// which disappears on the app's dark backdrops.
    let isDarkCutout: Bool

    init(_ cgImage: CGImage) {
        self.cgImage = cgImage
        isDarkCutout = Self.isDarkCutout(cgImage)
    }

    private static func isDarkCutout(_ image: CGImage) -> Bool {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst, image.alphaInfo != .noneSkipLast else { return false }
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return false }
        var alphaSum = 0.0, lumaSum = 0.0, transparent = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            if a < 0.1 { transparent += 1; continue }
            // Premultiplied: dividing by alpha recovers the colour; weighting by alpha cancels that out.
            lumaSum += (0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])) / 255
            alphaSum += a
        }
        guard alphaSum > 0, Double(transparent) / Double(side * side) > 0.2 else { return false }
        return lumaSum / alphaSum < 0.3
    }
}

/// Loads remote (or file) images through a disk-backed URLCache, downsamples them off the main thread,
/// and keeps decoded results in memory so scrolling back never flickers.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private let memory = NSCache<NSString, LoadedImage>()
    private let session: URLSession

    init() {
        memory.countLimit = 500
        memory.totalCostLimit = 256 * 1024 * 1024
        let config = URLSessionConfiguration.default
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ImageCache", isDirectory: true)
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 512 << 20, directory: dir)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    private func key(_ url: URL, _ maxPixelSize: Int) -> NSString { "\(maxPixelSize)|\(url.absoluteString)" as NSString }

    func cached(_ url: URL, maxPixelSize: Int) -> LoadedImage? {
        memory.object(forKey: key(url, maxPixelSize))
    }

    func image(for url: URL, maxPixelSize: Int) async throws -> LoadedImage {
        if let hit = cached(url, maxPixelSize: maxPixelSize) { return hit }
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            let (d, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            data = d
        }
        try Task.checkCancellation()
        guard let cg = Self.downsample(data, maxPixelSize: maxPixelSize) else { throw URLError(.cannotDecodeContentData) }
        let image = LoadedImage(cg)
        memory.setObject(image, forKey: key(url, maxPixelSize), cost: cg.bytesPerRow * cg.height)
        return image
    }

    private static func downsample(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Cached remote image. The caller sizes and clips it; `placeholder` shows while loading and on failure.
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    var maxPixelSize: Int = 600
    var contentMode: ContentMode = .fill
    /// Draws dark transparent artwork (title logos) in white so it stays legible on dark backdrops.
    var lightensDarkCutouts = false
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var loaded: (url: URL, image: LoadedImage)?

    init(url: URL?, maxPixelSize: Int = 600, contentMode: ContentMode = .fill, lightensDarkCutouts: Bool = false,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.maxPixelSize = maxPixelSize
        self.contentMode = contentMode
        self.lightensDarkCutouts = lightensDarkCutouts
        self.placeholder = placeholder
    }

    private var current: LoadedImage? {
        guard let url else { return nil }
        if let loaded, loaded.url == url { return loaded.image }
        return ImagePipeline.shared.cached(url, maxPixelSize: maxPixelSize)
    }

    var body: some View {
        ZStack {
            if let current {
                Image(decorative: current.cgImage, scale: 1)
                    .renderingMode(lightensDarkCutouts && current.isDarkCutout ? .template : .original)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .transition(.opacity)
            } else {
                // Stays underneath until the artwork has faded in, so the cross-fade never dips to black.
                placeholder()
                    .transition(.asymmetric(insertion: .identity,
                                            removal: .opacity.animation(.linear(duration: 0.12).delay(0.28))))
            }
        }
        .task(id: url) {
            guard let url, current == nil else { return }
            if let image = try? await ImagePipeline.shared.image(for: url, maxPixelSize: maxPixelSize) {
                withAnimation(Theme.Motion.imageFade) { loaded = (url, image) }
            }
        }
    }
}

extension RemoteImage where Placeholder == Color {
    init(url: URL?, maxPixelSize: Int = 600, contentMode: ContentMode = .fill) {
        self.init(url: url, maxPixelSize: maxPixelSize, contentMode: contentMode) { Theme.Palette.surface }
    }
}

extension String {
    /// http(s)/file URL from an addon-supplied string, or nil.
    var imageURL: URL? {
        guard let u = URL(string: self), let scheme = u.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else { return nil }
        return u
    }
}
