import XCTest

/// Sign in with Zoom shows as Coming soon until Zoom approves Greenroom's
/// Zoom app (owner, 2026-11-26): it can't start meetings on any account but
/// the app owner's (error 63). One switch, `ZoomSignInAvailability`; the route
/// is always your own Zoom apps, the choice control can't pick the sign-in,
/// and someone who used it is told to set up their own apps, with their
/// sign-in kept for when it opens.
final class ZoomSignInComingSoonTests: XCTestCase {

    private func facts(signedIn: Bool = false, endpointSet: Bool = true, sdk: Bool = false, s2s: Bool = false,
                       prefersSignIn: Bool = false, comingSoon: Bool = true) -> ZoomRouteFacts {
        ZoomRouteFacts(signedIn: signedIn, accountName: "Sample Host", accountEmail: "host@example.com",
                       endpointSet: endpointSet, ownSDKComplete: sdk, ownS2SComplete: s2s,
                       sdkClientID: "SampleClientID9z7Q", prefersSignIn: prefersSignIn, signInComingSoon: comingSoon)
    }

    private func choice(signedIn: Bool = false, sdk: Bool = false, s2s: Bool = false,
                        prefersSignIn: Bool = false, comingSoon: Bool = true) -> ZoomRouteChoice {
        ZoomRouteChoiceRules.choice(ZoomRouteChoiceFacts(
            route: facts(signedIn: signedIn, sdk: sdk, s2s: s2s, prefersSignIn: prefersSignIn, comingSoon: comingSoon),
            ownSDKStarted: sdk, ownS2SStarted: s2s, signingIn: false))
    }

    private static let own = ZoomRoute.ownApps(sdkClientID: "SampleClientID9z7Q")
    private static let setUpYourOwn = "Set up your own Zoom apps to start meetings"

    // MARK: The switch

    /// Until Zoom approves the app, the shipped switch is on.
    func testTheShippedSwitchIsOn() {
        XCTAssertTrue(ZoomSignInAvailability.comingSoon)
    }

    /// The debug override turns the sign-in back on in a DEBUG build only.
    func testTheDebugOverrideWorksOnlyInADebugBuild() {
        XCTAssertTrue(ZoomSignInAvailability.resolve(shipped: true, debugBuild: false, debugSignInOn: true),
                      "a Release build ignores the override")
        XCTAssertTrue(ZoomSignInAvailability.resolve(shipped: true, debugBuild: false, debugSignInOn: false))
        XCTAssertFalse(ZoomSignInAvailability.resolve(shipped: true, debugBuild: true, debugSignInOn: true),
                       "a DEBUG build with the override has the sign-in on")
        XCTAssertTrue(ZoomSignInAvailability.resolve(shipped: true, debugBuild: true, debugSignInOn: false))
        XCTAssertFalse(ZoomSignInAvailability.resolve(shipped: false, debugBuild: false, debugSignInOn: false),
                       "once Zoom approves, the switch is off everywhere")
        XCTAssertFalse(ZoomSignInAvailability.resolve(shipped: false, debugBuild: true, debugSignInOn: false))
    }

    func testTheTestTargetIsADebugBuild() {
        XCTAssertTrue(ZoomSignInAvailability.isDebugBuild)
    }

    // MARK: The route: always your own Zoom apps

    /// Every state: signed in or not, signing service or not, sign-in chosen or
    /// not, each half of your own apps. The sign-in is never the route.
    func testTheRouteIsNeverTheSignInInAnyState() {
        for signedIn in [false, true] {
            for endpointSet in [false, true] {
                for prefersSignIn in [false, true] {
                    for sdk in [false, true] {
                        for s2s in [false, true] {
                            let f = facts(signedIn: signedIn, endpointSet: endpointSet, sdk: sdk, s2s: s2s,
                                          prefersSignIn: prefersSignIn)
                            let route = ZoomRouteRules.route(f)
                            let name = "signedIn \(signedIn) endpoint \(endpointSet) prefersSignIn \(prefersSignIn) sdk \(sdk) s2s \(s2s)"
                            let expected: ZoomRoute
                            if sdk && s2s { expected = Self.own }
                            else if sdk || s2s { expected = .none(.ownAppsIncomplete) }
                            else if signedIn || prefersSignIn { expected = .none(.signInComingSoon) }
                            else { expected = .none(.ownAppsNotSetUp) }
                            XCTAssertEqual(route, expected, name)
                            XCTAssertFalse(route.usesGreenroomApp, name)
                            XCTAssertNotEqual(ZoomRouteRules.restSource(route), .signedIn, name)
                            XCTAssertNotEqual(ZoomRouteRules.sdkAuth(route), .worker, name)
                            XCTAssertFalse(f.choosesSignIn, name)
                        }
                    }
                }
            }
        }
    }

    /// A saved sign-in choice and a stored token stay as they are; they just don't drive Start.
    func testASavedChoiceStaysSavedButDoesNotChoose() {
        let f = facts(signedIn: true, prefersSignIn: true)
        XCTAssertTrue(f.prefersSignIn)
        XCTAssertTrue(f.signedIn)
        XCTAssertFalse(f.choosesSignIn)
        XCTAssertTrue(facts(signedIn: true, prefersSignIn: true, comingSoon: false).choosesSignIn)
    }

    /// With the switch off the sign-in works again, exactly as before.
    func testTheSwitchOffRestoresTheSignIn() {
        XCTAssertEqual(ZoomRouteRules.route(facts(signedIn: true, prefersSignIn: true, comingSoon: false)),
                       .greenroomApp(account: "Sample Host"))
    }

    // MARK: Words for someone who used the sign-in

    func testTheGapSaysSetUpYourOwnApps() {
        let gap = ZoomRoute.none(.signInComingSoon)
        XCTAssertEqual(ZoomRouteWords.homeProblem(gap), Self.setUpYourOwn)
        XCTAssertEqual(ZoomRouteWords.line(gap),
                       "Start can\u{2019}t run yet: Sign in with Zoom is coming soon. Set up your own Zoom apps to start meetings.")
        XCTAssertEqual(ZoomRouteWords.phrase(gap),
                       "nothing yet: Sign in with Zoom is coming soon and your own Zoom apps aren\u{2019}t set up")
        XCTAssertFalse(ZoomRouteWords.line(gap).lowercased().contains("class"))
    }

    /// Home's pill and the menu bar open the setup guide for it; own apps not (fully) set up
    /// open the Zoom window straight away (owner, 2026-11-27: skip Settings); the rest opens Settings.
    func testTheGapOpensTheSetupGuide() {
        XCTAssertEqual(ZoomRouteWords.homeFix(.none(.signInComingSoon)), .setupGuide)
        XCTAssertEqual(ZoomRouteWords.homeFix(.none(.ownAppsNotSetUp)), .zoomWindow)
        XCTAssertEqual(ZoomRouteWords.homeFix(.none(.ownAppsIncomplete)), .zoomWindow)
        for other: ZoomRoute in [.none(.notSignedIn), .none(.signInNotFinished), Self.own, .greenroomApp(account: "A")] {
            XCTAssertEqual(ZoomRouteWords.homeFix(other), .settings, "\(other)")
        }
    }

    // MARK: The choice control

    func testTheSignInSegmentIsComingSoonAndCannotBePicked() {
        let c = choice()
        XCTAssertTrue(c.signInComingSoon)
        XCTAssertFalse(c.isSelectable(.signIn))
        XCTAssertTrue(c.isSelectable(.ownApps))
        XCTAssertEqual(c.badge(.signIn), "Coming soon")
        XCTAssertNil(c.badge(.ownApps))
        XCTAssertEqual(c.tip(.signIn),
                       "Coming once Zoom approves Greenroom\u{2019}s Zoom app. Until then, set up your own Zoom apps; it takes about 10 minutes.")
        XCTAssertEqual(c.tip(.ownApps), ZoomRouteOption.ownApps.note)
    }

    func testWithTheSwitchOffBothSegmentsArePickable() {
        let c = choice(comingSoon: false)
        XCTAssertFalse(c.signInComingSoon)
        XCTAssertTrue(c.isSelectable(.signIn))
        XCTAssertNil(c.badge(.signIn))
        XCTAssertEqual(c.tip(.signIn), ZoomRouteOption.signIn.note)
    }

    /// A saved sign-in choice still shows your own Zoom apps, and never a sign-in section.
    func testOwnAppsAreShownWhateverWasChosen() {
        for prefersSignIn in [false, true] {
            for signedIn in [false, true] {
                let c = choice(signedIn: signedIn, prefersSignIn: prefersSignIn)
                XCTAssertEqual(c.selected, .ownApps, "prefersSignIn \(prefersSignIn) signedIn \(signedIn)")
                XCTAssertNil(c.action)
                XCTAssertNotEqual(c.check, .signIn)
            }
        }
    }

    // MARK: The status for a signed-in person with no own apps

    func testASignedInPersonWithNoOwnAppsIsToldToSetThemUp() {
        let c = choice(signedIn: true, prefersSignIn: true)
        XCTAssertEqual(c.status, Self.setUpYourOwn)
        XCTAssertEqual(c.tone, .problem)
        XCTAssertEqual(c.startBlocked,
                       "Start can\u{2019}t run yet: Sign in with Zoom is coming soon. Set up your own Zoom apps to start meetings.")
        XCTAssertEqual(c.otherHint,
                       "You are still signed in with Zoom. Greenroom keeps it for when Sign in with Zoom opens.")
    }

    /// Signed in with your own apps ready: ready, and no hint to choose the sign-in.
    func testASignedInPersonWithOwnAppsIsReady() {
        let c = choice(signedIn: true, sdk: true, s2s: true, prefersSignIn: true)
        XCTAssertEqual(c.status, "Ready")
        XCTAssertEqual(c.tone, .good)
        XCTAssertNil(c.startBlocked)
        XCTAssertNil(c.otherHint)
    }

    /// The open sign-in's hint ("Choose Sign in with Zoom...") never shows while it is coming soon.
    func testNoHintPointsAtTheSignIn() {
        for signedIn in [false, true] {
            for sdk in [false, true] {
                let hint = choice(signedIn: signedIn, sdk: sdk).otherHint ?? ""
                XCTAssertFalse(hint.contains("Choose Sign in with Zoom"), hint)
            }
        }
    }
}
