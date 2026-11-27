import XCTest
@testable import GreenroomTests

/// R10 (Start over), R11 (Use a different app), R12 (Find my app).
final class ZoomStartOverRulesTests: XCTestCase {
    private let id = "AbC_123-xyZ789qrstuvw1"

    private func facts(sdk: Int = 0, s2s: Int = 0) -> ZoomGuideFlowFacts {
        ZoomGuideFlowFacts(sdkFilled: sdk, s2sFilled: s2s, check: .notRun)
    }

    // MARK: R10

    func testStartOverShowsWheneverAnyKeyIsFilled() {
        XCTAssertFalse(ZoomStartOverRules.isShown(facts()))
        XCTAssertTrue(ZoomStartOverRules.isShown(facts(sdk: 1)))
        XCTAssertTrue(ZoomStartOverRules.isShown(facts(s2s: 3)))
    }

    func testTheConfirmationWords() {
        XCTAssertEqual(ZoomStartOverRules.buttonTitle, "Start over\u{2026}")
        XCTAssertEqual(ZoomStartOverRules.title, "Remove your Zoom keys from Greenroom?")
        XCTAssertEqual(ZoomStartOverRules.message,
                       "Greenroom forgets both apps\u{2019} keys on this Mac and signs out of Zoom here. Your apps in Zoom stay as they are, and you can fill the keys in again from Zoom.")
        XCTAssertEqual(ZoomStartOverRules.confirmTitle, "Remove keys")
        for t in [ZoomStartOverRules.title, ZoomStartOverRules.message] { XCTAssertFalse(t.lowercased().contains("class")) }
    }

    func testDisabledWhileASessionIsLive() {
        XCTAssertEqual(ZoomStartOverRules.help(inSession: true), "End the meeting first.")
        XCTAssertNotEqual(ZoomStartOverRules.help(inSession: false), "End the meeting first.")
    }

    func testStartOverClearsAllFiveKeysAndBothParts() {
        XCTAssertEqual(ZoomStartOverRules.fields(for: .meetingApp), [.clientID, .clientSecret])
        XCTAssertEqual(ZoomStartOverRules.fields(for: .hostingApp), [.accountID, .clientID, .clientSecret])
        XCTAssertTrue(ZoomStartOverRules.fields(for: .check).isEmpty)
        XCTAssertEqual(ZoomStartOverRules.fields(for: .meetingApp).count + ZoomStartOverRules.fields(for: .hostingApp).count, 5)
    }

    // MARK: R11

    func testUseADifferentAppShowsOnlyOnADonePart() {
        XCTAssertTrue(ZoomStartOverRules.showsUseDifferentApp(.done))
        XCTAssertFalse(ZoomStartOverRules.showsUseDifferentApp(.inProgress))
        XCTAssertFalse(ZoomStartOverRules.showsUseDifferentApp(.notStarted))
        XCTAssertEqual(ZoomStartOverRules.useDifferentAppTitle, "Use a different app")
        XCTAssertEqual(ZoomStartOverRules.removedNotice, "Keys removed")
    }

    // MARK: R12
}
