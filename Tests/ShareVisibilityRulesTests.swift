import XCTest

final class ShareVisibilityRulesTests: XCTestCase {
    func testWordsAndIconsForEachState() {
        XCTAssertEqual(ShareVisibility.classSees.label, "Class sees this")
        XCTAssertEqual(ShareVisibility.onlyYou.label, "Only you")
        XCTAssertEqual(ShareVisibility.classSees.symbol, "eye")
        XCTAssertEqual(ShareVisibility.onlyYou.symbol, "eye.slash")
        XCTAssertEqual(ShowOnShare.borderLabel, "Class sees this")
    }

    func testMarkedMeansTheClassSees() {
        XCTAssertEqual(ShareVisibility(marked: true), .classSees)
        XCTAssertEqual(ShareVisibility(marked: false), .onlyYou)
        // On, but the share is an app: nothing goes out, so it reads "Only you".
        XCTAssertEqual(ShareVisibility(marked: ShowOnShare.marksWindow(on: true, kind: .app)), .onlyYou)
        XCTAssertEqual(ShareVisibility(marked: ShowOnShare.marksWindow(on: true, kind: .display)), .classSees)
    }

    func testFrostedWhenHiddenSolidWithEdgeWhenSeen() {
        XCTAssertEqual(ShareVisibility.onlyYou.backdrop, .frosted)
        XCTAssertEqual(ShareVisibility.classSees.backdrop, .solid)
        XCTAssertFalse(WindowBackdrop.frosted.hasEdge)
        XCTAssertTrue(WindowBackdrop.solid.hasEdge)
    }

    func testTransitionIsInstantUnderReduceMotion() {
        XCTAssertEqual(WindowBackdrop.transitionDuration(reduceMotion: true), 0)
        XCTAssertGreaterThan(WindowBackdrop.transitionDuration(reduceMotion: false), 0)
    }

    func testToastOnlyOnAChangeAndOnlyOnce() {
        XCTAssertEqual(ShareVisibilityExplainer.toast(was: .onlyYou, now: .classSees, alreadyExplained: false),
                       "The class sees this window.")
        XCTAssertEqual(ShareVisibilityExplainer.toast(was: .classSees, now: .onlyYou, alreadyExplained: false),
                       "Hidden from the class. Only you see this window.")
        XCTAssertNil(ShareVisibilityExplainer.toast(was: .onlyYou, now: .onlyYou, alreadyExplained: false))
        XCTAssertNil(ShareVisibilityExplainer.toast(was: .onlyYou, now: .classSees, alreadyExplained: true))
    }

    func testExplainedFlagIsPerMac() {
        let defaults = UserDefaults(suiteName: "ShareVisibilityRulesTests")!
        defaults.removePersistentDomain(forName: "ShareVisibilityRulesTests")
        XCTAssertFalse(ShareVisibilityExplainer.hasExplained(defaults))
        ShareVisibilityExplainer.markExplained(defaults)
        XCTAssertTrue(ShareVisibilityExplainer.hasExplained(defaults))
        defaults.removePersistentDomain(forName: "ShareVisibilityRulesTests")
    }
}
