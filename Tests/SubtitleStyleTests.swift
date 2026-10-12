import XCTest
@testable import DeStream

final class SubtitleStyleTests: XCTestCase {
    private func property(_ name: String, _ style: SubtitleStyle) -> String? {
        style.mpvProperties.first { $0.name == name }?.value
    }

    func testDefaultsMatchMPV() {
        let style = SubtitleStyle()
        XCTAssertTrue(style.isDefault)
        XCTAssertEqual(property("sub-scale", style), "1.00")
        XCTAssertEqual(property("sub-font", style), "sans-serif")
        XCTAssertEqual(property("sub-color", style), "1.000/1.000/1.000/1.000")
        XCTAssertEqual(property("sub-border-style", style), "outline-and-shadow")
        XCTAssertEqual(property("sub-pos", style), "100")
        XCTAssertEqual(property("sub-ass-override", style), "scale")
    }

    func testCustomStyleMapsToMPVProperties() {
        var style = SubtitleStyle()
        style.size = 1.5
        style.font = .georgia
        style.bold = true
        style.textColor = .yellow
        style.background = true
        style.backgroundOpacity = 0.5
        style.elevation = 0.2
        style.overrideStyledSubtitles = true
        XCTAssertEqual(property("sub-scale", style), "1.50")
        XCTAssertEqual(property("sub-font", style), "Georgia")
        XCTAssertEqual(property("sub-bold", style), "yes")
        XCTAssertEqual(property("sub-color", style), "1.000/0.880/0.200/1.000")
        XCTAssertEqual(property("sub-border-style", style), "background-box")
        XCTAssertEqual(property("sub-back-color", style), "0.000/0.000/0.000/0.500")
        XCTAssertEqual(property("sub-pos", style), "80")
        XCTAssertEqual(property("sub-ass-override", style), "force")
    }

    func testDecodingFillsMissingAndClampsValues() throws {
        let json = #"{"size": 9, "font": "comicSans", "bold": true}"#
        let style = try JSONDecoder().decode(SubtitleStyle.self, from: Data(json.utf8))
        XCTAssertEqual(style.size, SubtitleStyle.sizeRange.upperBound)
        XCTAssertEqual(style.font, .system)
        XCTAssertTrue(style.bold)
        XCTAssertEqual(style.textColor, .white)
    }

    @MainActor
    func testAppSettingsPersistsStyle() {
        let suite = "SubtitleStyleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.subtitleStyle.isDefault)
        settings.subtitleStyle.size = 1.25
        settings.subtitleStyle.textColor = .cyan
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.subtitleStyle.size, 1.25)
        XCTAssertEqual(reloaded.subtitleStyle.textColor, .cyan)
    }
}
