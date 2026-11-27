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

    func testStepOneSaysFindMyAppWhenKeysAreFilledButNoIDIsKnown() {
        for part in [ZoomGuidePart.meetingApp, .hostingApp] {
            let find = ZoomMarketplaceGuide.rows(part: part, ids: ZoomAppIDs(), keysFilled: true)
            XCTAssertEqual(find.first?.link, ZoomGuideRowLink(title: "Find my app", page: .createdApps))
            XCTAssertTrue(find.dropFirst().allSatisfy { $0.link == nil })
            let create = ZoomMarketplaceGuide.rows(part: part, ids: ZoomAppIDs(), keysFilled: false)
            XCTAssertEqual(create.first?.link?.title, "Create the app")
        }
    }

    func testAKnownIDWinsOverKeysFilled() {
        let rows = ZoomMarketplaceGuide.rows(part: .hostingApp, ids: ZoomAppIDs(hosting: id), keysFilled: true)
        XCTAssertEqual(rows.map { $0.link?.title }, [nil, "Open Scopes", "Open Activation", "Open App Credentials"])
    }

    func testTheCoachAsksForTheAppOnCreatedApps() {
        let c = ZoomCoachRules.coach(part: .hostingApp, page: .createdApps, keysFilled: false, tipsOn: true, needsApp: true)
        XCTAssertEqual(c, ZoomCoach(label: nil, kind: .none, counter: "", text: "Click the app you made for Greenroom."))
        XCTAssertNotNil(ZoomCoachRules.coach(part: .meetingApp, page: .createdApps, keysFilled: false, tipsOn: true, needsApp: true))
        XCTAssertNil(ZoomCoachRules.coach(part: .hostingApp, page: .createdApps, keysFilled: false, tipsOn: true, needsApp: false))
        XCTAssertNil(ZoomCoachRules.coach(part: .hostingApp, page: .createdApps, keysFilled: false, tipsOn: false, needsApp: true))
        XCTAssertNil(ZoomCoachRules.coach(part: .check, page: .createdApps, keysFilled: false, tipsOn: true, needsApp: true))
        // Other pages ignore it.
        XCTAssertEqual(ZoomCoachRules.coach(part: .hostingApp, page: .chooseType(id), keysFilled: false, tipsOn: true, needsApp: true)?.label,
                       "Server to server OAuth app")
    }
}
