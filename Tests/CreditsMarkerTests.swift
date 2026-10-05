import XCTest
@testable import DeStream

final class CreditsMarkerTests: XCTestCase {
    func testCreditsChapterWins() {
        let chapters = [PlayerChapter(title: "Intro", time: 0), PlayerChapter(title: "Chapter 2", time: 600),
                        PlayerChapter(title: "End Credits", time: 2700), PlayerChapter(title: "Preview", time: 2800)]
        XCTAssertEqual(CreditsMarker.start(duration: 2900, chapters: chapters), 2700)
    }

    func testCreditsChapterInFirstHalfIsIgnored() {
        let chapters = [PlayerChapter(title: "Opening Credits", time: 30)]
        XCTAssertEqual(CreditsMarker.start(duration: 3000, chapters: chapters), 3000 - 105)
    }

    func testFallbackLeadScalesWithRuntime() {
        XCTAssertEqual(CreditsMarker.fallbackLead(duration: 22 * 60), 46.2, accuracy: 0.01)
        XCTAssertEqual(CreditsMarker.fallbackLead(duration: 10 * 60), 30)
        XCTAssertEqual(CreditsMarker.fallbackLead(duration: 70 * 60), 120)
        XCTAssertNil(CreditsMarker.start(duration: 120, chapters: []), "shorts get no prompt")
        XCTAssertNil(CreditsMarker.start(duration: nil, chapters: []))
    }

    func testCreditsTitles() {
        for title in ["ED", "Ending", "End Credits", "Credits", "Outro", "Closing Credits", "ending theme"] {
            XCTAssertTrue(CreditsMarker.isCredits(title), title)
        }
        for title in ["Chapter 12", "The End of the World", "Opening", "OP", nil] {
            XCTAssertFalse(CreditsMarker.isCredits(title), title ?? "nil")
        }
    }
}
