import Foundation

struct Stream: Codable, Hashable, Sendable {
    var url: String?
    var ytId: String?
    var infoHash: String?
    var fileIdx: Int?
    var externalUrl: String?
    var name: String?
    var title: String?
    var description: String?
    var behaviorHints: StreamBehaviorHints?

    /// Stremio's newer addons use `description`, older ones `title`.
    var details: String { description ?? title ?? "" }

    /// Only http(s) URLs are playable/downloadable; addon responses are untrusted.
    var playableURL: URL? {
        guard let url, let u = URL(string: url), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return u
    }

    var filename: String? { behaviorHints?.filename }

    /// Debrid addons mark cached results with ⚡ (Comet/Torrentio) or "+" in the name.
    var isCached: Bool {
        let n = (name ?? "") + " " + (title ?? "")
        if n.contains("⚡") { return true }
        if n.contains("⬇") || n.lowercased().contains("download") { return false }
        return n.contains("+]") || n.contains("[TB+") || n.contains("[RD+")
    }

    /// Best-effort container sniffing; AVPlayer can only play mp4/mov/m4v/m3u8 natively.
    var containerExtension: String? {
        let candidates = [behaviorHints?.filename, url.flatMap { URL(string: $0)?.lastPathComponent }]
        for c in candidates.compactMap({ $0 }) {
            let ext = (c as NSString).pathExtension.lowercased()
            if !ext.isEmpty, ext.count <= 4 { return ext }
        }
        return nil
    }
}

extension Stream {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = c.decodeLossyString(forKey: .url)
        ytId = c.decodeLossyString(forKey: .ytId)
        infoHash = c.decodeLossyString(forKey: .infoHash)
        fileIdx = try c.decodeLossyInt(forKey: .fileIdx)
        externalUrl = c.decodeLossyString(forKey: .externalUrl)
        name = c.decodeLossyString(forKey: .name)
        title = c.decodeLossyString(forKey: .title)
        description = c.decodeLossyString(forKey: .description)
        behaviorHints = try? c.decodeIfPresent(StreamBehaviorHints.self, forKey: .behaviorHints)
        if url == nil, infoHash == nil, ytId == nil, externalUrl == nil {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "stream has no source"))
        }
    }
}

extension StreamBehaviorHints {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filename = c.decodeLossyString(forKey: .filename)
        notWebReady = try? c.decodeIfPresent(Bool.self, forKey: .notWebReady)
        bingeGroup = c.decodeLossyString(forKey: .bingeGroup)
        videoSize = (try? c.decodeLossyInt(forKey: .videoSize)).map(Int64.init)
        videoHash = c.decodeLossyString(forKey: .videoHash)
        proxyHeaders = try? c.decodeIfPresent(ProxyHeaders.self, forKey: .proxyHeaders)
    }
}

struct StreamBehaviorHints: Codable, Hashable, Sendable {
    var filename: String?
    var notWebReady: Bool?
    var bingeGroup: String?
    var videoSize: Int64?
    var videoHash: String?
    var proxyHeaders: ProxyHeaders?

    struct ProxyHeaders: Codable, Hashable, Sendable {
        var request: [String: String]?
        var response: [String: String]?
    }
}

/// A stream tagged with the addon it came from, as shown in the merged stream list.
struct AddonStream: Hashable, Sendable, Identifiable {
    var id: String
    var addonName: String
    /// `Addon.id.uuidString` of the source addon; resolve with `AddonRegistry.addon(withID:)`.
    var addonID: String
    var stream: Stream
}

/// Resolution bucket of a stream, best first.
enum StreamQuality: String, CaseIterable, Codable, Comparable, Sendable {
    case uhd = "4k", fhd = "1080p", hd = "720p", sd, unknown

    var label: String {
        switch self {
        case .uhd: "4K"
        case .fhd: "1080p"
        case .hd: "720p"
        case .sd: "SD"
        case .unknown: "Other"
        }
    }

    static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    /// Explicit line counts win over marketing words, so "4K.Remastered.1080p" is 1080p.
    private static let passes: [[(StreamQuality, String)]] = [
        [(.uhd, "2160p|4320p"), (.fhd, "1080[pi]|1440p"), (.hd, "720p"), (.sd, "576[pi]|480[pi]|360p|240p")],
        [(.uhd, "4k|uhd|8k"), (.fhd, "fhd|full[ .-]?hd"), (.hd, "(?<!dts[-. ])hd"), (.sd, "sd|dvdrip|dvd")],
    ]

    /// Parses the resolution named in `text`; `.unknown` when there is none.
    static func parse(_ text: String) -> StreamQuality {
        for pass in passes {
            for (quality, pattern) in pass {
                let regex = "(?:^|[^a-z0-9])(?:" + pattern + ")(?:[^a-z0-9]|$)"
                if text.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil { return quality }
            }
        }
        return .unknown
    }
}

extension Stream {
    /// The addon's name line is checked first (Comet/Torrentio put the resolution there), then the release
    /// filename, then the free-text details, so a "4K" in a movie title can't outrank an explicit "1080p".
    var quality: StreamQuality {
        for field in [name, behaviorHints?.filename, description, title] {
            guard let field, !field.isEmpty else { continue }
            let q = StreamQuality.parse(field)
            if q != .unknown { return q }
        }
        return .unknown
    }
}
