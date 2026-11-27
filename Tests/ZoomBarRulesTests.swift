import XCTest
@testable import GreenroomTests

/// R13: what the Greenroom bar at the top of the Zoom window says and offers.
final class ZoomBarRulesTests: XCTestCase {
    private let mid = "AbC_123-xyZ789qrstuvw1", hid = "ZzZ_999-aaBBcc1122"

    private func bar(_ part: ZoomGuidePart, _ page: ZoomMarketplacePage?, meeting: Bool = false, hosting: Bool = false,
                     ids: ZoomAppIDs = ZoomAppIDs(), signIn: ZoomSignInState = .signedIn, hasRow: Bool = false, working: Bool = false) -> ZoomBar {
        ZoomBarRules.bar(ZoomBarFacts(part: part, page: page, ids: ids, meetingComplete: meeting, hostingComplete: hosting, signIn: signIn,
                                      hasMatchingRow: hasRow, working: working))
    }

    func testTheTitleCountsOneRunOfSevenSteps() {
        let d = " \u{00B7} "
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .scopes)).title, "Step 5 of 7" + d + "Add the permissions")
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .activation)).title, "Step 6 of 7" + d + "Turn it on")
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .credentials)).title, "Step 7 of 7" + d + "Copy its keys" + d + "Hosting app")
        XCTAssertEqual(bar(.meetingApp, .general(mid, .embed)).title, "Step 2 of 7" + d + "Turn on Meeting SDK")
        XCTAssertEqual(bar(.meetingApp, .general(mid, .information)).title, "Step 3 of 7" + d + "Copy its keys" + d + "Meeting app")
        XCTAssertEqual(bar(.hostingApp, .chooseType(hid)).title, "Step 4 of 7" + d + "Create the hosting app")
        XCTAssertEqual(bar(.meetingApp, .chooseType(mid)).title, "Step 1 of 7" + d + "Create the meeting app")
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .information)).title, "Step 4 of 7" + d + "Create the hosting app")
    }

    func testBeforeAnAppPageIsKnown() {
        XCTAssertEqual(bar(.hostingApp, .createdApps).title, "Step 4 of 7 \u{00B7} Create the hosting app")
        XCTAssertEqual(bar(.meetingApp, nil).title, "Step 1 of 7 \u{00B7} Find or create the meeting app")
    }

    func testSignInAndPagesWithoutAStep() {
        XCTAssertEqual(bar(.hostingApp, .signIn).title, "Sign in to Zoom")
                XCTAssertEqual(bar(.meetingApp, .general(mid, .other)).title, "Meeting app \u{00B7} Set up the app")
    }

    func testThePageDecidesThePartNotTheRequest() {
        XCTAssertEqual(bar(.meetingApp, .s2s(hid, .scopes)).title, "Step 5 of 7 \u{00B7} Add the permissions")
    }

    func testCopyScopesOnTheHostingScopesStepOnly() {
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .scopes)).context, .copyScopes)
        for page: ZoomMarketplacePage in [.s2s(hid, .activation), .s2s(hid, .credentials), .createdApps, .signIn, .general(mid, .scopes)] {
            XCTAssertEqual(bar(.hostingApp, page).context, ZoomBarContext.none, "\(page)")
        }
    }

    func testASetUpPartOnItsCredentialsPageSaysSoWithACheck() {
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .credentials), hosting: true).context, .setUp("Hosting app is set up"))
        XCTAssertEqual(bar(.meetingApp, .general(mid, .information), meeting: true).context, .setUp("Meeting app is set up"))
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .credentials)).context, ZoomBarContext.none)
        // The other part being set up is not this part.
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .credentials), meeting: true).context, ZoomBarContext.none)
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .scopes), hosting: true).context, .copyScopes)
    }

    func testNextPartAfterOneIsComplete() {
        let a = bar(.hostingApp, .s2s(hid, .credentials), hosting: true)
        XCTAssertEqual(a.primary, .next(.meetingApp, .createdApps))
        XCTAssertEqual(a.primary.title, "Continue")
        let b = bar(.hostingApp, .s2s(hid, .credentials), hosting: true, ids: ZoomAppIDs(meeting: mid))
        XCTAssertEqual(b.primary, .next(.meetingApp, .general(mid, .information)))
        let c = bar(.meetingApp, .general(mid, .information), meeting: true)
        XCTAssertEqual(c.primary, .next(.hostingApp, .createdApps))
        XCTAssertEqual(c.primary.title, "Continue")
        // Step 4 always starts at Created apps, coached for the hosting app, even when its ID is known.
        let d = bar(.meetingApp, .general(mid, .information), meeting: true, ids: ZoomAppIDs(hosting: hid))
        XCTAssertEqual(d.primary, .next(.hostingApp, .createdApps))
    }

    func testNoNextUntilThePartIsCompleteAndOnItsCredentialsPage() {
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .credentials)).primary, ZoomBarPrimary.none)
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .scopes), hosting: true).primary, ZoomBarPrimary.none)
        XCTAssertEqual(bar(.hostingApp, .createdApps).primary, ZoomBarPrimary.none)
    }

    func testBothCompleteOffersBackToGreenroom() {
        let done = bar(.hostingApp, .s2s(hid, .credentials), meeting: true, hosting: true)
        XCTAssertEqual(done.primary, .backToGreenroom)
        XCTAssertEqual(done.primary.title, "Back to Greenroom")
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .scopes), meeting: true, hosting: true).primary, .backToGreenroom)
        XCTAssertEqual(bar(.meetingApp, .createdApps, meeting: true, hosting: true).primary, .backToGreenroom)
        XCTAssertEqual(bar(.meetingApp, .signIn, meeting: true, hosting: true).primary, ZoomBarPrimary.none)
    }

    func testTheCheckStartsOnReturnOnlyIfItHasNotRun() {
        let go = ZoomBarRules.shouldCheckOnReturn
        XCTAssertTrue(go(false, false, false))
        XCTAssertFalse(go(true, false, false))   // already running (the auto check started it)
        XCTAssertFalse(go(false, true, false))   // already has results
        XCTAssertFalse(go(false, false, true))   // a session is live
    }

    func testWordsNeverSayClass() {
        for part in [ZoomGuidePart.meetingApp, .hostingApp] {
            for page: ZoomMarketplacePage in [.createdApps, .chooseType(hid), .s2s(hid, .scopes), .general(mid, .embed), .signIn] {
                XCTAssertFalse(bar(part, page).title.lowercased().contains("class"))
            }
        }
    }

    func testSignedOutSaysSignInAndOffersASignInButton() {
        let b = bar(.hostingApp, .createdApps, signIn: .signedOut)
        XCTAssertEqual(b.title, "Sign in to Zoom")
        XCTAssertEqual(b.context, .signIn)
        XCTAssertEqual(ZoomBarContext.signIn.title, "Sign in")
        XCTAssertFalse(b.offersSignOut)
        // On the sign-in page itself there is nothing to press.
        let on = bar(.hostingApp, .signIn, signIn: .signedOut)
        XCTAssertEqual(on.title, "Sign in to Zoom")
        XCTAssertEqual(on.context, ZoomBarContext.none)
        // Signed out beats the step.
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .scopes), signIn: .signedOut).context, .signIn)
    }

    func testSignOutIsOnlyOfferedWhenKnownToBeSignedIn() {
        XCTAssertTrue(bar(.hostingApp, .createdApps, signIn: .signedIn).offersSignOut)
        XCTAssertFalse(bar(.hostingApp, .createdApps, signIn: .unknown).offersSignOut)
        XCTAssertFalse(bar(.hostingApp, .createdApps, signIn: .signedOut).offersSignOut)
        // An unknown state does not change the words.
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .scopes), signIn: .unknown).context, .copyScopes)
    }

    func testCreatedAppsSaysFindYourAppWhenARowMatches() {
        XCTAssertEqual(bar(.meetingApp, .createdApps, hasRow: true).title, "Step 1 of 7 \u{00B7} Find the meeting app")
        XCTAssertEqual(bar(.hostingApp, .createdApps, hasRow: true).title, "Step 4 of 7 \u{00B7} Find the hosting app")
        XCTAssertEqual(bar(.meetingApp, .createdApps, hasRow: false).title, "Step 1 of 7 \u{00B7} Create the meeting app")
        // A page that is not Created apps ignores it.
        XCTAssertEqual(bar(.hostingApp, nil, hasRow: true).title, "Step 4 of 7 \u{00B7} Find or create the hosting app")
        XCTAssertEqual(bar(.hostingApp, .signIn, hasRow: true).title, "Sign in to Zoom")
    }

    func testThePasskeyPageSaysSignInAndOffersSafariRightThere() {
        for state in [ZoomSignInState.unknown, .signedIn, .signedOut] {
            let b = bar(.hostingApp, .passkey, signIn: state)
            XCTAssertEqual(b.title, "Sign in to Zoom")
            XCTAssertEqual(b.context, .openInSafari)
            XCTAssertEqual(ZoomBarContext.openInSafari.title, "Open in Safari")
            XCTAssertEqual(b.primary, ZoomBarPrimary.none)
            XCTAssertFalse(b.offersSignOut)
        }
        XCTAssertEqual(bar(.meetingApp, .passkey, meeting: true, hosting: true).primary, ZoomBarPrimary.none)
    }

    func testWhileAStepRunsTheBarSaysWorking() {
        let b = bar(.hostingApp, .s2s(hid, .scopes), working: true)
        XCTAssertEqual(b.context, .working)
        XCTAssertEqual(ZoomBarContext.working.title, "Working\u{2026}")
        XCTAssertEqual(b.title, "Step 5 of 7 \u{00B7} Add the permissions")
        XCTAssertEqual(bar(.hostingApp, .createdApps, working: true).context, .working)
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .scopes), working: false).context, .copyScopes)
    }
}
