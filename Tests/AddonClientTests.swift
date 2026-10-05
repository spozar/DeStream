import XCTest
@testable import DeStream

/// Serves canned responses for exact URLs. Unknown URLs fail with `URLError(.cannotFindHost)`.
final class AddonMockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Route: Sendable {
        var status = 200
        var body = Data()
        var delay: TimeInterval = 0
        var error: URLError.Code?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Route] = [:]
    nonisolated(unsafe) private static var requested: [String] = []

    static func set(_ url: String, _ route: Route) { lock.withLock { routes[url] = route } }
    static func set(_ url: String, json: String, status: Int = 200, delay: TimeInterval = 0) {
        set(url, Route(status: status, body: Data(json.utf8), delay: delay))
    }
    static func set(_ url: String, fixture: String) throws { set(url, Route(body: try CoreFixtures.data(fixture))) }
    static func requests() -> [String] { lock.withLock { requested } }
    static func reset() { lock.withLock { routes = [:]; requested = [] } }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AddonMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var cancelled = false

    override func startLoading() {
        let key = request.url?.absoluteString ?? ""
        let route = Self.lock.withLock { Self.requested.append(key); return Self.routes[key] }
        let deliver: @Sendable () -> Void = { [self] in
            guard !self.cancelled else { return }
            guard let route else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
                return
            }
            if let code = route.error {
                self.client?.urlProtocol(self, didFailWithError: URLError(code))
                return
            }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: route.status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: route.body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        let delay = route?.delay ?? 0
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() { cancelled = true }
}

final class AddonClientURLTests: XCTestCase {
    private let base = URL(string: "https://addon.example/CONFIG")!

    func testSimpleResources() {
        XCTAssertEqual(AddonClient.resourceURL(base: base, resource: "catalog", type: "movie", id: "top")?.absoluteString,
                       "https://addon.example/CONFIG/catalog/movie/top.json")
        XCTAssertEqual(AddonClient.resourceURL(base: base, resource: "meta", type: "series", id: "tt0903747")?.absoluteString,
                       "https://addon.example/CONFIG/meta/series/tt0903747.json")
        XCTAssertEqual(AddonClient.resourceURL(base: base, resource: "stream", type: "series", id: "tt0903747:1:1")?.absoluteString,
                       "https://addon.example/CONFIG/stream/series/tt0903747:1:1.json")
    }

    func testTrailingSlashBase() {
        XCTAssertEqual(AddonClient.resourceURL(base: URL(string: "https://addon.example/")!, resource: "meta", type: "movie", id: "tt1")?.absoluteString,
                       "https://addon.example/meta/movie/tt1.json")
    }

    func testIdWithUnsafeCharacters() {
        XCTAssertEqual(AddonClient.resourceURL(base: base, resource: "meta", type: "movie", id: "a/b c?d#e%")?.absoluteString,
                       "https://addon.example/CONFIG/meta/movie/a%2Fb%20c%3Fd%23e%25.json")
    }

    func testExtras() {
        let extras = AddonClient.catalogExtras(search: "breaking bad", skip: 100, genre: "Sci-Fi")
        XCTAssertEqual(AddonClient.resourceURL(base: base, resource: "catalog", type: "series", id: "top", extras: extras)?.absoluteString,
                       "https://addon.example/CONFIG/catalog/series/top/search=breaking%20bad&genre=Sci-Fi&skip=100.json")
    }

    func testGenreAndSkip() {
        let extras = AddonClient.catalogExtras(search: nil, skip: 100, genre: "Action")
        XCTAssertEqual(AddonClient.resourceURL(base: base, resource: "catalog", type: "movie", id: "top", extras: extras)?.absoluteString,
                       "https://addon.example/CONFIG/catalog/movie/top/genre=Action&skip=100.json")
    }

    func testGenreValuesAreEncoded() {
        let extras = AddonClient.catalogExtras(search: nil, skip: nil, genre: "Action & Adventure/Sci-Fi+")
        XCTAssertEqual(AddonClient.resourceURL(base: base, resource: "catalog", type: "series", id: "top", extras: extras)?.absoluteString,
                       "https://addon.example/CONFIG/catalog/series/top/genre=Action%20%26%20Adventure%2FSci-Fi%2B.json")
    }

    func testExtrasFollowDeclaredOrder() {
        let extras = AddonClient.catalogExtras(search: "x", skip: 20, genre: "2024", order: ["skip", "genre"])
        XCTAssertEqual(extras.map(\.0), ["skip", "genre", "search"], "undeclared extras go last")
        XCTAssertEqual(AddonClient.catalogExtras(search: "x", skip: 20, genre: "Drama", order: ["genre", "search", "skip"]).map(\.0),
                       ["genre", "search", "skip"])
    }

    func testExtrasEscapeDelimiters() {
        let extras = AddonClient.catalogExtras(search: "AC/DC & co=1+2 é", skip: nil, genre: nil)
        XCTAssertEqual(AddonClient.resourceURL(base: base, resource: "catalog", type: "movie", id: "top", extras: extras)?.absoluteString,
                       "https://addon.example/CONFIG/catalog/movie/top/search=AC%2FDC%20%26%20co%3D1%2B2%20%C3%A9.json")
    }

    func testEmptyExtrasOmitted() {
        XCTAssertTrue(AddonClient.catalogExtras(search: "  ", skip: 0, genre: "").isEmpty)
        XCTAssertEqual(AddonClient.catalogExtras(search: nil, skip: 50, genre: nil).map(\.0), ["skip"])
    }
}

final class AddonClientNetworkTests: XCTestCase {
    private let secret = "U0VDUkVULVRPUkJPWC1LRVk"
    private var client: AddonClient { AddonClient(session: AddonMockURLProtocol.session()) }

    override func setUp() { AddonMockURLProtocol.reset() }

    private func addon(_ manifestURL: String) throws -> Addon {
        Addon(id: UUID(), manifestURL: manifestURL, manifest: try CoreFixtures.decode(Manifest.self, "comet_manifest"), enabled: true, order: 0)
    }

    func testFetchManifestAcceptsStremioScheme() async throws {
        try AddonMockURLProtocol.set("https://client.test/manifest.json", fixture: "cinemeta_manifest")
        let m = try await client.fetchManifest(from: "stremio://client.test/manifest.json")
        XCTAssertEqual(m.id, "com.linvo.cinemeta")
    }

    func testFetchManifestRejectsNonHTTP() async {
        do {
            _ = try await client.fetchManifest(from: "ftp://x.test/manifest.json")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual((error as? AddonError)?.errorDescription, AddonError.invalidURL.errorDescription)
        }
    }

    func testCatalogSearchAndStreams() async throws {
        let a = try addon("https://client.test/\(secret)/manifest.json")
        try AddonMockURLProtocol.set("https://client.test/\(secret)/catalog/series/top/search=breaking%20bad.json", fixture: "cinemeta_search_series")
        try AddonMockURLProtocol.set("https://client.test/\(secret)/stream/series/tt0903747:1:1.json", fixture: "comet_streams_sample")
        let metas = try await client.catalog(a, type: "series", id: "top", search: "breaking bad")
        XCTAssertEqual(metas.count, 5)
        let streams = try await client.streams(a, type: "series", id: "tt0903747:1:1")
        XCTAssertEqual(streams.count, 4)
    }

    func testCatalogGenrePagingUsesManifestOrder() async throws {
        let manifest = try CoreFixtures.decode(Manifest.self, "catalog_extras_manifest")
        let a = Addon(id: UUID(), manifestURL: "https://client.test/\(secret)/manifest.json", manifest: manifest, enabled: true, order: 0)
        try AddonMockURLProtocol.set("https://client.test/\(secret)/catalog/movie/trending/genre=Sci-Fi&skip=100.json",
                                     fixture: "cinemeta_catalog_movie_top")
        try AddonMockURLProtocol.set("https://client.test/\(secret)/catalog/movie/by-year/skip=50&genre=2025.json",
                                     fixture: "cinemeta_catalog_movie_top")
        let page = try await client.catalog(a, type: "movie", id: "trending", skip: 100, genre: "Sci-Fi")
        XCTAssertFalse(page.isEmpty)
        let byYear = try await client.catalog(a, type: "movie", id: "by-year", skip: 50, genre: "2025")
        XCTAssertEqual(byYear.count, page.count)
    }

    func testErrorsAreRedacted() async throws {
        let a = try addon("https://client.test/\(secret)/manifest.json")
        AddonMockURLProtocol.set("https://client.test/\(secret)/meta/movie/tt1.json", json: "oops", status: 500)
        AddonMockURLProtocol.set("https://client.test/\(secret)/meta/movie/tt2.json", json: "<html>")
        AddonMockURLProtocol.set("https://client.test/\(secret)/stream/movie/tt3.json", json: #"{"err":"rate limited"}"#)
        AddonMockURLProtocol.set("https://client.test/\(secret)/meta/movie/tt4.json", json: #"{"meta":null}"#)

        var messages: [String] = []
        for id in ["tt1", "tt2", "tt5"] {
            do { _ = try await client.meta(a, type: "movie", id: id); XCTFail() } catch { messages.append(error.localizedDescription) }
        }
        do { _ = try await client.streams(a, type: "movie", id: "tt3"); XCTFail() } catch { messages.append(error.localizedDescription) }
        do { _ = try await client.meta(a, type: "movie", id: "tt4"); XCTFail() } catch {
            guard case AddonError.notFound = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(messages[0], "https://client.test/… returned HTTP 500")
        XCTAssertTrue(messages[1].contains("unexpected response"))
        XCTAssertEqual(messages[2], "https://client.test/… could not be reached: host not found")
        XCTAssertEqual(messages[3], "https://client.test/… reported an error: rate limited")
        for m in messages { XCTAssertFalse(m.contains(secret), m) }
    }
}
