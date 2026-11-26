import XCTest

/// What a failing or warning check line offers to click, for both Zoom checks,
/// as one table: check × outcome → the buttons, in order, primary marked "*".
final class ZoomCheckActionRulesTests: XCTestCase {

    private let ids = ZoomCheckActionContext(sdkClientID: "SampleSDKab12", s2sClientID: "SampleS2Scd34")

    private func titles(_ buttons: [ZoomCheckButton]) -> [String] {
        buttons.map { ($0.primary ? "*" : "") + $0.action.title }
    }

    func testEveryCheckAndOutcomeGetsItsButtons() {
        typealias Row = (ZoomCheckKind, String, ZoomCheckStatus, ZoomCheckProblem, [String])
        let table: [Row] = [
            // Your own Zoom apps: the Meeting SDK app's keys.
            (.ownApps, "sdk", .failed, .badCredentials, ["*Open App Credentials", "Show me where"]),
            (.ownApps, "sdk", .failed, .network, ["*Check again"]),
            // The Server-to-Server app: keys, activation, network.
            (.ownApps, "account", .failed, .badCredentials, ["*Open App Credentials", "Show me where"]),
            (.ownApps, "account", .failed, .notActivated, ["*Open the app", "Show me where"]),
            (.ownApps, "account", .failed, .network, ["*Check again"]),
            (.ownApps, "account", .failed, .zoomDown, ["*Check again"]),
            // One scope per line.
            (.ownApps, "update", .failed, .missingScopes(["meeting:update:meeting:admin"]), ["Copy scope", "*Open Scopes page", "Show me where"]),
            (.ownApps, "delete", .failed, .missingScopes(["meeting:delete:meeting:admin"]), ["Copy scope", "*Open Scopes page", "Show me where"]),
            // The API calls after the token.
            (.ownApps, "meetings", .failed, .network, ["*Check again"]),
            (.ownApps, "hostToken", .failed, .zoomDown, ["*Check again"]),
            (.ownApps, "meetings", .failed, .other, []),
            // Sign in with Zoom.
            (.signIn, "token", .failed, .signIn, ["*Sign in again"]),
            (.signIn, "profile", .failed, .signIn, ["*Sign in again"]),
            (.signIn, "profile", .failed, .network, ["*Check again"]),
            (.signIn, "scopes", .failed, .missingScopes(["meeting:write:meeting"]), ["*Sign in again"]),
            (.signIn, "scopes", .warned, .other, ["Sign in again"]),
            (.signIn, "zak", .failed, .signIn, ["*Sign in again"]),
            (.signIn, "zak", .failed, .network, ["*Check again"]),
            (.signIn, "signature", .failed, .other, ["*Check again"]),
            (.signIn, "account", .failed, .otherAccount, ["*Use my own Zoom apps"]),
            (.signIn, "account", .warned, .otherAccount, ["Use my own Zoom apps"]),
            // Lines that are fine, not tried, or left to Start offer nothing.
            (.ownApps, "update", .passed, .nothing, []),
            (.ownApps, "update", .skipped, .nothing, []),
            (.signIn, "create", .atStart, .nothing, []),
            (.ownApps, "sdk", .running, .nothing, []),
            (.ownApps, "sdk", .waiting, .nothing, []),
        ]
        for (kind, check, status, problem, expected) in table {
            let buttons = ZoomCheckActionRules.buttons(kind, check: check, status: status, problem: problem, ids: ids)
            XCTAssertEqual(titles(buttons), expected, "\(kind) \(check) \(status) \(problem)")
            XCTAssertLessThanOrEqual(buttons.filter(\.primary).count, 1, "one primary at most: \(check)")
        }
    }

    func testButtonsCarryWhatTheyNeed() {
        let scope = ZoomCheckActionRules.buttons(.ownApps, check: "update", status: .failed,
                                                 problem: .missingScopes(["meeting:update:meeting:admin"]), ids: ids)
        // Show me where opens the guide's scope list, which marks what is missing.
        XCTAssertEqual(scope.map(\.action), [.copyScope("meeting:update:meeting:admin"), .openScopesPage, .showGuide(.s2sScopes)])
        let sdk = ZoomCheckActionRules.buttons(.ownApps, check: "sdk", status: .failed, problem: .badCredentials, ids: ids)
        XCTAssertEqual(sdk.map(\.action), [.openAppCredentials(.sdk), .showGuide(.sdkCredentials)])
        let s2s = ZoomCheckActionRules.buttons(.ownApps, check: "account", status: .failed, problem: .badCredentials, ids: ids)
        XCTAssertEqual(s2s.map(\.action), [.openAppCredentials(.s2s), .showGuide(.s2sCredentials)])
        let off = ZoomCheckActionRules.buttons(.ownApps, check: "account", status: .failed, problem: .notActivated, ids: ids)
        XCTAssertEqual(off.map(\.action), [.openApp(.s2s), .showGuide(.s2sActivation)])
    }

    /// No deep link to one app's pages exists by client ID, so the tooltip says which app to pick.
    func testTooltipsNameTheAppByItsClientIDTail() {
        let help = { (a: ZoomCheckAction) in ZoomCheckActionRules.help(a, ids: self.ids) }
        XCTAssertEqual(help(.openScopesPage),
                       "Opens your apps in the Zoom App Marketplace. Pick the Server-to-Server app with client ID \u{2026}cd34, then Scopes \u{2192} Add Scopes.")
        XCTAssertEqual(help(.openAppCredentials(.s2s)),
                       "Opens your apps in the Zoom App Marketplace. Pick the Server-to-Server app with client ID \u{2026}cd34, then App Credentials.")
        XCTAssertEqual(help(.openAppCredentials(.sdk)),
                       "Opens your apps in the Zoom App Marketplace. Pick the General App with client ID \u{2026}ab12, then Basic Information \u{2192} App Credentials.")
        XCTAssertEqual(help(.openApp(.s2s)),
                       "Opens your apps in the Zoom App Marketplace. Pick the Server-to-Server app with client ID \u{2026}cd34, then Activation \u{2192} Activate your app.")
        XCTAssertEqual(help(.copyScope("meeting:update:meeting:admin")), "Copies meeting:update:meeting:admin")
        // No client ID yet: the app by its type alone.
        let none = ZoomCheckActionContext(sdkClientID: "", s2sClientID: " ")
        XCTAssertEqual(ZoomCheckActionRules.help(.openScopesPage, ids: none),
                       "Opens your apps in the Zoom App Marketplace. Pick your Server-to-Server app, then Scopes \u{2192} Add Scopes.")
        XCTAssertEqual(ZoomCheckAction.openScopesPage.url, ZoomMarketplaceGuide.builderURL)
        XCTAssertEqual(ZoomCheckAction.openAppCredentials(.sdk).url, ZoomMarketplaceGuide.builderURL)
        XCTAssertNil(ZoomCheckAction.checkAgain.url)
    }

    func testErrorsAreSortedIntoProblems() {
        let p = ZoomCheckActionRules.problem
        XCTAssertEqual(p("Couldn't get a Zoom API token: {\"reason\":\"Invalid client_id or client_secret\",\"error\":\"invalid_client\"}", false), .badCredentials)
        XCTAssertEqual(p("Couldn't get a Zoom API token: {\"reason\":\"This app is not activated\",\"error\":\"invalid_request\"}", false), .notActivated)
        XCTAssertEqual(p("Couldn't get a Zoom API token: <html><body>502 Bad Gateway</body></html>", false), .zoomDown)
        XCTAssertEqual(p("Couldn't get a Zoom API token: Service Unavailable", false), .zoomDown)
        XCTAssertEqual(p("The Internet connection appears to be offline.", true), .network)
    }

    func testTheFixBarCountsWhatToFixAndGathersTheScopes() {
        let lines = [
            ZoomCheckLine(id: "sdk", title: "a", status: .passed),
            ZoomCheckLine(id: "update", title: "b", status: .failed,
                          actions: ZoomCheckActionRules.buttons(.ownApps, check: "update", status: .failed,
                                                                problem: .missingScopes(["meeting:update:meeting:admin"]), ids: ids)),
            ZoomCheckLine(id: "delete", title: "c", status: .failed,
                          actions: ZoomCheckActionRules.buttons(.ownApps, check: "delete", status: .failed,
                                                                problem: .missingScopes(["meeting:delete:meeting:admin"]), ids: ids)),
            ZoomCheckLine(id: "create", title: "d", status: .atStart),
        ]
        let bar = ZoomCheckSummary.fixBar(lines, running: false)
        XCTAssertEqual(bar?.title, "2 things to fix")
        XCTAssertEqual(bar?.missingScopes, ["meeting:update:meeting:admin", "meeting:delete:meeting:admin"])
        XCTAssertEqual(bar?.copyAllText, "meeting:update:meeting:admin\nmeeting:delete:meeting:admin")
        XCTAssertEqual(bar?.offersScopesPage, true)
        XCTAssertEqual(ZoomCheckSummary.missingScopes(lines), ["meeting:update:meeting:admin", "meeting:delete:meeting:admin"])

        let one = [ZoomCheckLine(id: "token", title: "t", status: .failed)]
        XCTAssertEqual(ZoomCheckSummary.fixBar(one, running: false)?.title, "1 thing to fix")
        XCTAssertEqual(ZoomCheckSummary.fixBar(one, running: false)?.offersScopesPage, false)
        let warn = [ZoomCheckLine(id: "account", title: "t", status: .warned)]
        XCTAssertEqual(ZoomCheckSummary.fixBar(warn, running: false)?.title, "1 thing to check")
        XCTAssertNil(ZoomCheckSummary.fixBar(one, running: true), "no bar while the check runs")
        XCTAssertNil(ZoomCheckSummary.fixBar([ZoomCheckLine(id: "a", title: "a", status: .passed)], running: false))
    }

    func testButtonWordsArePlain() {
        let all: [ZoomCheckAction] = [.copyScope("x"), .openScopesPage, .openAppCredentials(.s2s), .openApp(.s2s),
                                      .showGuide(.s2sActivation), .signInAgain, .useOwnApps, .checkAgain]
        XCTAssertEqual(all.map(\.title), ["Copy scope", "Open Scopes page", "Open App Credentials", "Open the app",
                                          "Show me where", "Sign in again", "Use my own Zoom apps", "Check again"])
        for a in all { XCTAssertFalse(a.title.lowercased().contains("class")) }
    }

    /// The sign-in check's lines come with their buttons from the facts.
    func testSignInLinesCarryTheirButtons() {
        let line = { (step: ZoomSignInCheckStep, fact: ZoomSignInCheckFact, error: Error?) in
            self.titles(ZoomSignInCheckRules.line(step, fact, error: error).actions)
        }
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertEqual(line(.token, .failed("Zoom sign-in has expired."), nil), ["*Sign in again"])
        XCTAssertEqual(line(.profile, .failed("offline"), offline), ["*Check again"])
        XCTAssertEqual(line(.scopes, .missingScopes(["meeting:write:meeting"]), nil), ["*Sign in again"])
        XCTAssertEqual(line(.scopes, .unknown, nil), ["Sign in again"])
        XCTAssertEqual(line(.account, .refused(account: "A"), nil), ["*Use my own Zoom apps"])
        XCTAssertEqual(line(.account, .otherThanApp(account: "A"), nil), ["*Use my own Zoom apps"])
        XCTAssertEqual(line(.account, .ownerUnknown(account: "A"), nil), ["Use my own Zoom apps"])
        XCTAssertEqual(line(.account, .sameAsApp, nil), [])
        XCTAssertEqual(line(.zak, .skipped, nil), [])
        XCTAssertEqual(line(.create, .atStart, nil), [])
        XCTAssertEqual(line(.signature, .failed("server not configured"), nil), ["*Check again"])
    }
}
