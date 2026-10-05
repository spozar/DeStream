import XCTest
@testable import DeStream

final class StremioAPITests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    // MARK: Requests

    func testRequestBodies() throws {
        let login = try json(Requests.Login(email: "a@b.c", password: "pw"))
        XCTAssertEqual(login as NSDictionary, ["type": "Login", "email": "a@b.c", "password": "pw", "facebook": false])

        let get = try json(Requests.AddonCollectionGet(authKey: "k"))
        XCTAssertEqual(get as NSDictionary, ["type": "AddonCollectionGet", "authKey": "k", "update": true])

        let logout = try json(Requests.Typed(type: "Logout", authKey: "k"))
        XCTAssertEqual(logout as NSDictionary, ["type": "Logout", "authKey": "k"])

        let meta = try json(Requests.DatastoreMeta(authKey: "k", collection: "libraryItem"))
        XCTAssertEqual(meta as NSDictionary, ["authKey": "k", "collection": "libraryItem"])

        let all = try json(Requests.DatastoreGet(authKey: "k", collection: "libraryItem", ids: [], all: true))
        XCTAssertEqual(all as NSDictionary, ["authKey": "k", "collection": "libraryItem", "ids": [], "all": true])

        let put = try json(Requests.DatastorePut(authKey: "k", collection: "libraryItem", changes: []))
        XCTAssertEqual(put as NSDictionary, ["authKey": "k", "collection": "libraryItem", "changes": []])
    }

    // MARK: Responses

    func testLoginResponse() async throws {
        let api = stubbedAPI { request in
            XCTAssertEqual(request.url?.lastPathComponent, "login")
            return (200, try CoreFixtures.data("stremio_login"))
        }
        let (key, user) = try await api.login(email: "user@example.com", password: "pw")
        XCTAssertEqual(key, "test-auth-key-123")
        XCTAssertEqual(user, StremioUser(id: "5f1a2b3c4d5e6f7a8b9c0d1e", email: "user@example.com", fullname: "Test User"))
    }

    func testErrorMapping() async throws {
        let session = try CoreFixtures.data("stremio_error_session")
        XCTAssertThrowsError(try StremioAPI.decodeEnvelope([StremioItemMeta].self, from: session)) {
            XCTAssertEqual($0 as? StremioAPIError, .unauthorized)
        }

        let credentials = Data(#"{"error":{"code":3,"message":"Wrong passphrase"}}"#.utf8)
        var api = stubbedAPI { _ in (200, credentials) }
        await assertThrows(.invalidCredentials) { _ = try await api.login(email: "a", password: "b") }

        let other = Data(#"{"error":{"code":42,"message":"Something broke"}}"#.utf8)
        api = stubbedAPI { _ in (500, other) }
        await assertThrows(.server("Something broke")) { _ = try await api.getUser(authKey: "k") }

        api = stubbedAPI { _ in (502, Data("<html>".utf8)) }
        await assertThrows(.server("Stremio server error (HTTP 502)")) { try await api.logout(authKey: "k") }
    }

    func testAddonCollection() async throws {
        let api = stubbedAPI { request in
            let body = try XCTUnwrap(request.bodyData)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["type"] as? String, "AddonCollectionGet")
            return (200, try CoreFixtures.data("stremio_addon_collection"))
        }
        let addons = try await api.addonCollection(authKey: "k")
        XCTAssertEqual(addons.count, 2, "descriptor without transportUrl is skipped")
        XCTAssertEqual(addons[0].manifestID, "com.linvo.cinemeta")
        XCTAssertEqual(addons[0].flags, .init(official: true, protected: true))
        XCTAssertEqual(addons[1].flags, .init())

        let reencoded = try JSONDecoder().decode(StremioAddonDescriptor.self, from: JSONEncoder().encode(addons[0]))
        XCTAssertEqual(reencoded, addons[0])
    }

    func testDatastoreMeta() throws {
        let meta = try StremioAPI.decodeEnvelope([StremioItemMeta].self, from: CoreFixtures.data("stremio_datastore_meta"))
        XCTAssertEqual(meta.map(\.id), ["tt0903747", "tt0111161"])
        XCTAssertEqual(meta[0].mtime.timeIntervalSince1970, 1_714_566_645.123, accuracy: 0.0005)
    }

    func testLibraryItemsDecodeAndRoundTrip() throws {
        let items = try StremioAPI.decodeEnvelope(
            LossyArray<StremioLibraryItem>.self, from: CoreFixtures.data("stremio_library_items")).elements
        XCTAssertEqual(items.count, 2, "item without _id is skipped")

        let bb = items[0]
        XCTAssertEqual(bb.id, "tt0903747")
        XCTAssertEqual(bb.type, "series")
        XCTAssertFalse(bb.removed)
        XCTAssertEqual(bb.mtime.timeIntervalSince1970, 1_714_566_645.123, accuracy: 0.0005)
        XCTAssertEqual(bb.state.videoId, "tt0903747:1:5")
        XCTAssertEqual(bb.state.timeOffset, 1_234_567)
        XCTAssertEqual(bb.state.timesWatched, 12)
        XCTAssertEqual(bb.state.extra["season"], .number(1))
        XCTAssertEqual(bb.extra["year"], .string("2008–2013"))
        XCTAssertEqual(bb.behaviorHints?["hasScheduledVideos"], .bool(false))

        let movie = items[1]
        XCTAssertNil(movie.poster)
        XCTAssertNil(movie.ctime)
        XCTAssertNil(movie.state.lastWatched)
        XCTAssertNil(movie.state.videoId)
        XCTAssertEqual(movie.state.overallTimeWatched, 8_520_000)
        XCTAssertTrue(movie.removed && movie.temp)

        let data = try JSONEncoder().encode(items)
        XCTAssertEqual(try JSONDecoder().decode([StremioLibraryItem].self, from: data), items)

        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])[0]
        XCTAssertEqual(wire["_id"] as? String, "tt0903747")
        XCTAssertEqual(wire["_mtime"] as? String, "2024-05-01T12:30:45.123Z")
        XCTAssertEqual(wire["_ctime"] as? String, "2023-01-10T08:00:00.000Z")
        XCTAssertEqual(wire["year"] as? String, "2008–2013")
        let state = try XCTUnwrap(wire["state"] as? [String: Any])
        XCTAssertEqual(state["video_id"] as? String, "tt0903747:1:5")
        XCTAssertEqual(state["timeOffset"] as? Int, 1_234_567)
        XCTAssertEqual(state["season"] as? Int, 1)
        XCTAssertNil(state["videoId"])
    }

    func testLibraryGetRequestShape() async throws {
        let api = stubbedAPI { request in
            XCTAssertEqual(request.url?.lastPathComponent, "datastoreGet")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.bodyData)) as? [String: Any])
            XCTAssertEqual(object["ids"] as? [String], ["tt0903747"])
            XCTAssertEqual(object["all"] as? Bool, false)
            XCTAssertEqual(object["collection"] as? String, "libraryItem")
            return (200, try CoreFixtures.data("stremio_library_items"))
        }
        let items = try await api.libraryItems(ids: ["tt0903747"], authKey: "k")
        XCTAssertEqual(items.count, 2)
    }

    // MARK: Watched bitfield (vectors from stremio-core's stremio-watched-bitfield tests)

    func testBitfieldParseAndModify() {
        let videos = (1...9).map { "tt2934286:1:\($0)" }
        let serialized = "tt2934286:1:5:5:eJyTZwAAAEAAIA=="
        var watched = WatchedBitfield.decode(serialized, videoIDs: videos)
        XCTAssertEqual(watched, Set(videos.prefix(5)))
        XCTAssertEqual(WatchedBitfield.encode(watched: watched, videoIDs: videos), serialized)

        watched.insert("tt2934286:1:6")
        let updated = WatchedBitfield.encode(watched: watched, videoIDs: videos)
        XCTAssertTrue(updated.hasPrefix("tt2934286:1:6:6:"))
        XCTAssertEqual(WatchedBitfield.decode(updated, videoIDs: videos), Set(videos.prefix(6)))
    }

    func testBitfieldEmpty() {
        XCTAssertEqual(WatchedBitfield.encode(watched: [], videoIDs: []), "undefined:1:eJwDAAAAAAE=")
        XCTAssertEqual(WatchedBitfield.decode("undefined:1:eJwDAAAAAAE=", videoIDs: []), [])
        XCTAssertEqual(WatchedBitfield.unpack("eJyTZwAAAEAAIA=="), [31, 0])
        XCTAssertEqual(WatchedBitfield.unpack("eJz7//8/AAX9Av4="), [255, 255, 255])
    }

    func testBitfieldLargeRoundTrip() {
        let videos = (1..<500).map { "tt2934286:1:\($0)" }
        let half = Set(videos.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element))
        let serialized = WatchedBitfield.encode(watched: half, videoIDs: videos)
        XCTAssertEqual(WatchedBitfield.decode(serialized, videoIDs: videos), half)
    }

    func testBitfieldAnchorShiftWhenEpisodesInserted() {
        // "tt7767422:3:8" anchored at length 24 with all 24 bits set.
        let old = (1...24).map { "tt7767422:3:\($0 - 16)" }
        XCTAssertEqual(old[23], "tt7767422:3:8")
        let field = "tt7767422:3:8:24:eJz7//8/AAX9Av4="
        XCTAssertEqual(WatchedBitfield.decode(field, videoIDs: old), Set(old))

        let grown = ["new:a", "new:b"] + old + ["tt7767422:3:9"]
        XCTAssertEqual(WatchedBitfield.decode(field, videoIDs: grown), Set(old))
        XCTAssertEqual(WatchedBitfield.decode(field, videoIDs: ["other"]), [])
        XCTAssertEqual(WatchedBitfield.decode("garbage", videoIDs: old), [])
    }

    func testAnchorWithColonsAndLastWatched() {
        let videos = (1...20).map { "tt0:1:\($0)" }
        let s = WatchedBitfield.encode(watched: ["tt0:1:16"], videoIDs: videos)
        XCTAssertTrue(s.hasPrefix("tt0:1:16:16:"))
        XCTAssertEqual(WatchedBitfield.decode(s, videoIDs: videos), ["tt0:1:16"])
    }

    func testDates() {
        XCTAssertEqual(StremioDate.string(Date(timeIntervalSince1970: 1_700_000_000.123)), "2023-11-14T22:13:20.123Z")
        XCTAssertEqual(StremioDate.parse("2023-11-14T22:13:20Z"), Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: Helpers

    private func stubbedAPI(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) -> StremioAPI {
        StubURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return StremioAPI(baseURL: URL(string: "https://api.test/api/")!, session: URLSession(configuration: config))
    }

    private func assertThrows(
        _ expected: StremioAPIError, file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? StremioAPIError, expected, file: file, line: line)
        }
    }
}

private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (status, data) = try XCTUnwrap(Self.handler)(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLRequest {
    /// URLProtocol receives bodies as a stream.
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
