import Foundation

struct MetaPreview: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var type: String
    var name: String
    var poster: String?
    var posterShape: String?
    var releaseInfo: String?
    var description: String?
    var imdbRating: String?

    init(id: String, type: String, name: String, poster: String? = nil, posterShape: String? = nil,
         releaseInfo: String? = nil, description: String? = nil, imdbRating: String? = nil) {
        self.id = id; self.type = type; self.name = name; self.poster = poster
        self.posterShape = posterShape; self.releaseInfo = releaseInfo
        self.description = description; self.imdbRating = imdbRating
    }
}

struct MetaDetail: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var type: String
    var name: String
    var poster: String?
    var posterShape: String?
    var background: String?
    var logo: String?
    var description: String?
    var releaseInfo: String?
    var year: String?
    var runtime: String?
    var imdbRating: String?
    var genres: [String]?
    var genre: [String]?
    var videos: [Video]?
    var cast: [String]? = nil
    var director: [String]? = nil

    var allGenres: [String] { genres ?? genre ?? [] }
    var displayYear: String? { year ?? releaseInfo }

    var preview: MetaPreview {
        MetaPreview(id: id, type: type, name: name, poster: poster, posterShape: posterShape,
                    releaseInfo: releaseInfo, description: description, imdbRating: imdbRating)
    }

    /// Seasons present in `videos`, ascending, with specials (season 0) last.
    var seasons: [Int] {
        let s = Set((videos ?? []).compactMap(\.season))
        return s.filter { $0 > 0 }.sorted() + (s.contains(0) ? [0] : [])
    }

    func episodes(season: Int) -> [Video] {
        (videos ?? []).filter { $0.season == season }.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
    }
}

struct Video: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String?
    var name: String?
    var season: Int?
    var episode: Int?
    var released: String?
    var thumbnail: String?
    var overview: String?
    var description: String?

    var displayTitle: String { title ?? name ?? "Episode \(episode ?? 0)" }
    var episodeCode: String? {
        guard let season, let episode else { return nil }
        return String(format: "S%02dE%02d", season, episode)
    }

    init(id: String, title: String? = nil, season: Int? = nil, episode: Int? = nil, released: String? = nil, thumbnail: String? = nil) {
        self.id = id; self.title = title; self.season = season; self.episode = episode
        self.released = released; self.thumbnail = thumbnail
    }

    private enum CodingKeys: String, CodingKey { case id, title, name, season, episode, number, released, thumbnail, overview, description }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        season = try c.decodeLossyInt(forKey: .season)
        episode = try c.decodeLossyInt(forKey: .episode) ?? c.decodeLossyInt(forKey: .number)
        released = try? c.decodeIfPresent(String.self, forKey: .released)
        thumbnail = try c.decodeIfPresent(String.self, forKey: .thumbnail)
        overview = try c.decodeIfPresent(String.self, forKey: .overview)
        description = try c.decodeIfPresent(String.self, forKey: .description)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(season, forKey: .season)
        try c.encodeIfPresent(episode, forKey: .episode)
        try c.encodeIfPresent(released, forKey: .released)
        try c.encodeIfPresent(thumbnail, forKey: .thumbnail)
        try c.encodeIfPresent(overview, forKey: .overview)
        try c.encodeIfPresent(description, forKey: .description)
    }
}

extension KeyedDecodingContainer {
    func decodeLossyInt(forKey key: Key) throws -> Int? {
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int(s) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        return nil
    }
}

extension KeyedDecodingContainer {
    /// Accepts strings or numbers (addons are inconsistent about e.g. `year` and `imdbRating`).
    func decodeLossyString(forKey key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return String(d) }
        return nil
    }

    /// Decodes an array, silently dropping elements that fail to decode. Missing/null/non-array yields nil.
    func decodeLossyArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T]? {
        guard let items = try? decodeIfPresent([LossyElement<T>].self, forKey: key) else { return nil }
        return items.compactMap(\.value)
    }
}

struct LossyElement<T: Decodable>: Decodable {
    var value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension MetaPreview {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id),
                  type: try c.decode(String.self, forKey: .type),
                  name: try c.decode(String.self, forKey: .name),
                  poster: c.decodeLossyString(forKey: .poster),
                  posterShape: c.decodeLossyString(forKey: .posterShape),
                  releaseInfo: c.decodeLossyString(forKey: .releaseInfo),
                  description: c.decodeLossyString(forKey: .description),
                  imdbRating: c.decodeLossyString(forKey: .imdbRating))
    }
}

extension MetaDetail {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        name = try c.decode(String.self, forKey: .name)
        poster = c.decodeLossyString(forKey: .poster)
        posterShape = c.decodeLossyString(forKey: .posterShape)
        background = c.decodeLossyString(forKey: .background)
        logo = c.decodeLossyString(forKey: .logo)
        description = c.decodeLossyString(forKey: .description)
        releaseInfo = c.decodeLossyString(forKey: .releaseInfo)
        year = c.decodeLossyString(forKey: .year)
        runtime = c.decodeLossyString(forKey: .runtime)
        imdbRating = c.decodeLossyString(forKey: .imdbRating)
        genres = c.decodeLossyArray(String.self, forKey: .genres)
        genre = c.decodeLossyArray(String.self, forKey: .genre)
        videos = c.decodeLossyArray(Video.self, forKey: .videos)
        cast = c.decodeLossyArray(String.self, forKey: .cast)
        director = c.decodeLossyArray(String.self, forKey: .director)
    }
}

/// `{"metas": [...]}`; individual metas that fail to decode are dropped.
struct CatalogResponse: Codable, Sendable {
    var metas: [MetaPreview]

    init(metas: [MetaPreview]) { self.metas = metas }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metas = c.decodeLossyArray(MetaPreview.self, forKey: .metas) ?? []
    }
}

struct MetaResponse: Codable, Sendable { var meta: MetaDetail }

/// `{"streams": [...]}`; individual streams that fail to decode are dropped.
struct StreamResponse: Codable, Sendable {
    var streams: [Stream]

    init(streams: [Stream]) { self.streams = streams }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        streams = c.decodeLossyArray(Stream.self, forKey: .streams) ?? []
    }
}
