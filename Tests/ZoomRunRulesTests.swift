import XCTest
@testable import GreenroomTests

/// R18: a part is set up only when its keys are in AND the latest check passed for that app; failed lines
/// become the current step. Zoom's own order: App Credentials, Information, Feature, Scopes, Activation.
final class ZoomRunRulesTests: XCTestCase {
    private let ids = ZoomCheckActionContext(sdkClientID: "SampleSDKab12", s2sClientID: "SampleS2Scd34")
    private let hid = "ZzZ_999-aaBBcc1122", mid = "AbC_123-xyZ789qrstuvw1"

    private func line(_ id: String, _ status: ZoomCheckStatus, _ problem: ZoomCheckProblem = .nothing, _ detail: String = "x") -> ZoomCheckLine {
        ZoomCheckLine(id: id, title: id, status: status, detail: detail,
                      actions: ZoomCheckActionRules.buttons(.ownApps, check: id, status: status, problem: problem, ids: ids))
    }
    private var hostingPassed: [ZoomCheckLine] {
        ["account", "create", "list", "details", "update", "delete", "host", "end", "personalRoom", "meetings", "hostToken"].map { line($0, .passed) }
    }

    // MARK: Passed or not

    func testKeysAloneAreNotDone() {
        XCTAssertFalse(ZoomRunRules.passed(.s2s, lines: [], running: false, keysComplete: true))
        XCTAssertFalse(ZoomRunRules.passed(.sdk, lines: [], running: false, keysComplete: true))
        XCTAssertNil(ZoomRunRules.fix(.s2s, lines: [], keysComplete: true))
    }

    func testPassedNeedsAPassingCheckAndCompleteKeys() {
        XCTAssertTrue(ZoomRunRules.passed(.s2s, lines: hostingPassed, running: false, keysComplete: true))
        XCTAssertFalse(ZoomRunRules.passed(.s2s, lines: hostingPassed, running: true, keysComplete: true))
        XCTAssertFalse(ZoomRunRules.passed(.s2s, lines: hostingPassed, running: false, keysComplete: false))
        XCTAssertTrue(ZoomRunRules.passed(.sdk, lines: [line("sdk", .passed)], running: false, keysComplete: true))
        // The other app's failures do not unpass this one.
        XCTAssertTrue(ZoomRunRules.passed(.s2s, lines: hostingPassed + [line("sdk", .failed, .badCredentials, "Add both General App values")], running: false, keysComplete: true))
        XCTAssertFalse(ZoomRunRules.passed(.sdk, lines: hostingPassed + [line("sdk", .failed, .badCredentials)], running: false, keysComplete: true))
    }

    func testAFailedLineIsNeverPassedEvenWithoutAFix() {
        let offline = hostingPassed.dropLast() + [line("hostToken", .failed, .network)]
        XCTAssertFalse(ZoomRunRules.passed(.s2s, lines: Array(offline), running: false, keysComplete: true))
        XCTAssertNil(ZoomRunRules.fix(.s2s, lines: Array(offline), keysComplete: true))
    }

    // MARK: The first failure becomes the current step

    func testMissingScopesAreTheFixWithTheirCount() {
        var lines = hostingPassed.filter { $0.id != "update" && $0.id != "delete" }
        lines.append(line("update", .failed, .missingScopes(["meeting:update:meeting:admin"])))
        lines.append(line("delete", .failed, .missingScopes(["meeting:delete:meeting:admin"])))
        XCTAssertEqual(ZoomRunRules.fix(.s2s, lines: lines, keysComplete: true), .scopes(missing: 2))
        XCTAssertEqual(ZoomRunRules.title(.scopes(missing: 2)), "Add 2 missing permissions")
        XCTAssertEqual(ZoomRunRules.title(.scopes(missing: 1)), "Add 1 missing permission")
        XCTAssertEqual(ZoomRunRules.title(.scopes(missing: 0)), "Add the permissions")
    }

    func testARefusedTokenPointsAtActivationAndMissingKeysAtTheKeys() {
        let refused = [line("account", .failed, .badCredentials, "Zoom did not accept the keys. Check the three hosting values.")]
        XCTAssertEqual(ZoomRunRules.fix(.s2s, lines: refused, keysComplete: true), .activation)
        let notActive = [line("account", .failed, .notActivated, "The app is not activated.")]
        XCTAssertEqual(ZoomRunRules.fix(.s2s, lines: notActive, keysComplete: true), .activation)
        let missing = [line("account", .failed, .badCredentials, "Add all three Server-to-Server app values under Create and host meetings.")]
        XCTAssertEqual(ZoomRunRules.fix(.s2s, lines: missing, keysComplete: false), .keys)
    }

    func testTheMeetingAppsFixes() {
        XCTAssertEqual(ZoomRunRules.fix(.sdk, lines: [line("sdk", .failed, .badCredentials, "Zoom said no. Check the General App credentials and that Meeting SDK is enabled.")], keysComplete: true), .embed)
        XCTAssertEqual(ZoomRunRules.fix(.sdk, lines: [line("sdk", .failed, .badCredentials, "Add both General App values under Meeting and chat.")], keysComplete: false), .keys)
        XCTAssertNil(ZoomRunRules.fix(.sdk, lines: [line("sdk", .passed)], keysComplete: true))
    }

    func testScopesComeBeforeActivationWhenBothAreKnown() {
        var lines = hostingPassed.filter { $0.id != "update" }
        lines.append(line("update", .failed, .missingScopes(["meeting:update:meeting:admin"])))
        XCTAssertEqual(ZoomRunRules.fix(.s2s, lines: lines, keysComplete: true), .scopes(missing: 1))
    }

    // MARK: Where each fix lives, and the order of Zoom's tabs

    func testFixStepsAndPages() {
        XCTAssertEqual(ZoomRunRules.step(.keys, app: .sdk), 2)
        XCTAssertEqual(ZoomRunRules.step(.embed, app: .sdk), 3)
        XCTAssertEqual(ZoomRunRules.step(.keys, app: .s2s), 5)
        XCTAssertEqual(ZoomRunRules.step(.scopes(missing: 3), app: .s2s), 7)
        XCTAssertEqual(ZoomRunRules.step(.activation, app: .s2s), 8)
        XCTAssertEqual(ZoomRunRules.page(.scopes(missing: 3), app: .s2s, id: hid), .s2s(hid, .scopes))
        XCTAssertEqual(ZoomRunRules.page(.activation, app: .s2s, id: hid), .s2s(hid, .activation))
        XCTAssertEqual(ZoomRunRules.page(.keys, app: .s2s, id: hid), .s2s(hid, .credentials))
        XCTAssertEqual(ZoomRunRules.page(.keys, app: .sdk, id: mid), .general(mid, .information))
        XCTAssertEqual(ZoomRunRules.page(.embed, app: .sdk, id: mid), .general(mid, .embed))
    }

    func testZoomsWizardOrder() {
        XCTAssertEqual(ZoomRunRules.nextTab(after: .s2s(hid, .credentials)), .s2s(hid, .information))
        XCTAssertEqual(ZoomRunRules.nextTab(after: .s2s(hid, .information)), .s2s(hid, .feature))
        XCTAssertEqual(ZoomRunRules.nextTab(after: .s2s(hid, .feature)), .s2s(hid, .scopes))
        XCTAssertEqual(ZoomRunRules.nextTab(after: .s2s(hid, .scopes)), .s2s(hid, .activation))
        XCTAssertNil(ZoomRunRules.nextTab(after: .s2s(hid, .activation)))
        XCTAssertEqual(ZoomRunRules.nextTab(after: .general(mid, .information)), .general(mid, .embed))
        XCTAssertNil(ZoomRunRules.nextTab(after: .general(mid, .embed)))
        XCTAssertNil(ZoomRunRules.nextTab(after: .createdApps))
    }

    // MARK: The feedback loop

    func testTheCheckRunsWhenAPartsKeysBecomeCompleteNotWhileOneRunsOrALiveSession() {
        let go = ZoomRunRules.shouldCheckAfterKeys
        XCTAssertTrue(go(false, true, false, false))
        XCTAssertFalse(go(true, true, false, false))
        XCTAssertFalse(go(false, false, false, false))
        XCTAssertFalse(go(false, true, true, false))
        XCTAssertFalse(go(false, true, false, true))
    }

    func testTheCheckRunsAgainAfterAStepOnlyWhenThereIsSomethingToFix() {
        let again = ZoomRunRules.shouldRecheck
        XCTAssertTrue(again(true, false, false))
        XCTAssertFalse(again(false, false, false))   // nothing failed
        XCTAssertFalse(again(true, true, false))     // already running
        XCTAssertFalse(again(true, false, true))     // a live session
    }
}
