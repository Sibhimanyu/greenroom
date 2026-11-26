import XCTest

/// The shared Zoom checker (both Settings checks use it) and the sign-in check's
/// steps and words, as a table.
final class ZoomSetupCheckRulesTests: XCTestCase {

    // MARK: The sign-in check: steps in Start's order

    func testTheStepsRunInTheOrderStartNeedsThem() {
        XCTAssertEqual(ZoomSignInCheckStep.allCases,
                       [.token, .profile, .scopes, .zak, .signature, .create, .account])
        XCTAssertEqual(ZoomSignInCheckStep.allCases.map(\.title), [
            "Zoom sign-in is still valid",
            "Your Zoom account answers",
            "Permissions Greenroom needs",
            "Host key for your meetings",
            "Greenroom\u{2019}s signing service",
            "Creating a meeting on your account",
            "Starting meetings on this account",
        ])
    }

    func testEveryOutcomeHasOneStatusAndOnePlainLine() {
        typealias Row = (ZoomSignInCheckStep, ZoomSignInCheckFact, ZoomCheckStatus, String)
        let table: [Row] = [
            (.token, .ok(""), .passed, "Zoom renewed the sign-in token."),
            (.token, .failed("Zoom sign-in has expired."), .failed, "Zoom sign-in has expired. Sign out, then sign in with Zoom again."),
            (.profile, .ok("Sample Host \u{00B7} host@example.com"), .passed, "Signed in as Sample Host \u{00B7} host@example.com."),
            (.profile, .failed("HTTP 401"), .failed, "Zoom didn\u{2019}t return your account: HTTP 401"),
            (.scopes, .ok(""), .passed, "Zoom granted every permission Greenroom asks for."),
            (.scopes, .missingScopes(["meeting:write:meeting"]), .failed,
             "Missing meeting:write:meeting. In Settings \u{2192} Zoom, sign in again and approve it."),
            (.scopes, .unknown, .warned, "Zoom didn\u{2019}t say which permissions it granted. Start will tell."),
            (.zak, .ok(""), .passed, "Zoom returned a host key. No meeting was started."),
            (.zak, .failed("HTTP 400"), .failed, "Zoom didn\u{2019}t return a host key: HTTP 400"),
            (.signature, .ok("\u{2026}wSEQ"), .passed, "The signing service returned a Meeting SDK key for Greenroom\u{2019}s Zoom app (\u{2026}wSEQ, production)."),
            (.signature, .failed("server not configured"), .failed, "The signing service didn\u{2019}t sign: server not configured"),
            (.create, .atStart, .atStart, "Checked at Start: Zoom has no dry run for creating a meeting, so this check doesn\u{2019}t make one."),
            (.account, .sameAsApp, .passed, "This is the account that owns Greenroom\u{2019}s Zoom app, so Start can host here."),
            (.account, .refused(account: "Sample Host"), .failed,
             "Zoom refused a Start with this account (Sample Host). Greenroom\u{2019}s Zoom app can only start meetings on the account that made it, and Zoom has not opened it to other accounts yet. Start will fail until then. Use your own Zoom apps instead: Settings \u{2192} Zoom \u{2192} Your own Zoom apps."),
            (.account, .otherThanApp(account: "Sample Host"), .failed,
             "This account (Sample Host) is not the one that owns Greenroom\u{2019}s Zoom app. Greenroom\u{2019}s Zoom app can only start meetings on the account that made it, and Zoom has not opened it to other accounts yet. Start will fail until then. Use your own Zoom apps instead: Settings \u{2192} Zoom \u{2192} Your own Zoom apps."),
            (.account, .ownerUnknown(account: "Sample Host"), .warned,
             "Greenroom can\u{2019}t tell from here whether this account (Sample Host) owns Greenroom\u{2019}s Zoom app. If it doesn\u{2019}t, Start will fail until Zoom opens the app to other accounts. To be sure, use your own Zoom apps: Settings \u{2192} Zoom \u{2192} Your own Zoom apps."),
            (.zak, .skipped, .skipped, "Not checked: an earlier step failed. Fix it, then check again."),
        ]
        for (step, fact, status, detail) in table {
            let line = ZoomSignInCheckRules.line(step, fact)
            XCTAssertEqual(line.status, status, "\(step) \(fact)")
            XCTAssertEqual(line.detail, detail, "\(step) \(fact)")
            XCTAssertEqual(line.title, step.title)
            XCTAssertEqual(line.id, step.rawValue)
            XCTAssertFalse(detail.lowercased().contains("class"), detail)
        }
    }

    func testWhoOwnsTheAppIsDecidedFromWhatIsKnown() {
        XCTAssertEqual(ZoomSignInCheckRules.accountFact(accountID: "b", name: "B", ownerAccountID: "", refused: ["b"]), .refused(account: "B"))
        XCTAssertEqual(ZoomSignInCheckRules.accountFact(accountID: "a", name: "A", ownerAccountID: "a", refused: []), .sameAsApp)
        XCTAssertEqual(ZoomSignInCheckRules.accountFact(accountID: "b", name: "B", ownerAccountID: "a", refused: []), .otherThanApp(account: "B"))
        XCTAssertEqual(ZoomSignInCheckRules.accountFact(accountID: "b", name: "B", ownerAccountID: "", refused: []), .ownerUnknown(account: "B"))
        // A refusal is proof even when the owner is unknown.
        XCTAssertEqual(ZoomSignInCheckRules.accountFact(accountID: "a", name: "A", ownerAccountID: "a", refused: ["a"]), .refused(account: "A"))
    }

    func testAFailedTokenSkipsTheRest() {
        XCTAssertTrue(ZoomSignInCheckRules.stopsTheRest(.token))
        XCTAssertTrue(ZoomSignInCheckRules.stopsTheRest(.profile))
        XCTAssertFalse(ZoomSignInCheckRules.stopsTheRest(.zak))
    }

    // MARK: The JWT's app key, without trusting it

    func testTheSignedKeyNamesItsApp() {
        // {"alg":"HS256"} . {"appKey":"RJN6abcdwSEQ","role":1} . sig
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJhcHBLZXkiOiJSSk42YWJjZHdTRVEiLCJyb2xlIjoxfQ.c2ln"
        XCTAssertEqual(ZoomSignInCheckRules.appKey(inJWT: jwt), "RJN6abcdwSEQ")
        XCTAssertNil(ZoomSignInCheckRules.appKey(inJWT: "not a jwt"))
        XCTAssertNil(ZoomSignInCheckRules.appKey(inJWT: "a.e30.c")) // {} has no appKey
    }

    // MARK: The shared summary both checks show

    func testTheSummaryCountsWhatWasCheckedHere() {
        let lines = [
            ZoomCheckLine(id: "a", title: "A", status: .passed, detail: ""),
            ZoomCheckLine(id: "b", title: "B", status: .warned, detail: ""),
            ZoomCheckLine(id: "c", title: "C", status: .atStart, detail: ""),
        ]
        XCTAssertEqual(ZoomCheckSummary.count(lines), "1 of 2 checks passed")
        XCTAssertEqual(ZoomCheckSummary.headline(lines, subject: "Zoom sign-in", running: false), "Zoom sign-in needs attention")
        XCTAssertEqual(ZoomCheckSummary.headline(lines, subject: "Zoom sign-in", running: true), "Checking your Zoom sign-in")
        let fine = [ZoomCheckLine(id: "a", title: "A", status: .passed, detail: ""),
                    ZoomCheckLine(id: "c", title: "C", status: .atStart, detail: "")]
        XCTAssertEqual(ZoomCheckSummary.headline(fine, subject: "Zoom setup", running: false), "Zoom setup checks passed")
        XCTAssertEqual(ZoomCheckSummary.trailing(.passed), "Passed")
        XCTAssertEqual(ZoomCheckSummary.trailing(.warned), "Check")
        XCTAssertEqual(ZoomCheckSummary.trailing(.atStart), "At Start")
        XCTAssertNil(ZoomCheckSummary.trailing(.failed))
    }
}
