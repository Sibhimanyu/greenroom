import XCTest

/// The Google consent URL Greenroom opens: PKCE S256, a loopback redirect,
/// and the prompt that always shows the account chooser and returns a
/// refresh token.
final class YouTubeOAuthTests: XCTestCase {

    private func items(_ url: URL) -> [String: String] {
        let pairs = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(pairs.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    private var url: URL {
        YouTubeOAuth.authURL(clientID: "id.apps.googleusercontent.com",
                             redirectURI: YouTubeOAuth.redirectURI(port: 53682),
                             challenge: "CHALLENGE", state: "STATE")
    }

    func testItGoesToGooglesAuthEndpoint() {
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(url.path, "/o/oauth2/v2/auth")
    }

    func testAlwaysShowsTheAccountChooserAndAsksForARefreshToken() {
        let q = items(url)
        XCTAssertEqual(q["prompt"], "select_account consent")
        XCTAssertEqual(q["access_type"], "offline")
    }

    func testUsesPKCES256() {
        let q = items(url)
        XCTAssertEqual(q["code_challenge"], "CHALLENGE")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["state"], "STATE")
    }

    func testRedirectsToTheLoopbackAddress() {
        XCTAssertEqual(YouTubeOAuth.redirectURI(port: 53682), "http://127.0.0.1:53682")
        XCTAssertEqual(items(url)["redirect_uri"], "http://127.0.0.1:53682")
    }

    func testAsksForTheYouTubeScopeAndTheClient() {
        let q = items(url)
        XCTAssertEqual(q["scope"], "https://www.googleapis.com/auth/youtube.force-ssl")
        XCTAssertEqual(q["client_id"], "id.apps.googleusercontent.com")
    }

    /// RFC 7636, appendix B.
    func testTheChallengeIsTheRFCsS256() {
        XCTAssertEqual(YouTubeOAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testTheSharedClientIsTheDesktopKind() {
        XCTAssertTrue(YouTubeOAuth.sharedClientID.hasSuffix(".apps.googleusercontent.com"))
    }
}
