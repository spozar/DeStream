import XCTest
@testable import DeStream

final class StreamQualityTests: XCTestCase {
    private func stream(name: String? = nil, title: String? = nil, description: String? = nil, filename: String? = nil) -> DeStream.Stream {
        DeStream.Stream(url: "https://example.com/v.mkv", name: name, title: title, description: description,
               behaviorHints: filename.map { StreamBehaviorHints(filename: $0) })
    }

    func testParseTokens() {
        let cases: [(String, StreamQuality)] = [
            ("Comet | TorBox ⚡ 2160p", .uhd),
            ("[TB⚡] Comet 4K", .uhd),
            ("Torrentio\n4k DV | HDR", .uhd),
            ("Movie.2019.UHD.BluRay.x265", .uhd),
            ("Movie.2019.1080p.WEB-DL", .fhd),
            ("Movie.2019.1080i.HDTV", .fhd),
            ("Movie 1440p", .fhd),
            ("Full HD release", .fhd),
            ("FHD", .fhd),
            ("Comet 720p", .hd),
            ("Show S01E01 HD", .hd),
            ("Movie.480p.DVDRip", .sd),
            ("Movie.DVDRip.XviD", .sd),
            ("Movie 576p", .sd),
            ("Comet Unknown", .unknown),
            ("", .unknown),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(StreamQuality.parse(text), expected, text)
        }
    }

    func testFalsePositivesAreIgnored() {
        XCTAssertEqual(StreamQuality.parse("Movie.HDR10.DTS-HD.MA.5.1"), .unknown)
        XCTAssertEqual(StreamQuality.parse("Movie.HDTV.x264"), .unknown)
        XCTAssertEqual(StreamQuality.parse("Movie.SDR.WEB"), .unknown)
        XCTAssertEqual(StreamQuality.parse("Movie.x264.AAC"), .unknown)
        XCTAssertEqual(StreamQuality.parse("12160p"), .unknown)
    }

    func testExplicitLineCountBeatsMarketingWord() {
        XCTAssertEqual(StreamQuality.parse("Movie.4K.Remastered.1080p.BluRay"), .fhd)
        XCTAssertEqual(StreamQuality.parse("Movie.UHD.720p"), .hd)
    }

    func testFieldPriority() {
        XCTAssertEqual(stream(name: "Comet 1080p", description: "The 4K Restoration").quality, .fhd)
        XCTAssertEqual(stream(name: "Comet Unknown", filename: "Movie.2160p.mkv").quality, .uhd)
        XCTAssertEqual(stream(name: "Comet", description: "Movie.720p.WEB\n💾 1.1 GB").quality, .hd)
        XCTAssertEqual(stream(name: "Addon", title: "Movie.480p.avi").quality, .sd)
        XCTAssertEqual(stream(name: "Addon").quality, .unknown)
    }

    func testCometFixture() throws {
        let response = try CoreFixtures.decode(StreamResponse.self, "comet_streams_sample")
        XCTAssertEqual(response.streams.map(\.quality), [.uhd, .fhd, .hd, .sd])
    }

    func testBestPrefersQualityThenFallsBack() {
        let items = [
            AddonStream(id: "a", addonName: "Comet", addonID: "x", stream: stream(name: "[TB⚡] Comet 2160p")),
            AddonStream(id: "b", addonName: "Comet", addonID: "x", stream: stream(name: "[TB⬇️] Comet 720p")),
            AddonStream(id: "c", addonName: "Comet", addonID: "x", stream: stream(name: "[TB⚡] Comet 1080p")),
        ]
        XCTAssertEqual(StreamCache.best(in: items, preferring: nil)?.id, "a")
        XCTAssertEqual(StreamCache.best(in: items, preferring: .fhd)?.id, "c")
        XCTAssertEqual(StreamCache.best(in: items, preferring: .hd)?.id, "a", "uncached 720p is skipped, falls back to the first cached")
    }
}
