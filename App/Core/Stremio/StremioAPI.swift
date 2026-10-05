import Compression
import Foundation

/// Client for the Stremio account API (`POST https://api.strem.io/api/<method>`). OWNER: Stremio Agent 1 (API).
/// The auth key and addon transport URLs are secrets: never log them.
/// Network failures surface as `URLError`; API failures as `StremioAPIError`.
struct StremioAPI: Sendable {
    let baseURL: URL
    let session: URLSession

    static let libraryCollection = "libraryItem"

    init(baseURL: URL = URL(string: "https://api.strem.io/api/")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func login(email: String, password: String) async throws -> (authKey: String, user: StremioUser) {
        let response: AuthResponse = try await call("login", Requests.Login(email: email, password: password))
        return (response.authKey, response.user)
    }

    func logout(authKey: String) async throws {
        let _: SuccessResponse = try await call("logout", Requests.Typed(type: "Logout", authKey: authKey))
    }

    func getUser(authKey: String) async throws -> StremioUser {
        try await call("getUser", Requests.Typed(type: "GetUser", authKey: authKey))
    }

    func addonCollection(authKey: String) async throws -> [StremioAddonDescriptor] {
        let response: CollectionResponse = try await call(
            "addonCollectionGet", Requests.AddonCollectionGet(authKey: authKey))
        return response.addons.elements
    }

    func setAddonCollection(_ addons: [StremioAddonDescriptor], authKey: String) async throws {
        let _: SuccessResponse = try await call(
            "addonCollectionSet", Requests.AddonCollectionSet(authKey: authKey, addons: addons))
    }

    /// `datastoreMeta` for the `libraryItem` collection: id + last-modified of every item.
    func libraryMeta(authKey: String) async throws -> [StremioItemMeta] {
        try await call("datastoreMeta", Requests.DatastoreMeta(authKey: authKey, collection: Self.libraryCollection))
    }

    /// `datastoreGet` for `libraryItem`; `ids == nil` fetches all. Malformed items are skipped.
    func libraryItems(ids: [String]?, authKey: String) async throws -> [StremioLibraryItem] {
        if let ids, ids.isEmpty { return [] }
        let request = Requests.DatastoreGet(
            authKey: authKey, collection: Self.libraryCollection, ids: ids ?? [], all: ids == nil)
        let items: LossyArray<StremioLibraryItem> = try await call("datastoreGet", request, timeout: 60)
        return items.elements
    }

    /// `datastorePut` for `libraryItem` (upserts; deletion is `removed = true`).
    func putLibraryItems(_ items: [StremioLibraryItem], authKey: String) async throws {
        guard !items.isEmpty else { return }
        let _: SuccessResponse = try await call(
            "datastorePut",
            Requests.DatastorePut(authKey: authKey, collection: Self.libraryCollection, changes: items),
            timeout: 60)
    }

    // MARK: - Transport

    func call<Body: Encodable, Result: Decodable>(
        _ method: String, _ body: Body, timeout: TimeInterval = 20
    ) async throws -> Result {
        var request = URLRequest(url: baseURL.appendingPathComponent(method), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        do {
            return try Self.decodeEnvelope(Result.self, from: data, httpStatus: status)
        } catch let failure as APIFailure {
            throw Self.map(failure, method: method)
        }
    }

    static func map(_ failure: APIFailure, method: String) -> StremioAPIError {
        if failure.code == 1 { return .unauthorized }
        if method == "login", failure.code == 2 || failure.code == 3 || isCredentialError(failure.message) {
            return .invalidCredentials
        }
        return .server(failure.message)
    }

    /// Decodes `{"result": T}` or `{"error": {"message", "code"}}`; error code 1 ("Session does not exist") is `.unauthorized`,
    /// other errors are thrown as `APIFailure`.
    static func decodeEnvelope<T: Decodable>(_ type: T.Type, from data: Data, httpStatus: Int = 200) throws -> T {
        let envelope: Envelope<T>
        do {
            envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            if !(200..<300).contains(httpStatus) { throw StremioAPIError.server("Stremio server error (HTTP \(httpStatus))") }
            throw StremioAPIError.server("Unexpected response from Stremio")
        }
        if let failure = envelope.error {
            if failure.code == 1 { throw StremioAPIError.unauthorized }
            throw failure
        }
        guard let result = envelope.result else {
            throw StremioAPIError.server("Unexpected response from Stremio")
        }
        return result
    }

    static func isCredentialError(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("password") || m.contains("passphrase") || m.contains("user not found")
    }
}

/// The `{"error": …}` payload; public API methods convert it to `StremioAPIError`.
struct APIFailure: Error, Decodable, Sendable {
    var message: String
    var code: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        message = (try? c.decode(String.self, forKey: .message)) ?? "Stremio server error"
        code = (try? c.decode(Int.self, forKey: .code)) ?? 0
    }

    private enum CodingKeys: String, CodingKey { case message, code }
}

private struct Envelope<T: Decodable>: Decodable {
    var result: T?
    var error: APIFailure?
}

private struct AuthResponse: Decodable {
    var authKey: String
    var user: StremioUser
}

private struct SuccessResponse: Decodable {
    var success: Bool?
}

private struct CollectionResponse: Decodable {
    var addons: LossyArray<StremioAddonDescriptor>
}

/// Decodes an array, dropping elements that fail to decode (like stremio-core's `VecSkipError`).
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [Element] = []
        while !c.isAtEnd {
            if let e = try? c.decode(Element.self) { out.append(e) } else { _ = try? c.decode(JSONValue.self) }
        }
        elements = out
    }
}

/// Request bodies, exactly as stremio-core serializes them (`src/types/api/request.rs`).
enum Requests {
    struct Login: Encodable {
        var type = "Login"
        var email: String
        var password: String
        var facebook = false
    }

    struct Typed: Encodable {
        var type: String
        var authKey: String
    }

    struct AddonCollectionGet: Encodable {
        var type = "AddonCollectionGet"
        var authKey: String
        var update = true
    }

    struct AddonCollectionSet: Encodable {
        var type = "AddonCollectionSet"
        var authKey: String
        var addons: [StremioAddonDescriptor]
    }

    struct DatastoreMeta: Encodable {
        var authKey: String
        var collection: String
    }

    struct DatastoreGet: Encodable {
        var authKey: String
        var collection: String
        var ids: [String]
        var all: Bool
    }

    struct DatastorePut: Encodable {
        var authKey: String
        var collection: String
        var changes: [StremioLibraryItem]
    }
}

enum StremioAPIError: LocalizedError, Sendable, Equatable {
    case notImplemented
    /// Bad or expired auth key; the account should sign out locally.
    case unauthorized
    case invalidCredentials
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notImplemented: "Not implemented"
        case .unauthorized: "Your Stremio session has expired. Sign in again."
        case .invalidCredentials: "Wrong email or password."
        case .server(let message): message
        }
    }
}

// MARK: - Models

struct StremioUser: Codable, Sendable, Hashable {
    var id: String
    var email: String
    var fullname: String?
    var avatar: String?

    private enum CodingKeys: String, CodingKey {
        case id = "_id", email, fullname, avatar
    }

    init(id: String, email: String, fullname: String? = nil, avatar: String? = nil) {
        self.id = id
        self.email = email
        self.fullname = fullname
        self.avatar = avatar
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        email = (try? c.decode(String.self, forKey: .email)) ?? ""
        fullname = (try? c.decodeIfPresent(String.self, forKey: .fullname)).flatMap(\.nonEmpty)
        avatar = (try? c.decodeIfPresent(String.self, forKey: .avatar)).flatMap(\.nonEmpty)
    }
}

/// One entry of the account's addon collection. `manifest` is kept as raw JSON so unknown fields round-trip unchanged.
struct StremioAddonDescriptor: Codable, Sendable, Hashable {
    var transportUrl: String
    var manifest: JSONValue
    var flags: Flags

    struct Flags: Codable, Sendable, Hashable {
        var official: Bool = false
        var protected: Bool = false

        init(official: Bool = false, protected: Bool = false) {
            self.official = official
            self.protected = protected
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            official = (try? c.decodeIfPresent(Bool.self, forKey: .official)) ?? false
            protected = (try? c.decodeIfPresent(Bool.self, forKey: .protected)) ?? false
        }
    }

    var manifestID: String? { manifest["id"]?.stringValue }

    init(transportUrl: String, manifest: JSONValue, flags: Flags = Flags()) {
        self.transportUrl = transportUrl
        self.manifest = manifest
        self.flags = flags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transportUrl = try c.decode(String.self, forKey: .transportUrl)
        manifest = try c.decode(JSONValue.self, forKey: .manifest)
        flags = (try? c.decodeIfPresent(Flags.self, forKey: .flags)) ?? Flags()
    }
}

/// One `datastoreMeta` entry; on the wire `["<id>", <mtime ms>]`.
struct StremioItemMeta: Sendable, Hashable, Decodable {
    var id: String
    var mtime: Date

    init(id: String, mtime: Date) {
        self.id = id
        self.mtime = mtime
    }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        id = try c.decode(String.self)
        mtime = Date(timeIntervalSince1970: try c.decode(Double.self) / 1000)
    }
}

/// A Stremio library item (collection `libraryItem`). Times inside `state` are milliseconds, as on the wire.
/// Wire keys: `_id`, `_ctime`, `_mtime`, `state.video_id`; dates are ISO 8601 strings.
/// Unknown keys (top level and in `state`) are preserved in `extra` and written back on encode.
struct StremioLibraryItem: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var type: String
    var poster: String?
    var posterShape: String?
    var removed: Bool
    /// Items created only by watching (not explicitly added to the library).
    var temp: Bool
    var ctime: Date?
    var mtime: Date
    var state: State
    /// Raw `behaviorHints` object (e.g. `defaultVideoId`, `hasScheduledVideos`).
    var behaviorHints: JSONValue?
    var extra: [String: JSONValue] = [:]

    struct State: Codable, Sendable, Hashable {
        var lastWatched: Date?
        var timeWatched: Int64 = 0
        var timeOffset: Int64 = 0
        var overallTimeWatched: Int64 = 0
        var timesWatched: Int = 0
        var flaggedWatched: Int = 0
        var duration: Int64 = 0
        var videoId: String?
        /// Compressed episode bitfield, "<anchorVideoId>:<length>:<base64 zlib>". See `WatchedBitfield`.
        var watched: String?
        var noNotif: Bool = false
        var extra: [String: JSONValue] = [:]

        init(
            lastWatched: Date? = nil, timeWatched: Int64 = 0, timeOffset: Int64 = 0, overallTimeWatched: Int64 = 0,
            timesWatched: Int = 0, flaggedWatched: Int = 0, duration: Int64 = 0, videoId: String? = nil,
            watched: String? = nil, noNotif: Bool = false
        ) {
            self.lastWatched = lastWatched
            self.timeWatched = timeWatched
            self.timeOffset = timeOffset
            self.overallTimeWatched = overallTimeWatched
            self.timesWatched = timesWatched
            self.flaggedWatched = flaggedWatched
            self.duration = duration
            self.videoId = videoId
            self.watched = watched
            self.noNotif = noNotif
        }

        private static let known: Set<String> = [
            "lastWatched", "timeWatched", "timeOffset", "overallTimeWatched", "timesWatched",
            "flaggedWatched", "duration", "video_id", "watched", "noNotif",
        ]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            lastWatched = c.date("lastWatched")
            timeWatched = c.int("timeWatched")
            timeOffset = c.int("timeOffset")
            overallTimeWatched = c.int("overallTimeWatched")
            timesWatched = Int(c.int("timesWatched"))
            flaggedWatched = Int(c.int("flaggedWatched"))
            duration = c.int("duration")
            videoId = c.string("video_id")
            watched = c.string("watched")
            noNotif = c.bool("noNotif")
            extra = c.extra(excluding: Self.known)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            try c.encodeExtra(extra)
            try c.encode(lastWatched.map(StremioDate.string), forKey: "lastWatched")
            try c.encode(timeWatched, forKey: "timeWatched")
            try c.encode(timeOffset, forKey: "timeOffset")
            try c.encode(overallTimeWatched, forKey: "overallTimeWatched")
            try c.encode(timesWatched, forKey: "timesWatched")
            try c.encode(flaggedWatched, forKey: "flaggedWatched")
            try c.encode(duration, forKey: "duration")
            try c.encode(videoId, forKey: "video_id")
            try c.encode(watched, forKey: "watched")
            try c.encode(noNotif, forKey: "noNotif")
        }
    }

    init(
        id: String, name: String, type: String, poster: String? = nil, posterShape: String? = nil,
        removed: Bool = false, temp: Bool = false, ctime: Date? = nil, mtime: Date, state: State = State(),
        behaviorHints: JSONValue? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.poster = poster
        self.posterShape = posterShape
        self.removed = removed
        self.temp = temp
        self.ctime = ctime
        self.mtime = mtime
        self.state = state
        self.behaviorHints = behaviorHints
    }

    private static let known: Set<String> = [
        "_id", "name", "type", "poster", "posterShape", "removed", "temp", "_ctime", "_mtime", "state",
        "behaviorHints",
    ]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.decode(String.self, forKey: "_id")
        name = c.string("name") ?? ""
        type = try c.decode(String.self, forKey: "type")
        poster = c.string("poster")
        posterShape = c.string("posterShape")
        removed = c.bool("removed")
        temp = c.bool("temp")
        ctime = c.date("_ctime")
        guard let mtime = c.date("_mtime") else {
            throw DecodingError.dataCorruptedError(forKey: "_mtime", in: c, debugDescription: "missing _mtime")
        }
        self.mtime = mtime
        state = (try? c.decodeIfPresent(State.self, forKey: "state")) ?? State()
        behaviorHints = try? c.decodeIfPresent(JSONValue.self, forKey: "behaviorHints")
        extra = c.extra(excluding: Self.known)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeExtra(extra)
        try c.encode(id, forKey: "_id")
        try c.encode(name, forKey: "name")
        try c.encode(type, forKey: "type")
        try c.encode(poster, forKey: "poster")
        try c.encodeIfPresent(posterShape, forKey: "posterShape")
        try c.encode(removed, forKey: "removed")
        try c.encode(temp, forKey: "temp")
        try c.encode(ctime.map(StremioDate.string), forKey: "_ctime")
        try c.encode(StremioDate.string(mtime), forKey: "_mtime")
        try c.encode(state, forKey: "state")
        try c.encodeIfPresent(behaviorHints, forKey: "behaviorHints")
    }
}

/// ISO 8601 / RFC 3339 dates as the Stremio API writes them (`2024-01-02T03:04:05.678Z`).
enum StremioDate {
    static func string(_ date: Date) -> String {
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
        var (secs, millis) = ms.quotientAndRemainder(dividingBy: 1000)
        if millis < 0 { secs -= 1; millis += 1000 }
        let base = Date.ISO8601FormatStyle().format(Date(timeIntervalSince1970: TimeInterval(secs))).dropLast()
        let fraction = String(millis + 1000).dropFirst()
        return "\(base).\(fraction)Z"
    }

    static func parse(_ string: String) -> Date? {
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let d = try? fractional.parse(string) { return d }
        return try? Date.ISO8601FormatStyle().parse(string)
    }
}

private struct AnyKey: CodingKey, ExpressibleByStringLiteral {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
    init(stringLiteral value: String) { stringValue = value }
}

private extension KeyedDecodingContainer where Key == AnyKey {
    func string(_ key: String) -> String? {
        (try? decodeIfPresent(String.self, forKey: AnyKey(stringValue: key))).flatMap { $0?.nonEmpty }
    }

    func bool(_ key: String) -> Bool {
        let k = AnyKey(stringValue: key)
        if let b = try? decodeIfPresent(Bool.self, forKey: k) { return b }
        if let n = try? decodeIfPresent(Double.self, forKey: k) { return n != 0 }
        return false
    }

    func int(_ key: String) -> Int64 {
        let k = AnyKey(stringValue: key)
        if let i = try? decodeIfPresent(Int64.self, forKey: k) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: k), d.isFinite { return Int64(d) }
        return 0
    }

    func date(_ key: String) -> Date? {
        let k = AnyKey(stringValue: key)
        if let s = try? decodeIfPresent(String.self, forKey: k) { return StremioDate.parse(s) }
        if let ms = try? decodeIfPresent(Double.self, forKey: k) { return Date(timeIntervalSince1970: ms / 1000) }
        return nil
    }

    func extra(excluding known: Set<String>) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for key in allKeys where !known.contains(key.stringValue) {
            if let v = try? decode(JSONValue.self, forKey: key) { out[key.stringValue] = v }
        }
        return out
    }
}

private extension KeyedEncodingContainer where Key == AnyKey {
    mutating func encodeExtra(_ extra: [String: JSONValue]) throws {
        for (key, value) in extra { try encode(value, forKey: AnyKey(stringValue: key)) }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Minimal lossless JSON value.
enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

// MARK: - Watched bitfield

/// Codec for `LibraryItem.state.watched`, matching stremio-core's `stremio-watched-bitfield` crate:
/// `"<anchorVideoId>:<anchorLength>:<base64(zlib(bytes))>"`, bit `i` (LSB-first within each byte) = `videoIDs[i]` watched.
/// The anchor (last watched video and its 1-based index) lets the bitfield be re-aligned when episodes were
/// added or removed before it. `videoIDs` must be ordered like stremio-core: by season, then episode, then release date.
enum WatchedBitfield {
    /// Returns the watched video ids. An unparseable string or an anchor not in `videoIDs` yields an empty set.
    static func decode(_ s: String, videoIDs: [String]) -> Set<String> {
        var components = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 3,
              let packed = components.popLast(),
              let lengthString = components.popLast(), let anchorLength = Int(lengthString),
              let values = unpack(packed)
        else { return [] }
        let anchor = components.joined(separator: ":")
        guard let anchorIndex = videoIDs.firstIndex(of: anchor) else { return [] }

        let count = videoIDs.count
        let offset = anchorLength - anchorIndex - 1
        func bit(_ i: Int) -> Bool { i / 8 < values.count && (values[i / 8] >> (i % 8)) & 1 != 0 }

        var watched: Set<String> = []
        var seen: Set<String> = []
        for (i, id) in videoIDs.enumerated() where seen.insert(id).inserted {
            let source = i + offset
            let isSet = offset == 0 ? bit(i) : (source >= 0 && source < count && bit(source))
            if isSet { watched.insert(id) }
        }
        return watched
    }

    static func encode(watched: Set<String>, videoIDs: [String]) -> String {
        var values = [UInt8](repeating: 0, count: (videoIDs.count + 7) / 8)
        var seen: Set<String> = []
        var last = 0
        for (i, id) in videoIDs.enumerated() where seen.insert(id).inserted && watched.contains(id) {
            values[i / 8] |= 1 << (i % 8)
            last = i
        }
        let anchor = videoIDs.indices.contains(last) ? videoIDs[last] : "undefined"
        return "\(anchor):\(last + 1):\(pack(values))"
    }

    static func pack(_ bytes: [UInt8]) -> String {
        zlibCompress(Data(bytes)).base64EncodedString()
    }

    static func unpack(_ base64: String) -> [UInt8]? {
        guard let data = Data(base64Encoded: base64), let raw = zlibDecompress(data) else { return nil }
        return [UInt8](raw)
    }

    /// zlib stream (RFC 1950): 2-byte header + raw deflate (Apple's `COMPRESSION_ZLIB`) + big-endian Adler-32.
    static func zlibCompress(_ data: Data) -> Data {
        var deflated: Data
        if data.isEmpty {
            deflated = Data([0x03, 0x00])
        } else {
            let capacity = data.count + data.count / 2 + 64
            var buffer = [UInt8](repeating: 0, count: capacity)
            let written = data.withUnsafeBytes { src in
                compression_encode_buffer(
                    &buffer, capacity, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
            deflated = Data(buffer.prefix(written))
        }
        var out = Data([0x78, 0x9C])
        out.append(deflated)
        let a = adler32(data)
        out.append(contentsOf: [UInt8(a >> 24), UInt8((a >> 16) & 0xFF), UInt8((a >> 8) & 0xFF), UInt8(a & 0xFF)])
        return out
    }

    static func zlibDecompress(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 6, bytes[0] & 0x0F == 8, (UInt16(bytes[0]) << 8 | UInt16(bytes[1])) % 31 == 0,
              bytes[1] & 0x20 == 0
        else { return nil }
        let deflated = Array(bytes[2..<(bytes.count - 4)])
        var capacity = max(64, deflated.count * 8)
        while capacity <= 1 << 24 {
            var buffer = [UInt8](repeating: 0, count: capacity)
            let written = compression_decode_buffer(&buffer, capacity, deflated, deflated.count, nil, COMPRESSION_ZLIB)
            if written < capacity {
                let out = Data(buffer.prefix(written))
                return adler32(out) == bytes.suffix(4).reduce(0) { $0 << 8 | UInt32($1) } ? out : nil
            }
            capacity *= 4
        }
        return nil
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return b << 16 | a
    }
}
