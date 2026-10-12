import Foundation

/// How text subtitles look; persisted in AppSettings and applied live by both engines.
struct SubtitleStyle: Codable, Hashable, Sendable {
    struct RGBA: Codable, Hashable, Sendable {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double = 1

        static let white = RGBA(red: 1, green: 1, blue: 1)
        static let black = RGBA(red: 0, green: 0, blue: 0)
        static let yellow = RGBA(red: 1, green: 0.88, blue: 0.2)
        static let lightGray = RGBA(red: 0.82, green: 0.82, blue: 0.82)
        static let cyan = RGBA(red: 0.35, green: 0.88, blue: 1)
        static let green = RGBA(red: 0.45, green: 0.95, blue: 0.45)
        static let darkGray = RGBA(red: 0.2, green: 0.2, blue: 0.2)
        static let navy = RGBA(red: 0.05, green: 0.1, blue: 0.3)

        /// mpv's unambiguous "r/g/b/a" color syntax (0...1 floats).
        var mpv: String {
            [red, green, blue, alpha].map { String(format: "%.3f", min(1, max(0, $0))) }.joined(separator: "/")
        }

        /// CoreMedia's text markup order.
        var argb: [Double] { [alpha, red, green, blue] }
    }

    /// Fonts installed on both macOS and iOS.
    enum Font: String, Codable, CaseIterable, Sendable {
        case system, helveticaNeue, avenirNext, futura, gillSans, verdana, arial, georgia, palatino, menlo

        /// Family name for libass (CoreText) and CoreMedia; nil uses the platform's default sans-serif.
        var familyName: String? {
            switch self {
            case .system: nil
            case .helveticaNeue: "Helvetica Neue"
            case .avenirNext: "Avenir Next"
            case .futura: "Futura"
            case .gillSans: "Gill Sans"
            case .verdana: "Verdana"
            case .arial: "Arial"
            case .georgia: "Georgia"
            case .palatino: "Palatino"
            case .menlo: "Menlo"
            }
        }

        var title: String { familyName ?? "System Default" }
    }

    static let sizeRange: ClosedRange<Double> = 0.5...2
    static let outlineRange: ClosedRange<Double> = 0...6
    static let elevationRange: ClosedRange<Double> = 0...0.4

    /// Multiplier on the engine's default size.
    var size: Double = 1
    var font: Font = .system
    var bold = false
    var textColor: RGBA = .white
    /// mpv units (scaled to a 720p canvas); 0 disables the outline.
    var outlineWidth: Double = 3
    var outlineColor: RGBA = .black
    var background = false
    var backgroundOpacity: Double = 0.6
    /// Fraction of the video height the subtitles are lifted above their default position.
    var elevation: Double = 0
    /// Also restyle subtitles that carry their own styling (ASS/SSA), which can break signs and typesetting.
    var overrideStyledSubtitles = false

    static let `default` = SubtitleStyle()

    var isDefault: Bool { self == .default }

    init() {}

    var backgroundColor: RGBA { RGBA(red: 0, green: 0, blue: 0, alpha: backgroundOpacity) }

    /// mpv property values; setting them at runtime restyles the subtitle on screen immediately.
    var mpvProperties: [(name: String, value: String)] {
        [
            ("sub-scale", String(format: "%.2f", size)),
            ("sub-font", font.familyName ?? "sans-serif"),
            ("sub-bold", bold ? "yes" : "no"),
            ("sub-color", textColor.mpv),
            ("sub-outline-color", outlineColor.mpv),
            ("sub-outline-size", String(format: "%.1f", outlineWidth)),
            ("sub-border-style", background ? "background-box" : "outline-and-shadow"),
            ("sub-back-color", background ? backgroundColor.mpv : RGBA(red: 0, green: 0, blue: 0, alpha: 0).mpv),
            ("sub-pos", String(Int((100 - elevation * 100).rounded()))),
            // "scale" still applies the size to styled subtitles without touching their look.
            ("sub-ass-override", overrideStyledSubtitles ? "force" : "scale"),
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case size, font, bold, textColor, outlineWidth, outlineColor, background, backgroundOpacity, elevation, overrideStyledSubtitles
    }

    /// Missing or unknown values fall back to defaults, so adding a field never resets the others.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SubtitleStyle.default
        size = (try? c.decodeIfPresent(Double.self, forKey: .size)).flatMap { $0 }.map { $0.clamped(to: Self.sizeRange) } ?? d.size
        font = (try? c.decodeIfPresent(Font.self, forKey: .font)).flatMap { $0 } ?? d.font
        bold = (try? c.decodeIfPresent(Bool.self, forKey: .bold)).flatMap { $0 } ?? d.bold
        textColor = (try? c.decodeIfPresent(RGBA.self, forKey: .textColor)).flatMap { $0 } ?? d.textColor
        outlineWidth = (try? c.decodeIfPresent(Double.self, forKey: .outlineWidth)).flatMap { $0 }.map { $0.clamped(to: Self.outlineRange) } ?? d.outlineWidth
        outlineColor = (try? c.decodeIfPresent(RGBA.self, forKey: .outlineColor)).flatMap { $0 } ?? d.outlineColor
        background = (try? c.decodeIfPresent(Bool.self, forKey: .background)).flatMap { $0 } ?? d.background
        backgroundOpacity = (try? c.decodeIfPresent(Double.self, forKey: .backgroundOpacity)).flatMap { $0 }.map { $0.clamped(to: 0...1) } ?? d.backgroundOpacity
        elevation = (try? c.decodeIfPresent(Double.self, forKey: .elevation)).flatMap { $0 }.map { $0.clamped(to: Self.elevationRange) } ?? d.elevation
        overrideStyledSubtitles = (try? c.decodeIfPresent(Bool.self, forKey: .overrideStyledSubtitles)).flatMap { $0 } ?? d.overrideStyledSubtitles
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { Swift.min(range.upperBound, Swift.max(range.lowerBound, self)) }
}
