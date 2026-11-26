import XCTest

/// Error 63 (UnableToJoinExternalMeeting) in plain words, the fix button, and the
/// remembered refusal that warns on Home before the next Start.
final class ZoomRefusalRulesTests: XCTestCase {

    private let greenroom = ZoomRoute.greenroomApp(account: "Sibhi -8A")
    private let own = ZoomRoute.ownApps(sdkClientID: "AbCdEfGh1234wxyz")

    func testGreenroomRouteRefusalSaysWhyAndWhatToDo() {
        let failure = ZoomRefusalRules.startFailure("This Zoom account is not allowed to join that meeting.",
                                                    crossAccount: true, route: greenroom)
        XCTAssertEqual(failure.message,
                       "Zoom refused to start this meeting on your account. "
                       + "Greenroom\u{2019}s Zoom app can only start meetings on the Zoom account that made it, "
                       + "and Zoom has not opened it to other accounts yet. Your account (Sibhi -8A) is a different one. "
                       + "To host from Greenroom now, use your own Zoom apps: Settings \u{2192} Zoom \u{2192} Your own Zoom apps."
                       + "\n\nStart uses: your Zoom account (Sibhi -8A), through Greenroom\u{2019}s Zoom app.")
        XCTAssertEqual(failure.fix, .openOwnZoomApps)
    }

    func testOwnAppsRefusalPointsAtTheTwoApps() {
        let failure = ZoomRefusalRules.startFailure("x", crossAccount: true, route: own)
        XCTAssertEqual(failure.message,
                       "Zoom refused to start this meeting. Your Meeting SDK app and your Server-to-Server app "
                       + "need to be on the same Zoom account. Check both in Settings \u{2192} Zoom."
                       + "\n\nStart uses: your own Zoom apps (client ID \u{2026}wxyz).")
        XCTAssertEqual(failure.fix, .openOwnZoomApps)
    }

    func testAnyOtherFailureKeepsItsWordsAndTryAgain() {
        let failure = ZoomRefusalRules.startFailure("Couldn\u{2019}t reach Zoom.", crossAccount: false, route: greenroom)
        XCTAssertEqual(failure.message, "Couldn\u{2019}t reach Zoom.\n\nStart uses: your Zoom account (Sibhi -8A), through Greenroom\u{2019}s Zoom app.")
        XCTAssertNil(failure.fix)
    }

    func testTheFixButtonSaysWhereItGoes() {
        XCTAssertEqual(StartFailureFix.openOwnZoomApps.title, "Open Settings")
    }

    // MARK: Remembered refusals

    func testARefusalOnGreenroomsAppIsRememberedPerAccount() {
        var refused: Set<String> = []
        refused = ZoomRefusalRules.afterStart(refused, accountID: "acctB", route: greenroom, crossAccountRefusal: true)
        XCTAssertEqual(refused, ["acctB"])
        // A refusal on your own apps says nothing about the sign-in.
        XCTAssertEqual(ZoomRefusalRules.afterStart([], accountID: "acctB", route: own, crossAccountRefusal: true), [])
        // No account ID known: nothing to key it by.
        XCTAssertEqual(ZoomRefusalRules.afterStart([], accountID: "", route: greenroom, crossAccountRefusal: true), [])
    }

    func testASuccessfulStartClearsIt() {
        XCTAssertEqual(ZoomRefusalRules.afterStart(["acctB", "acctC"], accountID: "acctB", route: greenroom,
                                                   crossAccountRefusal: false), ["acctC"])
    }

    func testHomeWarnsOnlyWhenStartWouldTakeTheRefusedRoute() {
        XCTAssertEqual(ZoomRefusalRules.homeWarning(route: greenroom, accountID: "acctB", refused: ["acctB"]),
                       "Zoom: this account can\u{2019}t host yet")
        XCTAssertNil(ZoomRefusalRules.homeWarning(route: greenroom, accountID: "acctA", refused: ["acctB"]))
        XCTAssertNil(ZoomRefusalRules.homeWarning(route: own, accountID: "acctB", refused: ["acctB"]))
    }

    func testSettingsExplainsTheRememberedRefusal() {
        XCTAssertEqual(ZoomRefusalRules.settingsNote(route: greenroom, accountID: "acctB", refused: ["acctB"]),
                       "Zoom refused the last Start with this account. Greenroom\u{2019}s Zoom app can\u{2019}t start meetings on it yet, so choose Your own Zoom apps above.")
        XCTAssertNil(ZoomRefusalRules.settingsNote(route: own, accountID: "acctB", refused: ["acctB"]))
    }

    func testStoredFormRoundTrips() {
        XCTAssertEqual(ZoomRefusalRules.decode(ZoomRefusalRules.encode(["b", "a"])), ["a", "b"])
        XCTAssertEqual(ZoomRefusalRules.decode(nil), [])
        XCTAssertEqual(ZoomRefusalRules.encode(["b", "a"]), "a,b")
    }
}
