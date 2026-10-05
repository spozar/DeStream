import Foundation

/// On-disk `meta.json` for one saved title. All file paths are relative to the title folder.
/// OWNER: Agent 5 (Library). Schema is fixed by PLAN.md; DownloadManager writes it via LibraryWriter.
struct SidecarMeta: Codable, Hashable, Sendable, Identifiable {
    static let currentSchemaVersion = 1
    static let fileName = "meta.json"

    var schemaVersion: Int = 1
    var id: String
    var type: String
    var name: String
    var year: String?
    var description: String?
    var genres: [String]?
    var poster: String?
    var backdrop: String?
    var items: [SidecarItem]

    struct SidecarItem: Codable, Hashable, Sendable, Identifiable {
        var videoId: String
        var season: Int?
        var episode: Int?
        var title: String?
        var file: String
        var sizeBytes: Int64?
        var savedAt: Date
        var progressSeconds: Double?
        var durationSeconds: Double?
        /// Saved subtitle files; nil = not fetched yet, [] = fetched but none found.
        var subtitles: [SidecarSubtitle]? = nil
        var id: String { videoId }

        var episodeCode: String? {
            guard let season, let episode else { return nil }
            return String(format: "S%02dE%02d", season, episode)
        }

        /// 0...1 watch fraction, nil when unknown.
        var progressFraction: Double? {
            guard let progressSeconds, let durationSeconds, durationSeconds > 0 else { return nil }
            return min(1, max(0, progressSeconds / durationSeconds))
        }
    }

    /// A subtitle file saved next to an item's video.
    struct SidecarSubtitle: Codable, Hashable, Sendable {
        /// Relative to the title folder.
        var file: String
        /// Canonical ISO 639-1 code.
        var language: String
        var source: String?
        var isHashMatch: Bool?
    }

    var isSeries: Bool { type != "movie" }

    /// Items sorted by season then episode (movies keep their order).
    var sortedItems: [SidecarItem] {
        items.sorted { ($0.season ?? 0, $0.episode ?? 0, $0.videoId) < ($1.season ?? 0, $1.episode ?? 0, $1.videoId) }
    }

    var latestSavedAt: Date { items.map(\.savedAt).max() ?? .distantPast }
}

extension SidecarMeta {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, type, name, year, description, genres, poster, backdrop, items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        id = try c.decode(String.self, forKey: .id)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "movie"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        year = try? c.decodeIfPresent(String.self, forKey: .year)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        genres = try? c.decodeIfPresent([String].self, forKey: .genres)
        poster = try? c.decodeIfPresent(String.self, forKey: .poster)
        backdrop = try? c.decodeIfPresent(String.self, forKey: .backdrop)
        // A single malformed item must not hide the whole title.
        let lossy = try c.decodeIfPresent([LossyItem].self, forKey: .items) ?? []
        items = lossy.compactMap(\.value)
    }

    private struct LossyItem: Decodable {
        var value: SidecarItem?
        init(from decoder: Decoder) throws { value = try? SidecarItem(from: decoder) }
    }
}

extension SidecarMeta.SidecarItem {
    private enum CodingKeys: String, CodingKey {
        case videoId, season, episode, title, file, sizeBytes, savedAt, progressSeconds, durationSeconds, subtitles
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoId = try c.decode(String.self, forKey: .videoId)
        season = try c.decodeLossyInt(forKey: .season)
        episode = try c.decodeLossyInt(forKey: .episode)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        file = try c.decode(String.self, forKey: .file)
        sizeBytes = try? c.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        savedAt = (try? c.decodeIfPresent(Date.self, forKey: .savedAt)) ?? Date(timeIntervalSince1970: 0)
        progressSeconds = try? c.decodeIfPresent(Double.self, forKey: .progressSeconds)
        durationSeconds = try? c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        subtitles = (try? c.decodeIfPresent([LossySubtitle].self, forKey: .subtitles))?.compactMap(\.value)
    }

    private struct LossySubtitle: Decodable {
        var value: SidecarMeta.SidecarSubtitle?
        init(from decoder: Decoder) throws { value = try? SidecarMeta.SidecarSubtitle(from: decoder) }
    }
}

extension SidecarMeta {
    /// ISO8601 dates (`2026-10-02T12:00:00Z`), pretty-printed with sorted keys.
    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// Accepts ISO8601 with or without fractional seconds.
    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = try? Date(s, strategy: .iso8601) { return date }
            if let date = try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid ISO8601 date: \(s)")
        }
        return d
    }

    static func decode(_ data: Data) throws -> SidecarMeta { try makeDecoder().decode(SidecarMeta.self, from: data) }
    func encoded() throws -> Data { try Self.makeEncoder().encode(self) }

    /// True when `path` is a plain relative path that stays inside the title folder.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("://") else { return false }
        return !path.split(separator: "/").contains("..")
    }
}

/// A saved title as loaded from disk, with its resolved folder.
struct SavedTitle: Hashable, Sendable, Identifiable {
    var folder: URL
    var meta: SidecarMeta
    var id: String { meta.id }
    var posterURL: URL? { meta.poster.map { folder.appendingPathComponent($0) } }
    var backdropURL: URL? { meta.backdrop.map { folder.appendingPathComponent($0) } }
    func fileURL(for item: SidecarMeta.SidecarItem) -> URL { folder.appendingPathComponent(item.file) }

    /// The item's saved subtitles as local tracks for the player.
    func externalSubtitles(for item: SidecarMeta.SidecarItem) -> [ExternalSubtitle] {
        (item.subtitles ?? []).map { sub in
            ExternalSubtitle(url: folder.appendingPathComponent(sub.file), language: sub.language, source: sub.source,
                             fileName: sub.file, isHashMatch: sub.isHashMatch ?? false)
        }
    }

    var itemsSubtitle: String {
        if meta.type == "movie" { return "Movie" }
        let n = meta.items.count
        return n == 1 ? "1 episode" : "\(n) episodes"
    }
}
