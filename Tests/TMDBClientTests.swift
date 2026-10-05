import XCTest
@testable import DeStream

final class TMDBClientTests: XCTestCase {
    private static let v3Key = "0123456789abcdef0123456789abcdef"
    private static let v4Token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.signature"

    override func tearDown() {
        TMDBStubURLProtocol.handler = nil
        super.tearDown()
    }

    func testCredentialSelection() {
        XCTAssertEqual(TMDBCredential("  \(Self.v4Token)\n"), .bearer(Self.v4Token))
        XCTAssertEqual(TMDBCredential(Self.v3Key), .apiKey(Self.v3Key))

        let bearer = TMDBClient(key: Self.v4Token).makeRequest(path: "/configuration", query: [])
        XCTAssertEqual(bearer.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.v4Token)")
        XCTAssertNil(bearer.url?.query)

        let v3 = TMDBClient(key: Self.v3Key).makeRequest(path: "/find/tt1", query: [URLQueryItem(name: "external_source", value: "imdb_id")])
        XCTAssertNil(v3.value(forHTTPHeaderField: "Authorization"))
        let items = URLComponents(url: v3.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "api_key" }?.value, Self.v3Key)
        XCTAssertEqual(items.first { $0.name == "external_source" }?.value, "imdb_id")
        XCTAssertEqual(v3.url?.path, "/3/find/tt1")
    }

    func testImageURLs() {
        XCTAssertEqual(TMDBClient.posterURL("/abc.jpg"), "https://image.tmdb.org/t/p/w342/abc.jpg")
        XCTAssertEqual(TMDBClient.backdropURL("/abc.jpg"), "https://image.tmdb.org/t/p/w1280/abc.jpg")
        XCTAssertNil(TMDBClient.posterURL(nil))
        XCTAssertNil(TMDBClient.backdropURL(""))
    }

    func testFindAndBackdrop() async throws {
        let client = stubbedClient(key: Self.v4Token) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.v4Token)")
            switch request.url!.path {
            case "/3/find/tt1375666": return (200, try CoreFixtures.data("tmdb_find_movie"))
            case "/3/find/tt0903747": return (200, try CoreFixtures.data("tmdb_find_series"))
            default: return (200, try CoreFixtures.data("tmdb_find_empty"))
            }
        }
        let movie = try await client.backdrop(imdbID: "tt1375666", type: "movie")
        XCTAssertEqual(movie, "https://image.tmdb.org/t/p/w1280/8ZTVqvKDQ8emSGUEMjsS4yHAwrp.jpg")
        let series = try await client.backdrop(imdbID: "tt0903747", type: "series")
        XCTAssertEqual(series, "https://image.tmdb.org/t/p/w1280/tsRy63Mu5cu8etL1X7ZLyf7UP1M.jpg")
        let wrongType = try await client.backdrop(imdbID: "tt1375666", type: "series")
        XCTAssertNil(wrongType, "a movie id has no tv_results")

        let tvID = try await client.tmdbID(imdbID: "tt0903747", kind: .tv)
        XCTAssertEqual(tvID, 1396)
    }

    func testMovieRecommendationsMapToIMDbAndDropUnmappable() async throws {
        let paths = PathLog()
        let client = stubbedClient(key: Self.v3Key) { request in
            paths.append(request.url!.path)
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertTrue(items.contains(URLQueryItem(name: "api_key", value: Self.v3Key)))
            switch request.url!.path {
            case "/3/find/tt1375666": return (200, try CoreFixtures.data("tmdb_find_movie"))
            case "/3/movie/27205/recommendations": return (200, try CoreFixtures.data("tmdb_recommendations_movie"))
            case "/3/movie/155/external_ids": return (200, try CoreFixtures.data("tmdb_external_ids_155"))
            case "/3/movie/157336/external_ids": return (200, try CoreFixtures.data("tmdb_external_ids_157336"))
            case "/3/movie/999001/external_ids": return (200, try CoreFixtures.data("tmdb_external_ids_unmapped"))
            default: return (404, Data())
            }
        }

        let previews = try await client.recommendations(imdbID: "tt1375666", type: "movie", limit: 10)
        XCTAssertEqual(previews.map(\.id), ["tt0468569", "tt0816692"])
        XCTAssertEqual(previews[0], MetaPreview(
            id: "tt0468569", type: "movie", name: "The Dark Knight",
            poster: "https://image.tmdb.org/t/p/w342/qJ2tW6WMUDux911r6m7haRef0WH.jpg", posterShape: "poster",
            releaseInfo: "2008", description: "Batman raises the stakes in his war on crime.", imdbRating: "8.5"))
        XCTAssertNil(previews[1].imdbRating, "zero vote average is omitted")
        XCTAssertFalse(paths.values.contains("/3/movie/27205/similar"))

        let limited = try await client.recommendations(imdbID: "tt1375666", type: "movie", limit: 1)
        XCTAssertEqual(limited.map(\.id), ["tt0468569"])
        XCTAssertEqual(paths.values.count, 5, "second call is served from the session cache")
    }

    func testSeriesFallsBackToSimilarAndUsesPersistentIDCache() async throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tmdb-ids-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let paths = PathLog()
        let handler: @Sendable (URLRequest) throws -> (Int, Data) = { request in
            paths.append(request.url!.path)
            switch request.url!.path {
            case "/3/find/tt0903747": return (200, try CoreFixtures.data("tmdb_find_series"))
            case "/3/tv/1396/recommendations": return (200, try CoreFixtures.data("tmdb_recommendations_empty"))
            case "/3/tv/1396/similar": return (200, try CoreFixtures.data("tmdb_recommendations_series"))
            case "/3/tv/60059/external_ids": return (200, try CoreFixtures.data("tmdb_external_ids_60059"))
            default: return (404, Data())
            }
        }

        let first = stubbedClient(key: Self.v3Key, idCache: TMDBIDCache(fileURL: cacheURL), handler: handler)
        let previews = try await first.recommendations(imdbID: "tt0903747", type: "series", limit: 10)
        XCTAssertEqual(previews.map(\.id), ["tt3032476"])
        XCTAssertEqual(previews.first?.type, "series")
        XCTAssertEqual(previews.first?.releaseInfo, "2015")
        XCTAssertTrue(paths.values.contains("/3/tv/1396/similar"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))

        // Fresh client + fresh recommendation cache, same id cache file: no find/external_ids requests.
        paths.removeAll()
        let second = stubbedClient(key: Self.v3Key, idCache: TMDBIDCache(fileURL: cacheURL), handler: handler)
        let again = try await second.recommendations(imdbID: "tt0903747", type: "series", limit: 10)
        XCTAssertEqual(again, previews)
        XCTAssertEqual(paths.values.sorted(), ["/3/tv/1396/recommendations", "/3/tv/1396/similar"])
    }

    func testInvalidKeyAndRateLimitRetry() async throws {
        let bad = stubbedClient(key: Self.v3Key) { _ in (401, Data(#"{"status_code":7,"success":false}"#.utf8)) }
        do {
            try await bad.validate()
            XCTFail("expected invalidKey")
        } catch {
            XCTAssertEqual(error as? TMDBError, .invalidKey)
        }

        let attempts = PathLog()
        let limited = stubbedClient(key: Self.v3Key) { request in
            attempts.append(request.url!.path)
            return attempts.values.count == 1 ? (429, Data()) : (200, Data("{}".utf8))
        }
        try await limited.validate()
        XCTAssertEqual(attempts.values.count, 2)
    }

    // MARK: Helpers

    private func stubbedClient(
        key: String, idCache: TMDBIDCache = TMDBIDCache(fileURL: nil),
        handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)
    ) -> TMDBClient {
        TMDBStubURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TMDBStubURLProtocol.self]
        return TMDBClient(key: key, session: URLSession(configuration: config),
                          idCache: idCache, recommendationCache: TMDBRecommendationCache())
    }
}

private final class PathLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ path: String) { lock.withLock { storage.append(path) } }
    func removeAll() { lock.withLock { storage.removeAll() } }
}

private final class TMDBStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (status, data) = try XCTUnwrap(Self.handler)(request)
            let headers = status == 429 ? ["Retry-After": "0"] : [:]
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
