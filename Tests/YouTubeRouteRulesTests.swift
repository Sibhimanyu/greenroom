import XCTest

/// Which Google app (OAuth client) YouTube sign-in uses: Greenroom's shared
/// one, or the person's own pasted one. One rule, read by Settings, the
/// upload sheet and the token refresh, as a table.
final class YouTubeRouteRulesTests: XCTestCase {

    private let realShared = "123-abc.apps.googleusercontent.com"
    private let placeholder = "PLACEHOLDER.apps.googleusercontent.com"

    private func facts(ownApp: Bool = false, shared: String? = nil,
                       ownID: String = "", ownSecret: String = "") -> YouTubeRouteFacts {
        YouTubeRouteFacts(prefersOwnApp: ownApp, sharedClientID: shared ?? realShared,
                          ownClientID: ownID, ownClientSecret: ownSecret)
    }

    func testTheRouteTable() {
        let rows: [(String, YouTubeRouteFacts, YouTubeRoute)] = [
            ("shared chosen, shared real", facts(), .shared),
            ("shared chosen, shared still a placeholder", facts(shared: placeholder), .none(.sharedNotAvailableYet)),
            ("shared chosen, shared empty", facts(shared: ""), .none(.sharedNotAvailableYet)),
            ("shared chosen, own pasted: the choice wins", facts(ownID: "own", ownSecret: "s"), .shared),
            ("own chosen, own pasted", facts(ownApp: true, ownID: "own", ownSecret: "s"), .own),
            ("own chosen, nothing pasted", facts(ownApp: true), .none(.ownAppNotSetUp)),
            ("own chosen, only the ID", facts(ownApp: true, ownID: "own"), .none(.ownAppIncomplete)),
            ("own chosen, only the secret", facts(ownApp: true, ownSecret: "s"), .none(.ownAppIncomplete)),
            ("own chosen, whitespace only", facts(ownApp: true, ownID: "  ", ownSecret: "\n"), .none(.ownAppNotSetUp)),
            ("own chosen, shared placeholder does not matter", facts(ownApp: true, shared: placeholder, ownID: "own", ownSecret: "s"), .own),
        ]
        for (name, f, expected) in rows {
            XCTAssertEqual(YouTubeRouteRules.signInRoute(f), expected, name)
        }
    }

    func testPlaceholderIsNotAvailable() {
        XCTAssertFalse(YouTubeRouteRules.sharedAvailable(clientID: placeholder))
        XCTAssertFalse(YouTubeRouteRules.sharedAvailable(clientID: "  "))
        XCTAssertTrue(YouTubeRouteRules.sharedAvailable(clientID: realShared))
    }

    /// The shipped constant is a placeholder until the owner pastes the real one.
    func testTheShippedSharedClientIsRecognisedEitherWay() {
        let id = YouTubeOAuth.sharedClient.id
        XCTAssertEqual(YouTubeRouteRules.sharedAvailable(clientID: id), !id.hasPrefix("PLACEHOLDER"))
    }

    /// A refresh token only works with the app that issued it. Tokens from
    /// before the shared app existed came from the person's own app.
    func testTheTokenRefreshesWithTheAppThatIssuedIt() {
        XCTAssertEqual(YouTubeRouteRules.tokenApp(issuedBy: .shared), .shared)
        XCTAssertEqual(YouTubeRouteRules.tokenApp(issuedBy: .own), .own)
        XCTAssertEqual(YouTubeRouteRules.tokenApp(issuedBy: nil), .own)
    }

    /// First launch after the update: people who pasted their own app keep
    /// it; everyone else starts on Sign in with Google. A saved choice wins.
    func testTheInitialChoice() {
        XCTAssertFalse(YouTubeRouteRules.initialPrefersOwnApp(saved: nil, ownClientComplete: false))
        XCTAssertTrue(YouTubeRouteRules.initialPrefersOwnApp(saved: nil, ownClientComplete: true))
        XCTAssertFalse(YouTubeRouteRules.initialPrefersOwnApp(saved: false, ownClientComplete: true))
        XCTAssertTrue(YouTubeRouteRules.initialPrefersOwnApp(saved: true, ownClientComplete: false))
    }

    func testEveryGapSaysWhatToDo() {
        XCTAssertEqual(YouTubeRouteGap.sharedNotAvailableYet.message,
                       "Sign in with Google isn\u{2019}t available in this version yet. Use your own Google app, or Upload in YouTube Studio.")
        XCTAssertEqual(YouTubeRouteGap.ownAppNotSetUp.message,
                       "Paste your Google app\u{2019}s Client ID and Client Secret first.")
        XCTAssertEqual(YouTubeRouteGap.ownAppIncomplete.message,
                       "Paste both the Client ID and the Client Secret.")
    }
}
