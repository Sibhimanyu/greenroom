import XCTest

/// Settings -> Zoom is one choice of two ("Your own Zoom apps" or "Sign in
/// with Zoom"), and the chosen one IS what Start uses (owner, 2026-11-26:
/// "visibility based on what option is selected"). One table: every route
/// state, and what the page shows for it.
final class ZoomRouteChoiceRulesTests: XCTestCase {

    private struct Row {
        let name: String
        let facts: ZoomRouteChoiceFacts
        let expected: ZoomRouteChoice
    }

    private static func facts(signedIn: Bool = false, endpointSet: Bool = true, signingIn: Bool = false,
                              sdk: Bool = false, s2s: Bool = false,
                              sdkStarted: Bool? = nil, s2sStarted: Bool? = nil,
                              prefersSignIn: Bool) -> ZoomRouteChoiceFacts {
        ZoomRouteChoiceFacts(
            route: ZoomRouteFacts(signedIn: signedIn, accountName: "Sample Host", accountEmail: "host@example.com",
                                  endpointSet: endpointSet, ownSDKComplete: sdk, ownS2SComplete: s2s,
                                  sdkClientID: "SampleClientID9z7Q", prefersSignIn: prefersSignIn),
            ownSDKStarted: sdkStarted ?? sdk, ownS2SStarted: s2sStarted ?? s2s, signingIn: signingIn)
    }

    private static let ownLine = "Start uses: your own Zoom apps (client ID \u{2026}9z7Q)."
    private static let signInLine = "Start uses: your Zoom account (Sample Host), through Greenroom\u{2019}s Zoom app."

    private static let rows: [Row] = [
        Row(name: "both set up, own apps chosen",
            facts: facts(signedIn: true, sdk: true, s2s: true, prefersSignIn: false),
            expected: ZoomRouteChoice(selected: .ownApps, status: "Ready", tone: .good, check: .setup, action: nil,
                                      startLine: ownLine, startBlocked: nil, otherHint: nil)),
        Row(name: "both set up, sign-in chosen",
            facts: facts(signedIn: true, sdk: true, s2s: true, prefersSignIn: true),
            expected: ZoomRouteChoice(selected: .signIn, status: "Signed in as Sample Host \u{00B7} host@example.com",
                                      tone: .good, check: .signIn, action: nil,
                                      startLine: signInLine, startBlocked: nil, otherHint: nil)),
        Row(name: "only sign-in set up, sign-in chosen",
            facts: facts(signedIn: true, prefersSignIn: true),
            expected: ZoomRouteChoice(selected: .signIn, status: "Signed in as Sample Host \u{00B7} host@example.com",
                                      tone: .good, check: .signIn, action: nil,
                                      startLine: signInLine, startBlocked: nil, otherHint: nil)),
        Row(name: "only sign-in set up, own apps chosen",
            facts: facts(signedIn: true, prefersSignIn: false),
            expected: ZoomRouteChoice(selected: .ownApps,
                                      status: "Not set up yet. Paste the keys from your two Zoom apps below.",
                                      tone: .waiting, check: nil, action: nil,
                                      startLine: "Start can\u{2019}t run yet: your own Zoom apps aren\u{2019}t set up.",
                                      startBlocked: "Start can\u{2019}t run yet: your own Zoom apps aren\u{2019}t set up.",
                                      otherHint: "You are signed in with Zoom. Choose Sign in with Zoom to start with that instead.")),
        Row(name: "only own apps set up, own apps chosen",
            facts: facts(sdk: true, s2s: true, prefersSignIn: false),
            expected: ZoomRouteChoice(selected: .ownApps, status: "Ready", tone: .good, check: .setup, action: nil,
                                      startLine: ownLine, startBlocked: nil, otherHint: nil)),
        Row(name: "only own apps set up, sign-in chosen",
            facts: facts(sdk: true, s2s: true, prefersSignIn: true),
            expected: ZoomRouteChoice(selected: .signIn, status: "Not signed in", tone: .waiting, check: nil,
                                      action: .signIn,
                                      startLine: "Start can\u{2019}t run yet: you are not signed in with Zoom.",
                                      startBlocked: "Start can\u{2019}t run yet: you are not signed in with Zoom.",
                                      otherHint: "Your own Zoom apps are ready. Choose Your own Zoom apps to start with those instead.")),
        Row(name: "neither set up, own apps chosen (a fresh install)",
            facts: facts(prefersSignIn: false),
            expected: ZoomRouteChoice(selected: .ownApps,
                                      status: "Not set up yet. Paste the keys from your two Zoom apps below.",
                                      tone: .waiting, check: nil, action: nil,
                                      startLine: "Start can\u{2019}t run yet: your own Zoom apps aren\u{2019}t set up.",
                                      startBlocked: "Start can\u{2019}t run yet: your own Zoom apps aren\u{2019}t set up.",
                                      otherHint: nil)),
        Row(name: "neither set up, sign-in chosen",
            facts: facts(prefersSignIn: true),
            expected: ZoomRouteChoice(selected: .signIn, status: "Not signed in", tone: .waiting, check: nil,
                                      action: .signIn,
                                      startLine: "Start can\u{2019}t run yet: you are not signed in with Zoom.",
                                      startBlocked: "Start can\u{2019}t run yet: you are not signed in with Zoom.",
                                      otherHint: nil)),
        Row(name: "signing in, in the browser",
            facts: facts(signingIn: true, prefersSignIn: true),
            expected: ZoomRouteChoice(selected: .signIn, status: "Waiting for Zoom in your browser\u{2026}", tone: .waiting,
                                      check: nil, action: .cancelSignIn,
                                      startLine: "Start can\u{2019}t run yet: you are not signed in with Zoom.",
                                      startBlocked: "Start can\u{2019}t run yet: you are not signed in with Zoom.",
                                      otherHint: nil)),
        Row(name: "sign-in incomplete (no signing service)",
            facts: facts(signedIn: true, endpointSet: false, prefersSignIn: true),
            expected: ZoomRouteChoice(selected: .signIn,
                                      status: "Signed in as Sample Host, but Sign in with Zoom isn\u{2019}t finished setting up",
                                      tone: .problem, check: .signIn, action: nil,
                                      startLine: "Start can\u{2019}t run yet: Sign in with Zoom isn\u{2019}t finished setting up. Use your own Zoom apps for now.",
                                      startBlocked: "Start can\u{2019}t run yet: Sign in with Zoom isn\u{2019}t finished setting up. Use your own Zoom apps for now.",
                                      otherHint: nil)),
        Row(name: "own apps half filled: Meeting SDK only",
            facts: facts(sdk: true, prefersSignIn: false),
            expected: ZoomRouteChoice(selected: .ownApps, status: "Needs the Server-to-Server keys", tone: .problem,
                                      check: .setup, action: nil,
                                      startLine: "Start can\u{2019}t run yet: your own Zoom apps need both the Meeting SDK and the Server-to-Server app.",
                                      startBlocked: "Start can\u{2019}t run yet: your own Zoom apps need both the Meeting SDK and the Server-to-Server app.",
                                      otherHint: nil)),
        Row(name: "own apps half filled: some of each",
            facts: facts(sdkStarted: true, s2sStarted: true, prefersSignIn: false),
            expected: ZoomRouteChoice(selected: .ownApps, status: "Needs the Meeting SDK and Server-to-Server keys",
                                      tone: .problem, check: .setup, action: nil,
                                      startLine: "Start can\u{2019}t run yet: your own Zoom apps aren\u{2019}t set up.",
                                      startBlocked: "Start can\u{2019}t run yet: your own Zoom apps aren\u{2019}t set up.",
                                      otherHint: nil)),
    ]

    func testEveryRouteState() {
        for row in Self.rows {
            XCTAssertEqual(ZoomRouteChoiceRules.choice(row.facts), row.expected, row.name)
        }
    }

    /// The choice IS the route: Start never quietly takes the other one.
    func testStartFollowsTheChoiceEvenWhenTheOtherIsReady() {
        XCTAssertEqual(ZoomRouteRules.route(Self.facts(signedIn: true, prefersSignIn: false).route),
                       .none(.ownAppsNotSetUp))
        XCTAssertEqual(ZoomRouteRules.route(Self.facts(sdk: true, s2s: true, prefersSignIn: true).route),
                       .none(.notSignedIn))
    }

    // MARK: The choice on first run and after an update

    /// Owner's decision A: your own Zoom apps, because they start meetings on any account.
    func testAFreshInstallChoosesOwnApps() {
        XCTAssertFalse(ZoomRouteChoiceRules.initialPrefersSignIn(saved: nil, signedIn: false, ownAppsComplete: false))
    }

    func testASavedChoiceCarriesOver() {
        XCTAssertTrue(ZoomRouteChoiceRules.initialPrefersSignIn(saved: true, signedIn: false, ownAppsComplete: true))
        XCTAssertFalse(ZoomRouteChoiceRules.initialPrefersSignIn(saved: false, signedIn: true, ownAppsComplete: false))
    }

    func testNoSavedChoicePicksWhicheverIsSetUpAndOwnAppsWhenBoth() {
        XCTAssertTrue(ZoomRouteChoiceRules.initialPrefersSignIn(saved: nil, signedIn: true, ownAppsComplete: false))
        XCTAssertFalse(ZoomRouteChoiceRules.initialPrefersSignIn(saved: nil, signedIn: false, ownAppsComplete: true))
        XCTAssertFalse(ZoomRouteChoiceRules.initialPrefersSignIn(saved: nil, signedIn: true, ownAppsComplete: true))
    }

    /// Signing in (from the setup guide too) is choosing it, unless your own Zoom apps already work.
    func testSigningInChoosesTheSignInUnlessOwnAppsAreReady() {
        XCTAssertTrue(ZoomRouteChoiceRules.prefersSignInAfterSigningIn(current: false, ownAppsComplete: false))
        XCTAssertFalse(ZoomRouteChoiceRules.prefersSignInAfterSigningIn(current: false, ownAppsComplete: true))
        XCTAssertTrue(ZoomRouteChoiceRules.prefersSignInAfterSigningIn(current: true, ownAppsComplete: true))
    }

    func testTheTwoOptionsSayWhoTheyAreFor() {
        XCTAssertEqual(ZoomRouteOption.ownApps.title, "Your own Zoom apps")
        XCTAssertEqual(ZoomRouteOption.ownApps.note, "Works for any Zoom account")
        XCTAssertEqual(ZoomRouteOption.signIn.title, "Sign in with Zoom")
        XCTAssertEqual(ZoomRouteOption.signIn.note,
                       "Only starts meetings on the account that owns Greenroom\u{2019}s Zoom app")
        XCTAssertEqual(ZoomRouteCheck.setup.title, "Check Zoom setup")
        XCTAssertEqual(ZoomRouteCheck.signIn.title, "Check sign-in")
    }

    func testNoWordSaysClassOrAdvanced() {
        for row in Self.rows {
            let c = ZoomRouteChoiceRules.choice(row.facts)
            for w in [c.status, c.startLine, c.startBlocked ?? "", c.otherHint ?? ""] {
                XCTAssertFalse(w.lowercased().contains("class"), w)
                XCTAssertFalse(w.lowercased().contains("advanced"), w)
            }
        }
    }
}
