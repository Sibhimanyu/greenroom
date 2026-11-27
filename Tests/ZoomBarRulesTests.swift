import XCTest
@testable import GreenroomTests

/// R13: what the Greenroom bar at the top of the Zoom window says and offers.
final class ZoomBarRulesTests: XCTestCase {
    private let mid = "AbC_123-xyZ789qrstuvw1", hid = "ZzZ_999-aaBBcc1122"

    private let ctx = ZoomCheckActionContext(sdkClientID: "SampleSDKab12", s2sClientID: "SampleS2Scd34")
    private func line(_ id: String, _ status: ZoomCheckStatus, _ problem: ZoomCheckProblem = .nothing, _ detail: String = "x") -> ZoomCheckLine {
        ZoomCheckLine(id: id, title: id, status: status, detail: detail,
                      actions: ZoomCheckActionRules.buttons(.ownApps, check: id, status: status, problem: problem, ids: ctx))
    }
    private var hostingPass: [ZoomCheckLine] {
        ["account", "create", "list", "details", "update", "delete", "host", "end", "personalRoom", "meetings", "hostToken"].map { line($0, .passed) }
    }
    private var bothPass: [ZoomCheckLine] { [line("sdk", .passed)] + hostingPass }
    private var scopesFailing: [ZoomCheckLine] {
        [line("sdk", .passed)] + hostingPass.filter { $0.id != "update" && $0.id != "delete" } + [
            line("update", .failed, .missingScopes(["meeting:update:meeting:admin"])),
            line("delete", .failed, .missingScopes(["meeting:delete:meeting:admin"]))]
    }

    private func bar(_ part: ZoomGuidePart, _ page: ZoomMarketplacePage?, meeting: Bool = false, hosting: Bool = false,
                     ids: ZoomAppIDs = ZoomAppIDs(), signIn: ZoomSignInState = .signedIn, hasRow: Bool = false, working: Bool = false,
                     lines: [ZoomCheckLine] = [], running: Bool = false) -> ZoomBar {
        ZoomBarRules.bar(ZoomBarFacts(part: part, page: page, ids: ids, meetingComplete: meeting, hostingComplete: hosting, signIn: signIn,
                                      hasMatchingRow: hasRow, working: working, checkLines: lines, checkRunning: running))
    }

    /// R18: keys in is not done; the check is the judge, and a failed line is the current step.
    func testKeysAloneAreNotSetUp() {
        let b = bar(.hostingApp, .s2s(hid, .credentials), hosting: true)
        XCTAssertEqual(b.context, ZoomBarContext.none)
        XCTAssertEqual(b.primary, .next(.hostingApp, .s2s(hid, .information)), "Continue goes to Zoom's next tab, not back to Greenroom")
        XCTAssertEqual(b.primary.title, "Continue")
        XCTAssertEqual(b.title, "Step 5 of 8 \u{00B7} Copy its keys \u{00B7} Hosting app")
        let m = bar(.meetingApp, .general(mid, .information), meeting: true)
        XCTAssertEqual(m.context, ZoomBarContext.none)
        XCTAssertEqual(m.primary, .next(.meetingApp, .general(mid, .embed)))
    }

    func testSetUpOnlyWhenTheCheckPassedForThatApp() {
        let b = bar(.hostingApp, .s2s(hid, .activation), meeting: true, hosting: true, lines: [line("sdk", .failed, .badCredentials, "Add both General App values")] + hostingPass)
        XCTAssertEqual(b.context, .setUp("Hosting app is set up"))
        XCTAssertEqual(b.primary, .next(.meetingApp, .createdApps), "on to the meeting half")
        let both = bar(.hostingApp, .s2s(hid, .activation), meeting: true, hosting: true, lines: bothPass)
        XCTAssertEqual(both.primary, .backToGreenroom)
        XCTAssertEqual(both.context, .setUp("Hosting app is set up"))
    }

    func testAFailedCheckNeverShowsSetUp() {
        let b = bar(.hostingApp, .s2s(hid, .credentials), meeting: true, hosting: true, lines: scopesFailing)
        XCTAssertNotEqual(b.context, .setUp("Hosting app is set up"))
        XCTAssertNotEqual(b.primary, .backToGreenroom)
    }

    func testTheFirstFailureIsTheCurrentStepAndContinueGoesThere() {
        let onActivation = bar(.hostingApp, .s2s(hid, .activation), meeting: true, hosting: true, lines: scopesFailing)
        XCTAssertEqual(onActivation.title, "Step 7 of 8 \u{00B7} Add 2 missing permissions")
        XCTAssertEqual(onActivation.primary, .next(.hostingApp, .s2s(hid, .scopes)))
        let onScopes = bar(.hostingApp, .s2s(hid, .scopes), meeting: true, hosting: true, lines: scopesFailing)
        XCTAssertEqual(onScopes.title, "Step 7 of 8 \u{00B7} Add 2 missing permissions")
        XCTAssertEqual(onScopes.context, .copyScopes)
        XCTAssertEqual(onScopes.primary, ZoomBarPrimary.none, "Do this step is on the card; nothing to continue to")
    }

    func testAFixLaterInZoomsOrderDoesNotSkipTheTabsBeforeIt() {
        let refused = [line("sdk", .passed), line("account", .failed, .badCredentials, "Zoom did not accept the keys.")]
        // Activation is the fix, but the person is still at Credentials: Zoom's order says Information next.
        let b = bar(.hostingApp, .s2s(hid, .credentials), meeting: true, hosting: true, lines: refused)
        XCTAssertEqual(b.title, "Step 5 of 8 \u{00B7} Copy its keys \u{00B7} Hosting app")
        XCTAssertEqual(b.primary, .next(.hostingApp, .s2s(hid, .information)))
        // On the scopes page the same fix (Activation) is next in order.
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .scopes), meeting: true, hosting: true, lines: refused).primary,
                       .next(.hostingApp, .s2s(hid, .activation)))
        // Once past it, a refused token sends the person back to Activation.
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .activation), meeting: true, hosting: true, lines: refused).primary, ZoomBarPrimary.none)
    }

    func testTheCheckRunningSaysChecking() {
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .credentials), hosting: true, running: true).context, .checking)
        XCTAssertEqual(ZoomBarContext.checking.title, "Checking\u{2026}")
    }

    func testMeetingFixesLeadToEmbed() {
        let off = [line("sdk", .failed, .badCredentials, "Zoom said no. Check that Meeting SDK is enabled.")]
        let b = bar(.meetingApp, .general(mid, .information), meeting: true, lines: off)
        XCTAssertEqual(b.primary, .next(.meetingApp, .general(mid, .embed)))
        XCTAssertNotEqual(b.context, .setUp("Meeting app is set up"))
    }

    func testTheTitleCountsOneRunOfEightStepsInZoomsOrder() {
        let d = " \u{00B7} "
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .credentials)).title, "Step 5 of 8" + d + "Copy its keys" + d + "Hosting app")
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .information)).title, "Step 6 of 8" + d + "Fill in Information")
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .feature)).title, "Step 6 of 8" + d + "Fill in Information")
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .scopes)).title, "Step 7 of 8" + d + "Add the permissions")
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .activation)).title, "Step 8 of 8" + d + "Turn it on")
        XCTAssertEqual(bar(.meetingApp, .general(mid, .information)).title, "Step 2 of 8" + d + "Copy its keys" + d + "Meeting app")
        XCTAssertEqual(bar(.meetingApp, .general(mid, .embed)).title, "Step 3 of 8" + d + "Turn on Meeting SDK")
        XCTAssertEqual(bar(.hostingApp, .chooseType(hid)).title, "Step 4 of 8" + d + "Create the hosting app")
        XCTAssertEqual(bar(.meetingApp, .chooseType(mid)).title, "Step 1 of 8" + d + "Create the meeting app")
    }

    func testBeforeAnAppPageIsKnown() {
        XCTAssertEqual(bar(.hostingApp, .createdApps).title, "Step 4 of 8 \u{00B7} Create the hosting app")
        XCTAssertEqual(bar(.meetingApp, nil).title, "Step 1 of 8 \u{00B7} Find or create the meeting app")
    }

    func testSignInAndPagesWithoutAStep() {
        XCTAssertEqual(bar(.hostingApp, .signIn).title, "Sign in to Zoom")
                XCTAssertEqual(bar(.meetingApp, .general(mid, .other)).title, "Meeting app \u{00B7} Set up the app")
    }

    func testThePageDecidesThePartNotTheRequest() {
        XCTAssertEqual(bar(.meetingApp, .s2s(hid, .scopes)).title, "Step 7 of 8 \u{00B7} Add the permissions")
    }

    func testCopyScopesOnTheHostingScopesStepOnly() {
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .scopes)).context, .copyScopes)
        for page: ZoomMarketplacePage in [.s2s(hid, .activation), .s2s(hid, .credentials), .createdApps, .signIn, .general(mid, .scopes)] {
            XCTAssertEqual(bar(.hostingApp, page).context, ZoomBarContext.none, "\(page)")
        }
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
        XCTAssertEqual(bar(.meetingApp, .createdApps, hasRow: true).title, "Step 1 of 8 \u{00B7} Find the meeting app")
        XCTAssertEqual(bar(.hostingApp, .createdApps, hasRow: true).title, "Step 4 of 8 \u{00B7} Find the hosting app")
        XCTAssertEqual(bar(.meetingApp, .createdApps, hasRow: false).title, "Step 1 of 8 \u{00B7} Create the meeting app")
        // A page that is not Created apps ignores it.
        XCTAssertEqual(bar(.hostingApp, nil, hasRow: true).title, "Step 4 of 8 \u{00B7} Find or create the hosting app")
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
        XCTAssertEqual(b.title, "Step 7 of 8 \u{00B7} Add the permissions")
        XCTAssertEqual(bar(.hostingApp, .createdApps, working: true).context, .working)
        XCTAssertEqual(bar(.hostingApp, .s2s(hid, .scopes), working: false).context, .copyScopes)
    }
}
