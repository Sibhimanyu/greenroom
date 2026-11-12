import XCTest
@testable import GreenroomTests

final class LayoutAppOrderingTests: XCTestCase {
    private func app(_ name: String, browser: Bool = false, running: Bool = false) -> LayoutAppCandidate {
        LayoutAppCandidate(id: name, name: name, isBrowser: browser, isRunning: running)
    }

    private var sample: [LayoutAppCandidate] {
        [app("Automator"), app("Blender"), app("Keynote"), app("Safari", browser: true),
         app("Greenroom Browser", browser: true), app("Calculator", running: true),
         app("Chrome", browser: true), app("Notes"), app("Écran"), app("Arc", browser: true),
         app("Ulaa", browser: true), app("Zed")]
    }

    func testSuggestedOrderBrowsersThenSlidesThenRunning() {
        let r = LayoutAppOrdering.arrange(sample, query: "")
        XCTAssertFalse(r.searching)
        XCTAssertEqual(r.suggested, ["Greenroom Browser", "Safari", "Chrome", "Arc", "Ulaa", "Keynote", "Notes", "Calculator"])
    }

    func testRestIsAlphabeticalAndExcludesSuggested() {
        let r = LayoutAppOrdering.arrange(sample, query: "")
        XCTAssertEqual(r.rest, ["Automator", "Blender", "Écran", "Zed"])
    }

    func testSuggestedIsCapped() {
        let many = (0..<20).map { app("Browser \($0)", browser: true) }
        let r = LayoutAppOrdering.arrange(many, query: "")
        XCTAssertEqual(r.suggested.count, LayoutAppOrdering.suggestedLimit)
        XCTAssertEqual(r.suggested.count + r.rest.count, 20)
    }

    func testSearchIsCaseAndDiacriticInsensitiveAndDropsSections() {
        let r = LayoutAppOrdering.arrange(sample, query: " ecran ")
        XCTAssertTrue(r.searching)
        XCTAssertEqual(r.suggested, [])
        XCTAssertEqual(r.rest, ["Écran"])
        XCTAssertEqual(LayoutAppOrdering.arrange(sample, query: "CALC").rest, ["Calculator"])
    }

    func testSearchWithNoMatch() {
        let r = LayoutAppOrdering.arrange(sample, query: "qqq")
        XCTAssertTrue(r.searching)
        XCTAssertTrue(r.rest.isEmpty)
    }

    func testSearchResultsAlphabetical() {
        XCTAssertEqual(LayoutAppOrdering.arrange(sample, query: "r").rest,
                       ["Arc", "Automator", "Blender", "Calculator", "Chrome", "Écran", "Greenroom Browser", "Safari"].filter { LayoutAppOrdering.fold($0).contains("r") })
    }
}
