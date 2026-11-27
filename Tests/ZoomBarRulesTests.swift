import XCTest
@testable import GreenroomTests

/// R13: what the Greenroom bar at the top of the Zoom window says and offers.
final class ZoomBarRulesTests: XCTestCase {
    private let mid = "AbC_123-xyZ789qrstuvw1", hid = "ZzZ_999-aaBBcc1122"

    private func bar(_ part: ZoomGuidePart, _ page: ZoomMarketplacePage?, meeting: Bool = false, hosting: Bool = false,
                     ids: ZoomAppIDs = ZoomAppIDs(), signIn: ZoomSignInState = .signedIn, hasRow: Bool = false) -> ZoomBar {
        ZoomBarRules.bar(ZoomBarFacts(part: part, page: page, ids: ids, meetingComplete: meeting, hostingComplete: hosting, signIn: signIn,
                                      hasMatchingRow: hasRow))
    }

    func testTheTitleNamesThePartStepAndWhatToDo() {
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .scopes)).title, "Hosting app \u{00B7} Step 2 of 4 \u{00B7} Add the scopes")
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .activation)).title, "Hosting app \u{00B7} Step 3 of 4 \u{00B7} Activate the app")
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .credentials)).title, "Hosting app \u{00B7} Step 4 of 4 \u{00B7} Copy the keys")
        XCTAssertEqual(bar(.meetingApp, .general(mid, .embed)).title, "Meeting app \u{00B7} Step 2 of 3 \u{00B7} Turn on Meeting SDK")
        XCTAssertEqual(bar(.meetingApp, .general(mid, .information)).title, "Meeting app \u{00B7} Step 3 of 3 \u{00B7} Copy the keys")
        XCTAssertEqual(bar(.hostingApp, .chooseType(hid)).title, "Hosting app \u{00B7} Step 1 of 4 \u{00B7} Choose Server to server OAuth app")
        XCTAssertEqual(bar(.meetingApp, .chooseType(mid)).title, "Meeting app \u{00B7} Step 1 of 3 \u{00B7} Choose General app")
    }

    func testBeforeAnAppPageIsKnown() {
        XCTAssertEqual(bar(.hostingApp, .createdApps).title, "Hosting app \u{00B7} Create the app")
        XCTAssertEqual(bar(.meetingApp, nil).title, "Meeting app \u{00B7} Find or create the app")
    }

    func testSignInAndPagesWithoutAStep() {
        XCTAssertEqual(bar(.hostingApp, .signIn).title, "Sign in to Zoom")
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .information)).title, "Hosting app \u{00B7} Set up the app")
        XCTAssertEqual(bar(.meetingApp, .general(mid, .other)).title, "Meeting app \u{00B7} Set up the app")
    }

    func testThePageDecidesThePartNotTheRequest() {
        XCTAssertEqual(bar(.meetingApp, .s2s(hid, .scopes)).title, "Hosting app \u{00B7} Step 2 of 4 \u{00B7} Add the scopes")
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
        XCTAssertEqual(a.primary.title, "Next: Meeting app")
        let b = bar(.hostingApp, .s2s(hid, .credentials), hosting: true, ids: ZoomAppIDs(meeting: mid))
        XCTAssertEqual(b.primary, .next(.meetingApp, .general(mid, .information)))
        let c = bar(.meetingApp, .general(mid, .information), meeting: true)
        XCTAssertEqual(c.primary, .next(.hostingApp, .createdApps))
        XCTAssertEqual(c.primary.title, "Next: Hosting app")
        let d = bar(.meetingApp, .general(mid, .information), meeting: true, ids: ZoomAppIDs(hosting: hid))
        XCTAssertEqual(d.primary, .next(.hostingApp, .s2s(hid, .scopes)))
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
        XCTAssertEqual(bar(.meetingApp, .createdApps, hasRow: true).title, "Meeting app \u{00B7} Find your app")
        XCTAssertEqual(bar(.hostingApp, .createdApps, hasRow: true).title, "Hosting app \u{00B7} Find your app")
        XCTAssertEqual(bar(.meetingApp, .createdApps, hasRow: false).title, "Meeting app \u{00B7} Create the app")
        // A page that is not Created apps ignores it.
        XCTAssertEqual(bar(.hostingApp, nil, hasRow: true).title, "Hosting app \u{00B7} Find or create the app")
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
}
