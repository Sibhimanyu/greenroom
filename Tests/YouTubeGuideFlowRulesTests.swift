import XCTest

/// The setup guide's YouTube step as two cards (owner, 2026-11-26): "Your
/// YouTube account" and "After each recording", one open at a time. Each
/// card's state and label, which card is open, and where a deep link lands.
final class YouTubeGuideFlowRulesTests: XCTestCase {

    private func account(own: Bool = false, id: String = "", secret: String = "", signedIn: Bool = false,
                         token: YouTubeGoogleApp = .shared, channel: String? = nil) -> YouTubeAccountChoice {
        YouTubeAccountRules.choice(YouTubeAccountFacts(
            route: YouTubeRouteFacts(prefersOwnApp: own, sharedClientID: "123-abc.apps.googleusercontent.com",
                                     ownClientID: id, ownClientSecret: secret),
            signedIn: signedIn, tokenApp: token, channelName: channel, signingIn: false))
    }

    private struct Row {
        let name: String
        let account: YouTubeAccountChoice
        let mode: YouTubeUploadMode
        let kids: Bool?
        let accountState: YouTubeGuideCardState
        let afterState: YouTubeGuideCardState
        let open: YouTubeGuideCard?
        let accountLabel: String
        let afterLabel: String
    }

    func testTheCardTable() {
        let rows: [Row] = [
            Row(name: "fresh: not signed in, Ask", account: account(), mode: .ask, kids: nil,
                accountState: .notStarted, afterState: .done, open: .account,
                accountLabel: "Not signed in", afterLabel: "Ask whether to upload"),
            Row(name: "signed in with Greenroom's, Ask: all done, both folded",
                account: account(signedIn: true, channel: "Sample Channel"), mode: .ask, kids: false,
                accountState: .done, afterState: .done, open: nil,
                accountLabel: "Signed in as Sample Channel", afterLabel: "Ask whether to upload"),
            Row(name: "own app not set up", account: account(own: true), mode: .ask, kids: nil,
                accountState: .notStarted, afterState: .done, open: .account,
                accountLabel: "Not signed in", afterLabel: "Ask whether to upload"),
            Row(name: "own app half pasted", account: account(own: true, id: "x"), mode: .ask, kids: nil,
                accountState: .inProgress, afterState: .done, open: .account,
                accountLabel: "Not signed in", afterLabel: "Ask whether to upload"),
            Row(name: "signed in, Upload automatically without the answer: card 2 opens",
                account: account(signedIn: true, channel: "Sample Channel"), mode: .automatic, kids: nil,
                accountState: .done, afterState: .needsAnswer, open: .afterRecording,
                accountLabel: "Signed in as Sample Channel", afterLabel: "Needs the Made for Kids answer"),
            Row(name: "signed in, Upload automatically, answered",
                account: account(signedIn: true, channel: "Sample Channel"), mode: .automatic, kids: false,
                accountState: .done, afterState: .done, open: nil,
                accountLabel: "Signed in as Sample Channel", afterLabel: "Upload automatically"),
            Row(name: "not signed in, Upload automatically without the answer: the account first",
                account: account(), mode: .automatic, kids: nil,
                accountState: .notStarted, afterState: .needsAnswer, open: .account,
                accountLabel: "Not signed in", afterLabel: "Needs the Made for Kids answer"),
            Row(name: "Do nothing", account: account(), mode: .off, kids: nil,
                accountState: .notStarted, afterState: .done, open: .account,
                accountLabel: "Not signed in", afterLabel: "Do nothing"),
            Row(name: "own chosen, signed in through Greenroom's: not done",
                account: account(own: true, id: "x", secret: "y", signedIn: true, token: .shared), mode: .ask, kids: nil,
                accountState: .inProgress, afterState: .done, open: .account,
                accountLabel: "Not signed in with your own Google app", afterLabel: "Ask whether to upload"),
        ]
        for row in rows {
            let flow = YouTubeGuideFlowRules.flow(account: row.account, mode: row.mode, madeForKids: row.kids)
            XCTAssertEqual(flow.state(.account), row.accountState, row.name)
            XCTAssertEqual(flow.state(.afterRecording), row.afterState, row.name)
            XCTAssertEqual(flow.open, row.open, row.name)
            XCTAssertEqual(flow.label(.account), row.accountLabel, row.name)
            XCTAssertEqual(flow.label(.afterRecording), row.afterLabel, row.name)
        }
    }

    /// Upload automatically shows the Made for Kids answer and the §9.1 line; the others don't.
    func testTheAnswerShowsOnlyForUploadAutomatically() {
        for mode in YouTubeUploadMode.allCases {
            let flow = YouTubeGuideFlowRules.flow(account: account(), mode: mode, madeForKids: nil)
            XCTAssertEqual(flow.showsMadeForKids, mode == .automatic, mode.rawValue)
            XCTAssertEqual(flow.showsCertify, mode == .automatic, mode.rawValue)
        }
    }

    /// One plain line per choice; Do nothing carries what the old amber warning said.
    func testTheModeLines() {
        XCTAssertEqual(YouTubeGuideFlowRules.modeLine(.off), "Do nothing: no recordings leave this Mac.")
        XCTAssertEqual(YouTubeGuideFlowRules.modeLine(.ask),
                       "Ask: after each recording, choose Upload or Not now. Recordings stay in Documents/Greenroom either way.")
        XCTAssertEqual(YouTubeGuideFlowRules.modeLine(.automatic),
                       "Upload automatically: each recording goes to your channel as soon as it ends. A copy stays in Documents/Greenroom.")
    }

    /// Settings' "Set up… / Edit setup…" opens the account card at the own-app part.
    func testDeepLinks() {
        XCTAssertEqual(YouTubeGuideFlowRules.card(for: .ownApp), .account)
        XCTAssertNil(YouTubeGuideFlowRules.card(for: .step))
    }

    func testTheWords() {
        XCTAssertEqual(YouTubeGuideFlowRules.title, "Share recordings on YouTube")
        XCTAssertEqual(YouTubeGuideFlowRules.subtitle,
                       "Optional, and you can do it later. Uploads are Unlisted unless you choose otherwise.")
        XCTAssertEqual(YouTubeGuideFlowRules.footnote, "No sign-in? Every upload sheet also has Upload in YouTube Studio.")
        XCTAssertEqual(YouTubeGuideCard.account.title, "Your YouTube account")
        XCTAssertEqual(YouTubeGuideCard.afterRecording.title, "After each recording")
        XCTAssertEqual(YouTubeUploadMode.allCases, [.off, .ask, .automatic])
    }
}
