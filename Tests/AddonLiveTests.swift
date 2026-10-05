import XCTest
@testable import DeStream

/// Hits the real Cinemeta. Opt in with `TEST_RUNNER_DESTREAM_LIVE=1 scripts/build.sh <name> test`.
final class AddonLiveTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DESTREAM_LIVE"] == "1", "set DESTREAM_LIVE=1 to run network tests")
    }

    func testCinemetaLive() async throws {
        let client = AddonClient()
        let manifest = try await client.fetchManifest(from: AddonRegistry.cinemetaManifestURL)
        let addon = Addon(id: UUID(), manifestURL: AddonRegistry.cinemetaManifestURL, manifest: manifest, enabled: true, order: 0)

        let top = try await client.catalog(addon, type: "movie", id: "top")
        XCTAssertGreaterThan(top.count, 10)
        let page2 = try await client.catalog(addon, type: "movie", id: "top", skip: 100)
        XCTAssertFalse(page2.isEmpty)
        let genre = try await client.catalog(addon, type: "series", id: "top", genre: "Sci-Fi")
        XCTAssertFalse(genre.isEmpty)

        let search = try await client.catalog(addon, type: "series", id: "top", search: "breaking bad")
        XCTAssertTrue(search.contains { $0.id == "tt0903747" })

        let meta = try await client.meta(addon, type: "series", id: "tt0903747")
        XCTAssertEqual(meta.name, "Breaking Bad")
        XCTAssertEqual(meta.episodes(season: 1).count, 7)
    }
}
