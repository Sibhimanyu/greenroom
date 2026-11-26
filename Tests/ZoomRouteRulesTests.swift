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

    // MARK: Precedence

    func testSignedInAloneUsesGreenroomsApp() {
        XCTAssertEqual(ZoomRouteRules.route(facts(signedIn: true)), .greenroomApp(account: "Sibhi -8A"))
    }

    func testOwnAppsAloneUseOwnApps() {
        XCTAssertEqual(ZoomRouteRules.route(facts(sdk: true, s2s: true)), .ownApps(sdkClientID: "AbCdEfGh1234wxyz"))
    }

    /// Owner, 2026-11-26 (A): own apps work for any account; the sign-in only starts meetings on the
    /// account that owns Greenroom's Zoom app (error 63 elsewhere), so own apps win by default.
    func testBothSetUpOwnAppsWinByDefault() {
        let f = facts(signedIn: true, sdk: true, s2s: true)
        XCTAssertEqual(ZoomRouteRules.route(f), .ownApps(sdkClientID: "AbCdEfGh1234wxyz"))
        XCTAssertTrue(ZoomRouteRules.bothSetUp(f))
    }

    func testBothSetUpTheSwitchPicksTheSignIn() {
        let f = facts(signedIn: true, sdk: true, s2s: true, prefersSignIn: true)
        XCTAssertEqual(ZoomRouteRules.route(f), .greenroomApp(account: "Sibhi -8A"))
        XCTAssertTrue(ZoomRouteRules.bothSetUp(f))
    }

    func testTheSwitchIsIgnoredWhileOwnAppsAreIncomplete() {
        // Only the Meeting SDK half pasted: Start could not create a meeting with it.
        let f = facts(signedIn: true, sdk: true, s2s: false)
        XCTAssertEqual(ZoomRouteRules.route(f), .greenroomApp(account: "Sibhi -8A"))
        XCTAssertFalse(ZoomRouteRules.bothSetUp(f))
    }

    func testHalfOwnAppsNotSignedInIsAGap() {
        XCTAssertEqual(ZoomRouteRules.route(facts(sdk: true)), .none(.ownAppsIncomplete))
        XCTAssertEqual(ZoomRouteRules.route(facts(s2s: true)), .none(.ownAppsIncomplete))
    }

    func testNothingSetUp() {
        XCTAssertEqual(ZoomRouteRules.route(facts()), .none(.notSetUp))
    }

    func testSignedInWithoutTheSigningServiceFallsBackToOwnAppsElseSaysSo() {
        XCTAssertEqual(ZoomRouteRules.route(facts(signedIn: true, endpointSet: false)), .none(.signInNotFinished))
        XCTAssertEqual(ZoomRouteRules.route(facts(signedIn: true, endpointSet: false, sdk: true, s2s: true)),
                       .ownApps(sdkClientID: "AbCdEfGh1234wxyz"))
    }

    func testAccountNameFallsBackToEmail() {
        XCTAssertEqual(ZoomRouteRules.route(facts(signedIn: true, name: " ", email: "a@b.c")),
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
        XCTAssertEqual(ZoomRouteRules.restSource(.none(.notSetUp)), .none)
        XCTAssertEqual(ZoomRouteRules.sdkAuth(.none(.notSetUp)), .missingKeys)
        XCTAssertEqual(ZoomRouteRules.sdkAuth(.none(.signInNotFinished)), .notFinished)
    }

    // MARK: Words

    func testTheLineSaysWhichZoom() {
        XCTAssertEqual(ZoomRouteWords.line(.greenroomApp(account: "Sibhi -8A")),
                       "Start uses: your Zoom account (Sibhi -8A), through Greenroom\u{2019}s Zoom app.")
        XCTAssertEqual(ZoomRouteWords.line(.ownApps(sdkClientID: "AbCdEfGh1234wxyz")),
                       "Start uses: your own Zoom apps (client ID \u{2026}wxyz).")
        XCTAssertEqual(ZoomRouteWords.line(.none(.notSetUp)),
                       "Start can\u{2019}t run yet: sign in with Zoom, or set up your own Zoom apps.")
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

    func testBothSetUpSaysWhichWinsAndOffersTheOtherOne() {
        XCTAssertEqual(ZoomRouteWords.bothNote(.greenroomApp(account: "A")),
                       "Your own Zoom apps are set up too. Start uses your Zoom account, as you chose.")
        XCTAssertEqual(ZoomRouteWords.switchTitle(.greenroomApp(account: "A")), "Use my own Zoom apps")
        XCTAssertEqual(ZoomRouteWords.bothNote(.ownApps(sdkClientID: "x")),
                       "You are signed in with Zoom too. Start uses your own Zoom apps: they can start meetings on any account.")
        XCTAssertEqual(ZoomRouteWords.switchTitle(.ownApps(sdkClientID: "x")), "Use my Zoom account")
        XCTAssertNil(ZoomRouteWords.switchTitle(.none(.notSetUp)))
    }

    func testTheFailureEndsWithTheRouteLine() {
        XCTAssertEqual(ZoomRouteWords.failure("Couldn\u{2019}t reach Zoom.", route: .ownApps(sdkClientID: "AbCdEfGh1234wxyz")),
                       "Couldn\u{2019}t reach Zoom.\n\nStart uses: your own Zoom apps (client ID \u{2026}wxyz).")
    }

    func testNoWordSaysClass() {
        let routes: [ZoomRoute] = [.greenroomApp(account: "A"), .ownApps(sdkClientID: "x"),
                                   .none(.notSetUp), .none(.ownAppsIncomplete), .none(.signInNotFinished)]
        for route in routes {
            let words = [ZoomRouteWords.line(route), ZoomRouteWords.bothNote(route) ?? "", ZoomRouteWords.switchTitle(route) ?? ""]
            for w in words { XCTAssertFalse(w.lowercased().contains("class"), w) }
        }
    }
}
