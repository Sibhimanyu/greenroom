import XCTest

/// The one rule for "which Zoom am I using": Settings' top line, Home's
/// readiness, the Start path and the session log all read `ZoomRouteRules`.
final class ZoomRouteRulesTests: XCTestCase {

    private func facts(signedIn: Bool = false, name: String = "Sibhi -8A", email: String = "s@example.com",
                       endpointSet: Bool = true, sdk: Bool = false, s2s: Bool = false,
                       clientID: String = "AbCdEfGh1234wxyz", prefersSignIn: Bool = false) -> ZoomRouteFacts {
        ZoomRouteFacts(signedIn: signedIn, accountName: name, accountEmail: email, endpointSet: endpointSet,
                       ownSDKComplete: sdk, ownS2SComplete: s2s, sdkClientID: clientID,
                       prefersSignIn: prefersSignIn)
    }

    // MARK: The choice is the route

    func testSignInChosenAndSignedInUsesGreenroomsApp() {
        XCTAssertEqual(ZoomRouteRules.route(facts(signedIn: true, prefersSignIn: true)), .greenroomApp(account: "Sibhi -8A"))
    }

    func testOwnAppsChosenAndSetUpUseOwnApps() {
        XCTAssertEqual(ZoomRouteRules.route(facts(sdk: true, s2s: true)), .ownApps(sdkClientID: "AbCdEfGh1234wxyz"))
    }

    /// Owner, 2026-11-26: what is selected is what Start uses. Both set up, the choice picks.
    func testBothSetUpTheChoicePicks() {
        let own = facts(signedIn: true, sdk: true, s2s: true)
        XCTAssertEqual(ZoomRouteRules.route(own), .ownApps(sdkClientID: "AbCdEfGh1234wxyz"))
        XCTAssertTrue(ZoomRouteRules.bothSetUp(own))
        let signIn = facts(signedIn: true, sdk: true, s2s: true, prefersSignIn: true)
        XCTAssertEqual(ZoomRouteRules.route(signIn), .greenroomApp(account: "Sibhi -8A"))
        XCTAssertTrue(ZoomRouteRules.bothSetUp(signIn))
    }

    /// The chosen way not ready: Start says what it is missing, never quietly uses the other one.
    func testTheChosenWayNotReadyIsAGapEvenWhenTheOtherWorks() {
        XCTAssertEqual(ZoomRouteRules.route(facts(signedIn: true)), .none(.ownAppsNotSetUp))
        XCTAssertEqual(ZoomRouteRules.route(facts(signedIn: true, sdk: true)), .none(.ownAppsIncomplete))
        XCTAssertEqual(ZoomRouteRules.route(facts(sdk: true, s2s: true, prefersSignIn: true)), .none(.notSignedIn))
    }

    func testHalfOwnAppsIsAGap() {
        XCTAssertEqual(ZoomRouteRules.route(facts(sdk: true)), .none(.ownAppsIncomplete))
        XCTAssertEqual(ZoomRouteRules.route(facts(s2s: true)), .none(.ownAppsIncomplete))
    }

    func testNothingSetUp() {
        XCTAssertEqual(ZoomRouteRules.route(facts()), .none(.ownAppsNotSetUp))
        XCTAssertEqual(ZoomRouteRules.route(facts(prefersSignIn: true)), .none(.notSignedIn))
    }

    func testSignedInWithoutTheSigningServiceSaysSo() {
        XCTAssertEqual(ZoomRouteRules.route(facts(signedIn: true, endpointSet: false, prefersSignIn: true)),
                       .none(.signInNotFinished))
        XCTAssertEqual(ZoomRouteRules.route(facts(signedIn: true, endpointSet: false, sdk: true, s2s: true)),
                       .ownApps(sdkClientID: "AbCdEfGh1234wxyz"))
    }

    func testAccountNameFallsBackToEmail() {
        XCTAssertEqual(ZoomRouteRules.route(facts(signedIn: true, name: " ", email: "a@b.c", prefersSignIn: true)),
                       .greenroomApp(account: "a@b.c"))
    }

    // MARK: Both halves of Start follow the route

    func testRESTAndSDKBothFollowTheRoute() {
        let greenroom = ZoomRoute.greenroomApp(account: "A")
        XCTAssertEqual(ZoomRouteRules.restSource(greenroom), .signedIn)
        XCTAssertEqual(ZoomRouteRules.sdkAuth(greenroom), .worker)
        let own = ZoomRoute.ownApps(sdkClientID: "x")
        XCTAssertEqual(ZoomRouteRules.restSource(own), .ownApps)
        XCTAssertEqual(ZoomRouteRules.sdkAuth(own), .ownKeys)
        XCTAssertEqual(ZoomRouteRules.restSource(.none(.ownAppsNotSetUp)), .none)
        XCTAssertEqual(ZoomRouteRules.sdkAuth(.none(.ownAppsNotSetUp)), .missingKeys)
        XCTAssertEqual(ZoomRouteRules.sdkAuth(.none(.signInNotFinished)), .notFinished)
    }

    // MARK: Words

    func testTheLineSaysWhichZoom() {
        XCTAssertEqual(ZoomRouteWords.line(.greenroomApp(account: "Sibhi -8A")),
                       "Start uses: your Zoom account (Sibhi -8A), through Greenroom\u{2019}s Zoom app.")
        XCTAssertEqual(ZoomRouteWords.line(.ownApps(sdkClientID: "AbCdEfGh1234wxyz")),
                       "Start uses: your own Zoom apps (client ID \u{2026}wxyz).")
        XCTAssertEqual(ZoomRouteWords.line(.none(.ownAppsNotSetUp)),
                       "Start can\u{2019}t run yet: your own Zoom apps aren\u{2019}t set up.")
        XCTAssertEqual(ZoomRouteWords.line(.none(.notSignedIn)),
                       "Start can\u{2019}t run yet: you are not signed in with Zoom.")
        XCTAssertEqual(ZoomRouteWords.line(.none(.ownAppsIncomplete)),
                       "Start can\u{2019}t run yet: your own Zoom apps need both the Meeting SDK and the Server-to-Server app.")
    }

    func testTheLogLineCarriesTheSameWords() {
        XCTAssertEqual(ZoomRouteWords.logLine(.greenroomApp(account: "Sibhi -8A")),
                       "Zoom route: your Zoom account (Sibhi -8A), through Greenroom\u{2019}s Zoom app.")
        XCTAssertEqual(ZoomRouteWords.logLine(.ownApps(sdkClientID: "AbCdEfGh1234wxyz")),
                       "Zoom route: your own Zoom apps (client ID \u{2026}wxyz).")
    }

    func testAShortClientIDIsShownWhole() {
        XCTAssertEqual(ZoomRouteWords.clientIDTail("abc"), "abc")
        XCTAssertEqual(ZoomRouteWords.clientIDTail("  AbCdEfGh1234wxyz "), "\u{2026}wxyz")
    }

    /// Home's Zoom pill and the menu bar name the chosen way's gap.
    func testThePillNamesTheChosenWaysGap() {
        XCTAssertEqual(ZoomRouteWords.homeProblem(.none(.ownAppsNotSetUp)), "Zoom: set up your apps")
        XCTAssertEqual(ZoomRouteWords.homeProblem(.none(.ownAppsIncomplete)), "Zoom: set up your apps")
        XCTAssertEqual(ZoomRouteWords.homeProblem(.none(.notSignedIn)), "Zoom: sign in")
        XCTAssertEqual(ZoomRouteWords.homeProblem(.none(.signInNotFinished)), "Zoom: sign-in not ready")
        XCTAssertNil(ZoomRouteWords.homeProblem(.ownApps(sdkClientID: "x")))
    }

    func testTheFailureEndsWithTheRouteLine() {
        XCTAssertEqual(ZoomRouteWords.failure("Couldn\u{2019}t reach Zoom.", route: .ownApps(sdkClientID: "AbCdEfGh1234wxyz")),
                       "Couldn\u{2019}t reach Zoom.\n\nStart uses: your own Zoom apps (client ID \u{2026}wxyz).")
    }

    func testNoWordSaysClass() {
        let routes: [ZoomRoute] = [.greenroomApp(account: "A"), .ownApps(sdkClientID: "x"),
                                   .none(.ownAppsNotSetUp), .none(.notSignedIn), .none(.ownAppsIncomplete), .none(.signInNotFinished)]
        for route in routes {
            let words = [ZoomRouteWords.line(route), ZoomRouteWords.phrase(route), ZoomRouteWords.homeProblem(route) ?? ""]
            for w in words { XCTAssertFalse(w.lowercased().contains("class"), w) }
        }
    }
}
