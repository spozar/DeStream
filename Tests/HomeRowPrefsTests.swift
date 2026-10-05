import XCTest
@testable import DeStream

final class HomeRowPrefsTests: XCTestCase {
    private func row(_ addon: String, _ catalog: String, type: String = "movie") -> HomeRowID {
        HomeRowID(manifestID: addon, type: type, catalogID: catalog)
    }

    private lazy var top = row("cinemeta", "top")
    private lazy var year = row("cinemeta", "year")
    private lazy var netflix = row("streaming", "nfx")
    private lazy var hbo = row("streaming", "hbo")
    private lazy var installed = [top, year, netflix, hbo]

    func testDefaultKeepsRegistryOrderAndShowsEverything() {
        let prefs = HomeRowPrefs()
        XCTAssertEqual(prefs.visible(installed, id: { $0 }), installed)
        XCTAssertTrue(prefs.isDefault)
    }

    func testHiddenRowsAreFilteredButStillArranged() {
        var prefs = HomeRowPrefs()
        prefs.setHidden(year, true)
        XCTAssertEqual(prefs.visible(installed, id: { $0 }), [top, netflix, hbo])
        XCTAssertEqual(prefs.arranged(installed, id: { $0 }), installed)
        prefs.setHidden(year, false)
        XCTAssertTrue(prefs.isDefault)
    }

    func testMoveFollowsSwiftUIOffsets() {
        var prefs = HomeRowPrefs()
        prefs.move(fromOffsets: [3], toOffset: 0, in: installed)
        XCTAssertEqual(prefs.arranged(installed, id: { $0 }), [hbo, top, year, netflix])
        prefs.move(fromOffsets: [0], toOffset: 4, in: prefs.arranged(installed, id: { $0 }))
        XCTAssertEqual(prefs.arranged(installed, id: { $0 }), installed)
    }

    func testNewCatalogsAppendAtEndVisible() {
        var prefs = HomeRowPrefs()
        prefs.move(fromOffsets: [2], toOffset: 0, in: installed)
        let kitsu = row("kitsu", "trending", type: "anime")
        let withNew = [kitsu, top, year, netflix, hbo]
        XCTAssertEqual(prefs.visible(withNew, id: { $0 }), [netflix, top, year, hbo, kitsu])
    }

    func testRemovedAddonPrefsAreIgnoredAndRestoredOnReinstall() {
        var prefs = HomeRowPrefs()
        prefs.move(fromOffsets: [3], toOffset: 0, in: installed)
        prefs.setHidden(netflix, true)
        let cinemetaOnly = [top, year]
        XCTAssertEqual(prefs.visible(cinemetaOnly, id: { $0 }), [top, year])

        prefs.move(fromOffsets: [1], toOffset: 0, in: prefs.arranged(cinemetaOnly, id: { $0 }))
        XCTAssertEqual(prefs.arranged(cinemetaOnly, id: { $0 }), [year, top])
        XCTAssertEqual(prefs.visible(installed, id: { $0 }), [year, top, hbo])
    }

    func testDuplicateIDsKeepRegistryOrder() {
        struct Item: Equatable { let id: HomeRowID; let n: Int }
        var prefs = HomeRowPrefs()
        prefs.move(fromOffsets: [1], toOffset: 0, in: [top, netflix])
        let items = [Item(id: top, n: 1), Item(id: netflix, n: 2), Item(id: top, n: 3)]
        XCTAssertEqual(prefs.arranged(items, id: \.id).map(\.n), [2, 1, 3])
    }

    func testMoveVisibleSkipsHiddenNeighbours() {
        var prefs = HomeRowPrefs()
        prefs.setHidden(year, true)
        prefs.moveVisible(netflix, up: true, in: installed)
        XCTAssertEqual(prefs.visible(installed, id: { $0 }), [netflix, top, hbo])
        prefs.moveVisible(netflix, up: true, in: prefs.arranged(installed, id: { $0 }))
        XCTAssertEqual(prefs.visible(installed, id: { $0 }), [netflix, top, hbo])
        prefs.moveVisible(top, up: false, in: prefs.arranged(installed, id: { $0 }))
        XCTAssertEqual(prefs.visible(installed, id: { $0 }), [netflix, hbo, top])
    }

    func testCodableRoundTripAndLenientDecoding() throws {
        var prefs = HomeRowPrefs()
        prefs.setHidden(hbo, true)
        prefs.showsGenres = false
        prefs.move(fromOffsets: [1], toOffset: 0, in: installed)
        let decoded = try JSONDecoder().decode(HomeRowPrefs.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(decoded, prefs)
        XCTAssertEqual(try JSONDecoder().decode(HomeRowPrefs.self, from: Data("{}".utf8)), HomeRowPrefs())
    }
}
