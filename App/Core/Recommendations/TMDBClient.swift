import Foundation

enum TMDBError: LocalizedError, Equatable, Sendable {
    case invalidKey
    case rateLimited
    case http(Int)
    case network(String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .invalidKey: "TMDB rejected this API key. Check that you pasted the API key or read access token correctly."
        case .rateLimited: "TMDB is rate limiting requests. Try again in a moment."
        case .http(let code): "TMDB returned an error (HTTP \(code))."
        case .network(let message): "Couldn't reach TMDB: \(message)"
        case .decoding: "TMDB sent an unexpected response."
        }
    }
}

/// How the key is sent: v4 read access tokens (JWTs) go in a Bearer header, v3 keys as `api_key`.
enum TMDBCredential: Equatable, Sendable {
    case bearer(String)
    case apiKey(String)

    init(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self = trimmed.hasPrefix("eyJ") ? .bearer(trimmed) : .apiKey(trimmed)
    }
}

struct TMDBClient: TMDBService {
    static let baseURL = URL(string: "https://api.themoviedb.org/3")!
    static let posterBase = "https://image.tmdb.org/t/p/w342"
    static let backdropBase = "https://image.tmdb.org/t/p/w1280"
    static let maxConcurrentLookups = 6

    let credential: TMDBCredential
    let session: URLSession
    let idCache: TMDBIDCache
    let recommendationCache: TMDBRecommendationCache

    init(key: String,
         session: URLSession = TMDBClient.defaultSession,
         idCache: TMDBIDCache = .shared,
         recommendationCache: TMDBRecommendationCache = .shared) {
        self.credential = TMDBCredential(key)
        self.session = session
        self.idCache = idCache
        self.recommendationCache = recommendationCache
    }

    static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    static func posterURL(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return posterBase + path
    }

    static func backdropURL(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return backdropBase + path
    }

    // MARK: TMDBService

    func recommendations(imdbID: String, type: String, limit: Int) async throws -> [MetaPreview] {
        let kind = Kind(type)
        let cacheKey = "\(imdbID)|\(kind.stremioType)"
        if let cached = await recommendationCache.get(cacheKey) { return Array(cached.prefix(limit)) }

        guard let tmdbID = try await tmdbID(imdbID: imdbID, kind: kind) else { return [] }
        var results = try await get(PagedResults.self, path: "/\(kind.path)/\(tmdbID)/recommendations").results
        if results.isEmpty {
            results = try await get(PagedResults.self, path: "/\(kind.path)/\(tmdbID)/similar").results
        }

        let previews = try await mapToPreviews(results, kind: kind)
        await idCache.persist()
        await recommendationCache.set(cacheKey, previews)
        return Array(previews.prefix(limit))
    }

    func backdrop(imdbID: String, type: String) async throws -> String? {
        let kind = Kind(type)
        guard let result = try await find(imdbID: imdbID, kind: kind) else { return nil }
        await idCache.persist()
        return Self.backdropURL(result.backdrop_path)
    }

    // MARK: Validation

    /// Throws `TMDBError.invalidKey` if TMDB rejects the credential.
    func validate() async throws {
        _ = try await data(path: "/configuration", query: [])
    }

    // MARK: ID mapping

    enum Kind: Sendable {
        case movie, tv
        init(_ stremioType: String) { self = stremioType == "series" ? .tv : .movie }
        var path: String { self == .tv ? "tv" : "movie" }
        var stremioType: String { self == .tv ? "series" : "movie" }
    }

    func tmdbID(imdbID: String, kind: Kind) async throws -> Int? {
        if let cached = await idCache.tmdbID(imdb: imdbID, kind: kind) { return cached }
        return try await find(imdbID: imdbID, kind: kind)?.id
    }

    private func find(imdbID: String, kind: Kind) async throws -> Result? {
        let response = try await get(FindResponse.self, path: "/find/\(imdbID)",
                                     query: [URLQueryItem(name: "external_source", value: "imdb_id")])
        let result = (kind == .tv ? response.tv_results : response.movie_results)?.first
        if let result { await idCache.store(imdb: imdbID, tmdb: result.id, kind: kind) }
        return result
    }

    private func imdbID(tmdbID: Int, kind: Kind) async throws -> String? {
        if let cached = await idCache.imdbID(tmdb: tmdbID, kind: kind) { return cached.isEmpty ? nil : cached }
        let ids = try await get(ExternalIDs.self, path: "/\(kind.path)/\(tmdbID)/external_ids")
        let imdb = ids.imdb_id.flatMap { $0.hasPrefix("tt") ? $0 : nil }
        await idCache.store(imdb: imdb, tmdb: tmdbID, kind: kind)
        return imdb
    }

    private func mapToPreviews(_ results: [Result], kind: Kind) async throws -> [MetaPreview] {
        var mapped = [Int: String]()
        try await withThrowingTaskGroup(of: (Int, String?).self) { group in
            var next = 0
            func addNext() {
                guard next < results.count else { return }
                let index = next, id = results[index].id
                next += 1
                group.addTask { (index, try? await imdbID(tmdbID: id, kind: kind)) }
            }
            for _ in 0..<Self.maxConcurrentLookups { addNext() }
            while let (index, imdb) = try await group.next() {
                if let imdb { mapped[index] = imdb }
                addNext()
            }
        }
        var seen = Set<String>()
        return results.enumerated().compactMap { index, result in
            guard let imdb = mapped[index], seen.insert(imdb).inserted else { return nil }
            return result.preview(imdbID: imdb, kind: kind)
        }
    }

    // MARK: HTTP

    private func get<T: Decodable>(_ type: T.Type, path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await data(path: path, query: query)
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw TMDBError.decoding }
    }

    func makeRequest(path: String, query: [URLQueryItem]) -> URLRequest {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var items = query
        if case .apiKey(let key) = credential { items.append(URLQueryItem(name: "api_key", value: key)) }
        components.queryItems = items.isEmpty ? nil : items
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if case .bearer(let token) = credential { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func data(path: String, query: [URLQueryItem], retried: Bool = false) async throws -> Data {
        let request = makeRequest(path: path, query: query)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            // The URLError's failing URL can contain the api_key, so only surface its code description.
            if error.code == .cancelled { throw CancellationError() }
            throw TMDBError.network(Self.describe(error.code))
        }
        guard let http = response as? HTTPURLResponse else { throw TMDBError.decoding }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw TMDBError.invalidKey
        case 429:
            guard !retried else { throw TMDBError.rateLimited }
            let wait = min(Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1, 3)
            try await Task.sleep(for: .seconds(max(wait, 0)))
            return try await self.data(path: path, query: query, retried: true)
        default:
            throw TMDBError.http(http.statusCode)
        }
    }

    private static func describe(_ code: URLError.Code) -> String {
        switch code {
        case .notConnectedToInternet: "You appear to be offline."
        case .timedOut: "The request timed out."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: "The server couldn't be reached."
        default: "Network error (\(code.rawValue))."
        }
    }

    // MARK: Wire types

    private struct FindResponse: Decodable {
        var movie_results: [Result]?
        var tv_results: [Result]?
    }

    private struct PagedResults: Decodable {
        var results: [Result]
    }

    private struct ExternalIDs: Decodable {
        var imdb_id: String?
    }

    struct Result: Decodable, Sendable {
        var id: Int
        var title: String?
        var name: String?
        var overview: String?
        var poster_path: String?
        var backdrop_path: String?
        var release_date: String?
        var first_air_date: String?
        var vote_average: Double?

        func preview(imdbID: String, kind: Kind) -> MetaPreview {
            let date = (kind == .tv ? first_air_date : release_date) ?? release_date ?? first_air_date
            let year = date.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil }
            let rating = vote_average.flatMap { $0 > 0 ? String(format: "%.1f", $0) : nil }
            let overview = overview.flatMap { $0.isEmpty ? nil : $0 }
            return MetaPreview(id: imdbID, type: kind.stremioType, name: title ?? name ?? imdbID,
                               poster: TMDBClient.posterURL(poster_path), posterShape: "poster",
                               releaseInfo: year, description: overview, imdbRating: rating)
        }
    }
}

/// Persistent IMDb <-> TMDB id mapping. An empty IMDb string records "TMDB has no IMDb id" so it isn't re-fetched.
actor TMDBIDCache {
    static let shared = TMDBIDCache(fileURL: {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("DeStream", isDirectory: true).appendingPathComponent("tmdb-ids.json")
    }())

    private struct Store: Codable {
        var toTMDB: [String: Int] = [:]
        var toIMDb: [String: String] = [:]
    }

    private let fileURL: URL?
    private var store: Store?
    private var dirty = false

    /// Pass nil for an in-memory cache.
    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    func tmdbID(imdb: String, kind: TMDBClient.Kind) -> Int? {
        loaded().toTMDB["\(kind.path):\(imdb)"]
    }

    func imdbID(tmdb: Int, kind: TMDBClient.Kind) -> String? {
        loaded().toIMDb["\(kind.path):\(tmdb)"]
    }

    func store(imdb: String?, tmdb: Int, kind: TMDBClient.Kind) {
        var store = loaded()
        if let imdb { store.toTMDB["\(kind.path):\(imdb)"] = tmdb }
        store.toIMDb["\(kind.path):\(tmdb)"] = imdb ?? ""
        self.store = store
        dirty = true
    }

    func persist() {
        guard dirty, let fileURL, let store else { return }
        dirty = false
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(store).write(to: fileURL, options: .atomic)
        } catch {
            dirty = true
        }
    }

    private func loaded() -> Store {
        if let store { return store }
        let decoded = fileURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Store.self, from: $0) }
        let store = decoded ?? Store()
        self.store = store
        return store
    }
}

/// Session-lifetime cache of mapped recommendations keyed by "imdbID|type".
actor TMDBRecommendationCache {
    static let shared = TMDBRecommendationCache()
    private var entries: [String: [MetaPreview]] = [:]

    func get(_ key: String) -> [MetaPreview]? { entries[key] }
    func set(_ key: String, _ value: [MetaPreview]) { entries[key] = value }
    func removeAll() { entries.removeAll() }
}
