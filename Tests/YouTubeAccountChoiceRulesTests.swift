import XCTest

/// Settings -> YouTube as one choice of two (owner, 2026-11-26): the option
/// picked is the section shown, its status line, its buttons, and where
/// "Set up… / Edit setup…" opens the setup guide. As a table.
final class YouTubeAccountChoiceRulesTests: XCTestCase {

    private let shared = "123-abc.apps.googleusercontent.com"

    private func facts(own: Bool = false, sharedID: String? = nil, id: String = "", secret: String = "",
                       signedIn: Bool = false, token: YouTubeGoogleApp = .shared,
                       channel: String? = nil, signingIn: Bool = false) -> YouTubeAccountFacts {
        YouTubeAccountFacts(route: YouTubeRouteFacts(prefersOwnApp: own, sharedClientID: sharedID ?? shared,
                                                     ownClientID: id, ownClientSecret: secret),
                            signedIn: signedIn, tokenApp: token, channelName: channel, signingIn: signingIn)
    }

    private struct Row {
        let name: String
        let facts: YouTubeAccountFacts
        let selected: YouTubeAppOption
        let account: String
        let setupStatus: String?
        let buttons: [YouTubeAccountButton]
        let signInEnabled: Bool
        let setupEntry: YouTubeSetupEntry?
        let ready: Bool
    }

    func testTheChoiceTable() {
        let setUp = YouTubeSetupEntry(title: "Set up\u{2026}", spot: .ownApp)
        let edit = YouTubeSetupEntry(title: "Edit setup\u{2026}", spot: .ownApp)
        let rows: [Row] = [
            Row(name: "Greenroom's, not signed in", facts: facts(),
                selected: .greenroom, account: "Not signed in", setupStatus: nil,
                buttons: [.signIn], signInEnabled: true, setupEntry: nil, ready: false),
            Row(name: "Greenroom's, signed in", facts: facts(signedIn: true, channel: "Sample Channel"),
                selected: .greenroom, account: "Signed in as Sample Channel", setupStatus: nil,
                buttons: [.useAnotherAccount, .signOut], signInEnabled: true, setupEntry: nil, ready: true),
            Row(name: "Greenroom's, signed in, channel not read yet", facts: facts(signedIn: true),
                selected: .greenroom, account: "Signed in", setupStatus: nil,
                buttons: [.useAnotherAccount, .signOut], signInEnabled: true, setupEntry: nil, ready: true),
            Row(name: "Greenroom's, waiting for Google", facts: facts(signingIn: true),
                selected: .greenroom, account: "Waiting for Google in your browser\u{2026}", setupStatus: nil,
                buttons: [.signIn], signInEnabled: false, setupEntry: nil, ready: false),
            Row(name: "Greenroom's, shared app still a placeholder", facts: facts(sharedID: "PLACEHOLDER.x"),
                selected: .greenroom, account: "Not available yet", setupStatus: nil,
                buttons: [.signIn], signInEnabled: false, setupEntry: nil, ready: false),
            Row(name: "Greenroom's chosen, signed in through your own: no silent fallback",
                facts: facts(id: "own", secret: "s", signedIn: true, token: .own, channel: "Sample Channel"),
                selected: .greenroom, account: "Not signed in with Greenroom\u{2019}s Google app", setupStatus: nil,
                buttons: [.signIn, .signOut], signInEnabled: true, setupEntry: nil, ready: false),
            Row(name: "Own, nothing pasted", facts: facts(own: true),
                selected: .own, account: "Not signed in", setupStatus: "Needs a Client ID and Secret",
                buttons: [.signIn], signInEnabled: false, setupEntry: setUp, ready: false),
            Row(name: "Own, only the ID", facts: facts(own: true, id: "own"),
                selected: .own, account: "Not signed in", setupStatus: "Needs the Client Secret",
                buttons: [.signIn], signInEnabled: false, setupEntry: edit, ready: false),
            Row(name: "Own, only the secret", facts: facts(own: true, secret: "s"),
                selected: .own, account: "Not signed in", setupStatus: "Needs the Client ID",
                buttons: [.signIn], signInEnabled: false, setupEntry: edit, ready: false),
            Row(name: "Own, set up, not signed in", facts: facts(own: true, id: "own", secret: "s"),
                selected: .own, account: "Not signed in", setupStatus: "Ready",
                buttons: [.signIn], signInEnabled: true, setupEntry: edit, ready: false),
            Row(name: "Own, set up and signed in",
                facts: facts(own: true, id: "own", secret: "s", signedIn: true, token: .own, channel: "Sample Channel"),
                selected: .own, account: "Signed in as Sample Channel", setupStatus: "Ready",
                buttons: [.useAnotherAccount, .signOut], signInEnabled: true, setupEntry: edit, ready: true),
            Row(name: "Own chosen, signed in through Greenroom's: no silent fallback",
                facts: facts(own: true, id: "own", secret: "s", signedIn: true, token: .shared),
                selected: .own, account: "Not signed in with your own Google app", setupStatus: "Ready",
                buttons: [.signIn, .signOut], signInEnabled: true, setupEntry: edit, ready: false),
            Row(name: "Own signed in, then the secret cleared: can't refresh, not ready",
                facts: facts(own: true, id: "own", signedIn: true, token: .own, channel: "Sample Channel"),
                selected: .own, account: "Signed in as Sample Channel", setupStatus: "Needs the Client Secret",
                buttons: [.useAnotherAccount, .signOut], signInEnabled: false, setupEntry: edit, ready: false),
        ]
        for row in rows {
            let c = YouTubeAccountRules.choice(row.facts)
            XCTAssertEqual(c.selected, row.selected, row.name)
            XCTAssertEqual(c.account, row.account, row.name)
            XCTAssertEqual(c.setupStatus, row.setupStatus, row.name)
            XCTAssertEqual(c.buttons, row.buttons, row.name)
            XCTAssertEqual(c.signInEnabled, row.signInEnabled, row.name)
            XCTAssertEqual(c.setupEntry, row.setupEntry, row.name)
            XCTAssertEqual(c.readyToUpload, row.ready, row.name)
        }
    }

    /// Green (good) only for real success: a sign-in on the chosen app, or own app's keys complete.
    func testTonesAreGreenOnlyForRealSuccess() {
        XCTAssertEqual(YouTubeAccountRules.choice(facts()).accountTone, .waiting)
        XCTAssertEqual(YouTubeAccountRules.choice(facts(signedIn: true)).accountTone, .good)
        XCTAssertEqual(YouTubeAccountRules.choice(facts(signedIn: true, token: .own)).accountTone, .waiting)
        XCTAssertEqual(YouTubeAccountRules.choice(facts(own: true)).setupTone, .waiting)
        XCTAssertEqual(YouTubeAccountRules.choice(facts(own: true, id: "x")).setupTone, .problem)
        XCTAssertEqual(YouTubeAccountRules.choice(facts(own: true, id: "x", secret: "y")).setupTone, .good)
        XCTAssertNil(YouTubeAccountRules.choice(facts()).setupTone)
    }

    /// The line under the account: what to do next, never silent.
    func testTheHintSaysWhatToDo() {
        XCTAssertNil(YouTubeAccountRules.choice(facts()).hint)
        XCTAssertNil(YouTubeAccountRules.choice(facts(signedIn: true)).hint)
        XCTAssertEqual(YouTubeAccountRules.choice(facts(own: true)).hint,
                       "Set up your Google app first, then sign in.")
        XCTAssertEqual(YouTubeAccountRules.choice(facts(signedIn: true, token: .own)).hint,
                       "You are signed in through your own Google app. Sign in again to use Greenroom\u{2019}s.")
        XCTAssertEqual(YouTubeAccountRules.choice(facts(own: true, id: "a", secret: "b", signedIn: true, token: .shared)).hint,
                       "You are signed in through Greenroom\u{2019}s Google app. Sign in again to use your own.")
        XCTAssertEqual(YouTubeAccountRules.choice(facts(sharedID: "PLACEHOLDER")).hint,
                       YouTubeRouteGap.sharedNotAvailableYet.message)
    }

    func testTheOptionWords() {
        XCTAssertEqual(YouTubeAppOption.allCases, [.greenroom, .own])
        XCTAssertEqual(YouTubeAppOption.greenroom.title, "Greenroom\u{2019}s Google app")
        XCTAssertEqual(YouTubeAppOption.own.title, "Your own Google app")
        XCTAssertEqual(YouTubeAppOption.greenroom.note,
                       "Sign in with any Google account. Google may show \u{201C}hasn\u{2019}t verified this app\u{201D}: click Advanced, then Go to Greenroom.")
        XCTAssertEqual(YouTubeAppOption.own.note,
                       "For when Greenroom\u{2019}s app has reached Google\u{2019}s 100-person limit, or to have your own daily upload limit.")
        XCTAssertEqual(YouTubeAppOption(prefersOwnApp: true), .own)
        XCTAssertEqual(YouTubeAppOption(prefersOwnApp: false), .greenroom)
        XCTAssertTrue(YouTubeAppOption.own.prefersOwnApp)
        XCTAssertEqual(YouTubeAppOption.greenroom.app, .shared)
        XCTAssertEqual(YouTubeAppOption.own.app, .own)
    }

    /// The default: fresh installs on Greenroom's app; anyone with their own client pasted carries over to Own.
    func testTheDefaultChoice() {
        XCTAssertEqual(YouTubeAppOption(prefersOwnApp: YouTubeRouteRules.initialPrefersOwnApp(saved: nil, ownClientComplete: false)), .greenroom)
        XCTAssertEqual(YouTubeAppOption(prefersOwnApp: YouTubeRouteRules.initialPrefersOwnApp(saved: nil, ownClientComplete: true)), .own)
        XCTAssertEqual(YouTubeAppOption(prefersOwnApp: YouTubeRouteRules.initialPrefersOwnApp(saved: false, ownClientComplete: true)), .greenroom)
    }
}
