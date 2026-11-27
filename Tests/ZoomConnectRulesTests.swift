import XCTest
@testable import GreenroomTests

/// R14: the Connect Zoom step's one button, its status lines, the check row and the manual route.
final class ZoomConnectRulesTests: XCTestCase {
    private let mid = "AbC_123-xyZ789qrstuvw1", hid = "ZzZ_999-aaBBcc1122"

    private func facts(_ sdk: Int, _ s2s: Int, _ check: ZoomGuideCheckState = .notRun,
                       sdkFix: Bool = false, s2sFix: Bool = false) -> ZoomGuideFlowFacts {
        ZoomGuideFlowFacts(sdkFilled: sdk, s2sFilled: s2s, check: check, meetingAppNeedsFix: sdkFix, hostingAppNeedsFix: s2sFix)
    }

    func testTheOneButtonByState() {
        XCTAssertEqual(ZoomConnectRules.button(facts(0, 0)), ZoomConnectButton(title: "Set up Zoom", part: .meetingApp))
        XCTAssertEqual(ZoomConnectRules.button(facts(1, 0)), ZoomConnectButton(title: "Continue setup", part: .meetingApp))
        XCTAssertEqual(ZoomConnectRules.button(facts(2, 0)), ZoomConnectButton(title: "Continue setup", part: .hostingApp))
        XCTAssertEqual(ZoomConnectRules.button(facts(0, 3)), ZoomConnectButton(title: "Continue setup", part: .meetingApp))
        XCTAssertEqual(ZoomConnectRules.button(facts(2, 1)), ZoomConnectButton(title: "Continue setup", part: .hostingApp))
        XCTAssertNil(ZoomConnectRules.button(facts(2, 3)))
        XCTAssertNil(ZoomConnectRules.button(facts(2, 3, .passed)))
    }

    func testAPartNeedingAFixIsUnfinishedAgain() {
        XCTAssertEqual(ZoomConnectRules.button(facts(2, 3, .failed, sdkFix: true)), ZoomConnectButton(title: "Continue setup", part: .meetingApp))
        XCTAssertEqual(ZoomConnectRules.button(facts(2, 3, .failed, s2sFix: true)), ZoomConnectButton(title: "Continue setup", part: .hostingApp))
    }

    func testWhereTheButtonOpens() {
        let none = ZoomAppIDs()
        XCTAssertEqual(ZoomConnectRules.entryPage(.meetingApp, ids: none, filled: 0), .createdApps)
        XCTAssertEqual(ZoomConnectRules.entryPage(.hostingApp, ids: none, filled: 0), .createdApps)
        XCTAssertEqual(ZoomConnectRules.entryPage(.meetingApp, ids: ZoomAppIDs(meeting: mid), filled: 0), .general(mid, .embed))
        XCTAssertEqual(ZoomConnectRules.entryPage(.meetingApp, ids: ZoomAppIDs(meeting: mid), filled: 1), .general(mid, .information))
        XCTAssertEqual(ZoomConnectRules.entryPage(.hostingApp, ids: ZoomAppIDs(hosting: hid), filled: 0), .s2s(hid, .scopes))
        XCTAssertEqual(ZoomConnectRules.entryPage(.hostingApp, ids: ZoomAppIDs(hosting: hid), filled: 2), .s2s(hid, .credentials))
        // The other kind's ID is not this part's.
        XCTAssertEqual(ZoomConnectRules.entryPage(.hostingApp, ids: ZoomAppIDs(meeting: mid), filled: 0), .createdApps)
    }

    func testTheCheckRowShowsOnceBothAreDoneOrACheckHasRun() {
        XCTAssertFalse(ZoomConnectRules.showsCheckRow(facts(0, 0)))
        XCTAssertFalse(ZoomConnectRules.showsCheckRow(facts(2, 1)))
        XCTAssertTrue(ZoomConnectRules.showsCheckRow(facts(2, 3)))
        XCTAssertTrue(ZoomConnectRules.showsCheckRow(facts(2, 3, .passed)))
        XCTAssertTrue(ZoomConnectRules.showsCheckRow(facts(2, 3, .failed, s2sFix: true)))
        XCTAssertTrue(ZoomConnectRules.showsCheckRow(facts(2, 3, .running)))
    }

    func testDeepLinksIntoKeysScopesAndActivationOpenTheManualRoute() {
        for spot: ZoomGuideSpot in [.sdkCredentials, .s2sCredentials, .s2sScopes, .s2sActivation] {
            XCTAssertTrue(ZoomConnectRules.opensManual(spot), "\(spot)")
        }
        XCTAssertFalse(ZoomConnectRules.opensManual(.zoomStep))
    }

    func testShortcutsOnlyForAppsWhoseIDIsKnown() {
        XCTAssertTrue(ZoomConnectRules.shortcuts(.meetingApp, ids: ZoomAppIDs()).isEmpty)
        XCTAssertTrue(ZoomConnectRules.shortcuts(.hostingApp, ids: ZoomAppIDs(meeting: mid)).isEmpty)
        XCTAssertEqual(ZoomConnectRules.shortcuts(.meetingApp, ids: ZoomAppIDs(meeting: mid)).map(\.title), ["Open Embed", "Open Basic information"])
        XCTAssertEqual(ZoomConnectRules.shortcuts(.hostingApp, ids: ZoomAppIDs(hosting: hid)).map(\.title),
                       ["Open Scopes", "Open Activation", "Open App Credentials"])
    }

    func testTheIntro() {
        XCTAssertEqual(ZoomConnectRules.intro,
                       "Greenroom needs two small apps in your Zoom account. It takes about 10 minutes, and Greenroom shows you each click.")
        XCTAssertEqual(ZoomConnectRules.manualTitle, "Enter the keys yourself")
        XCTAssertFalse(ZoomConnectRules.intro.lowercased().contains("class"))
    }
}
