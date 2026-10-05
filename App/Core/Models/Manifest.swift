import Foundation

struct Manifest: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var version: String
    var description: String?
    var logo: String?
    var resources: [ManifestResource]
    var types: [String]
    var catalogs: [ManifestCatalog]
    var idPrefixes: [String]?
    var behaviorHints: ManifestBehaviorHints?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "0"
        description = try c.decodeIfPresent(String.self, forKey: .description)
        logo = try c.decodeIfPresent(String.self, forKey: .logo)
        resources = try c.decodeIfPresent([ManifestResource].self, forKey: .resources) ?? []
        types = try c.decodeIfPresent([String].self, forKey: .types) ?? []
        catalogs = c.decodeLossyArray(ManifestCatalog.self, forKey: .catalogs) ?? []
        idPrefixes = try c.decodeIfPresent([String].self, forKey: .idPrefixes)
        behaviorHints = try c.decodeIfPresent(ManifestBehaviorHints.self, forKey: .behaviorHints)
    }

    /// Whether this addon serves `resource` for `type` and the given id (respecting per-resource and global idPrefixes).
    func supports(resource: String, type: String, id: String? = nil) -> Bool {
        guard let r = resources.first(where: { $0.name == resource }) else { return false }
        let resTypes = r.types ?? types
        guard resTypes.contains(type) else { return false }
        guard let id else { return true }
        let prefixes = r.idPrefixes ?? idPrefixes
        guard let prefixes, !prefixes.isEmpty else { return true }
        return prefixes.contains { id.hasPrefix($0) }
    }
}

struct ManifestBehaviorHints: Codable, Hashable, Sendable {
    var configurable: Bool?
    var configurationRequired: Bool?
    var adult: Bool?
}

/// A resource is either a plain string ("stream") or an object with name/types/idPrefixes.
struct ManifestResource: Codable, Hashable, Sendable {
    var name: String
    var types: [String]?
    var idPrefixes: [String]?

    init(name: String, types: [String]? = nil, idPrefixes: [String]? = nil) {
        self.name = name
        self.types = types
        self.idPrefixes = idPrefixes
    }

    private enum CodingKeys: String, CodingKey { case name, types, idPrefixes }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let s = try? single.decode(String.self) {
            name = s
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        types = try c.decodeIfPresent([String].self, forKey: .types)
        idPrefixes = try c.decodeIfPresent([String].self, forKey: .idPrefixes)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(types, forKey: .types)
        try c.encodeIfPresent(idPrefixes, forKey: .idPrefixes)
    }
}

struct ManifestCatalog: Codable, Hashable, Sendable {
    var type: String
    var id: String
    var name: String?
    var extra: [CatalogExtra]?
    var extraSupported: [String]?
    var extraRequired: [String]?
    /// Legacy (pre-`extra`) genre list; still sent by Cinemeta and older addons.
    var genres: [String]?

    init(type: String, id: String, name: String? = nil, extra: [CatalogExtra]? = nil,
         extraSupported: [String]? = nil, extraRequired: [String]? = nil, genres: [String]? = nil) {
        self.type = type; self.id = id; self.name = name; self.extra = extra
        self.extraSupported = extraSupported; self.extraRequired = extraRequired; self.genres = genres
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        id = try c.decode(String.self, forKey: .id)
        name = c.decodeLossyString(forKey: .name)
        extra = c.decodeLossyArray(CatalogExtra.self, forKey: .extra)
        extraSupported = c.decodeLossyArray(String.self, forKey: .extraSupported)
        extraRequired = c.decodeLossyArray(String.self, forKey: .extraRequired)
        genres = c.decodeLossyStringArray(forKey: .genres)
    }

    /// Catalog ids repeat across types, so use this in ForEach.
    var stableID: String { "\(type)/\(id)" }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return id
    }

    func supports(extra extraName: String) -> Bool {
        (extra?.contains { $0.name == extraName } ?? false) || (extraSupported?.contains(extraName) ?? false)
            || (extraName == "genre" && genres != nil)
    }

    var supportsSearch: Bool { supports(extra: "search") }
    var supportsSkip: Bool { supports(extra: "skip") }
    var supportsGenre: Bool { supports(extra: "genre") }

    /// Names of extras the addon requires on every request (deduplicated, declaration order).
    var requiredExtras: [String] {
        var seen = Set<String>()
        return ((extra?.filter { $0.isRequired == true }.map(\.name) ?? []) + (extraRequired ?? []))
            .filter { seen.insert($0).inserted }
    }

    var requiresGenre: Bool { requiredExtras.contains("genre") }

    /// Selectable genre values: the `genre` extra's options, else the legacy `genres` list.
    var genreOptions: [String] {
        if let options = extra?.first(where: { $0.name == "genre" })?.options, !options.isEmpty { return options }
        return genres ?? []
    }

    /// Plain rows (Home) can be shown without supplying any extra.
    var isBrowsable: Bool { requiredExtras.isEmpty }

    /// Usable in Discover: needs nothing but (optionally) a genre, and a required genre has options to pick from.
    var isDiscoverable: Bool {
        requiredExtras.allSatisfy { $0 == "genre" } && (!requiresGenre || !genreOptions.isEmpty)
    }

    /// Order in which the addon declared its extras; request extras follow it (static addons match paths literally).
    var extraOrder: [String] {
        var seen = Set<String>()
        return ((extra?.map(\.name) ?? []) + (extraSupported ?? [])).filter { seen.insert($0).inserted }
    }
}

struct CatalogExtra: Codable, Hashable, Sendable {
    var name: String
    var isRequired: Bool?
    var options: [String]?
    var optionsLimit: Int?

    init(name: String, isRequired: Bool? = nil, options: [String]? = nil, optionsLimit: Int? = nil) {
        self.name = name; self.isRequired = isRequired; self.options = options; self.optionsLimit = optionsLimit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        isRequired = try? c.decodeIfPresent(Bool.self, forKey: .isRequired)
        options = c.decodeLossyStringArray(forKey: .options)
        optionsLimit = try c.decodeLossyInt(forKey: .optionsLimit)
    }
}

extension KeyedDecodingContainer {
    /// String array whose numeric elements (e.g. years) are kept as strings; other elements are dropped.
    func decodeLossyStringArray(forKey key: Key) -> [String]? {
        decodeLossyArray(LossyString.self, forKey: key)?.compactMap(\.value)
    }
}

private struct LossyString: Decodable {
    var value: String?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = String(i) }
        else if let d = try? c.decode(Double.self) { value = String(d) }
    }
}
