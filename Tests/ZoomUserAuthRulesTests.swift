import XCTest

final class ZoomUserAuthRulesTests: XCTestCase {

    func testPKCEMatchesRFC7636Vector() {
        XCTAssertEqual(ZoomPKCE.challenge(forVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testPairIsUrlSafeAndInRange() {
        let pair = ZoomPKCE.pair()
        XCTAssertEqual(pair.verifier.count, 64)
        XCTAssertFalse(pair.verifier.contains("="))
        XCTAssertFalse(pair.verifier.contains("+"))
        XCTAssertEqual(pair.challenge, ZoomPKCE.challenge(forVerifier: pair.verifier))
        XCTAssertNotEqual(ZoomPKCE.pair().verifier, pair.verifier)
        XCTAssertEqual(ZoomPKCE.pair(bytes: [UInt8](repeating: 0xFF, count: 3)).verifier, "____")
    }

    func testAuthorizeURLCarriesEverythingAndNoSecret() throws {
        let url = try XCTUnwrap(ZoomAuthRequest.authorizeURL(
            clientID: ZoomOAuth.publicClientID, redirectURI: ZoomOAuth.redirectURI(port: 53682),
            state: "st", challenge: "ch"))
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.host, "zoom.us")
        XCTAssertEqual(url.path, "/oauth/authorize")
        XCTAssertEqual(items["client_id"], ZoomOAuth.publicClientID)
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:53682/callback")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["state"], "st")
        XCTAssertNil(items["client_secret"])
    }

    func testExchangeFormHasNoSecret() {
        let form = ZoomAuthRequest.codeExchangeForm(code: "c", verifier: "v", redirectURI: "http://127.0.0.1:1/callback", clientID: "id")
        XCTAssertEqual(form["client_id"], "id")
        XCTAssertEqual(form["code_verifier"], "v")
        XCTAssertNil(form["client_secret"])
        let body = String(decoding: ZoomAuthRequest.formBody(form), as: UTF8.self)
        XCTAssertTrue(body.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A1%2Fcallback"))
    }

    func testCallbackCode() {
        XCTAssertEqual(ZoomCallback.parse(target: "/callback?code=abc&state=s1", expectedState: "s1"), .code("abc"))
    }

    func testCallbackStateMismatch() {
        XCTAssertEqual(ZoomCallback.parse(target: "/callback?code=abc&state=other", expectedState: "s1"), .stateMismatch)
        XCTAssertEqual(ZoomCallback.parse(target: "/callback?code=abc", expectedState: "s1"), .stateMismatch)
        XCTAssertEqual(ZoomCallback.parse(target: "/callback?error=access_denied&state=bad", expectedState: "s1"), .stateMismatch)
    }

    func testCallbackError() {
        XCTAssertEqual(ZoomCallback.parse(target: "/callback?error=access_denied&error_description=User%20said%20no&state=s1", expectedState: "s1"),
                       .refused(error: "access_denied", description: "User said no"))
    }

    func testCallbackIgnoresOtherRequests() {
        XCTAssertEqual(ZoomCallback.parse(target: "/favicon.ico", expectedState: "s"), .notCallback)
        XCTAssertEqual(ZoomCallback.parse(target: "/other?code=x&state=s", expectedState: "s"), .notCallback)
        XCTAssertEqual(ZoomCallback.parse(target: "/callback", expectedState: "s"), .notCallback)
    }

    func testRequestTarget() {
        XCTAssertEqual(ZoomCallback.requestTarget(fromRequest: "GET /callback?code=1&state=2 HTTP/1.1\r\nHost: x\r\n\r\n"), "/callback?code=1&state=2")
        XCTAssertEqual(ZoomCallback.requestTarget(fromRequest: ""), "")
    }

    func testTokenParseAndRotation() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let set = try XCTUnwrap(ZoomTokenSet.parse(["access_token": "a", "refresh_token": "r2", "expires_in": 3600], now: now))
        XCTAssertEqual(set.expiresAt, now.addingTimeInterval(3600))
        XCTAssertEqual(ZoomTokenRules.refreshToStore(old: "r1", response: set), "r2")
        let noRotate = try XCTUnwrap(ZoomTokenSet.parse(["access_token": "a", "expires_in": 60], now: now))
        XCTAssertEqual(ZoomTokenRules.refreshToStore(old: "r1", response: noRotate), "r1")
        XCTAssertNil(ZoomTokenSet.parse(["refresh_token": "r"], now: now))
    }

    func testRefreshDecision() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(ZoomTokenRules.decide(cachedExpiry: now.addingTimeInterval(600), hasRefreshToken: true, now: now), .useCached)
        XCTAssertEqual(ZoomTokenRules.decide(cachedExpiry: now.addingTimeInterval(30), hasRefreshToken: true, now: now), .refresh)
        XCTAssertEqual(ZoomTokenRules.decide(cachedExpiry: nil, hasRefreshToken: true, now: now), .refresh)
        XCTAssertEqual(ZoomTokenRules.decide(cachedExpiry: now.addingTimeInterval(-5), hasRefreshToken: false, now: now), .signIn)
    }

    func testRESTSourceChoice() {
        XCTAssertEqual(ZoomCredentialRules.restSource(signedIn: true, ownS2SComplete: true), .signedIn)
        XCTAssertEqual(ZoomCredentialRules.restSource(signedIn: true, ownS2SComplete: false), .signedIn)
        XCTAssertEqual(ZoomCredentialRules.restSource(signedIn: false, ownS2SComplete: true), .ownApps)
        XCTAssertEqual(ZoomCredentialRules.restSource(signedIn: false, ownS2SComplete: false), .none)
    }

    func testSDKAuthChoice() {
        typealias R = ZoomCredentialRules
        XCTAssertEqual(R.sdkAuth(signedIn: true, endpointSet: true, ownKeysPresent: true), .worker)
        XCTAssertEqual(R.sdkAuth(signedIn: true, endpointSet: false, ownKeysPresent: true), .ownKeys)
        XCTAssertEqual(R.sdkAuth(signedIn: true, endpointSet: false, ownKeysPresent: false), .notFinished)
        XCTAssertEqual(R.sdkAuth(signedIn: false, endpointSet: true, ownKeysPresent: true), .ownKeys)
        XCTAssertEqual(R.sdkAuth(signedIn: false, endpointSet: true, ownKeysPresent: false), .missingKeys)
    }

    func testRefusalWords() {
        XCTAssertEqual(ZoomSignInWords.refusal(error: "access_denied", description: nil), "Sign-in was cancelled in Zoom.")
        XCTAssertTrue(ZoomSignInWords.refusal(error: "invalid_scope", description: "Bad scope").contains("Bad scope"))
    }

    func testScopeParsedFromTokenResponse() throws {
        let set = try XCTUnwrap(ZoomTokenSet.parse(["access_token": "a", "scope": "user:read:user meeting:write:meeting", "expires_in": 60], now: Date()))
        XCTAssertEqual(ZoomScopeCheck.parse(set.scope), ["user:read:user", "meeting:write:meeting"])
        XCTAssertNil(try XCTUnwrap(ZoomTokenSet.parse(["access_token": "a"], now: Date())).scope)
    }

    func testScopeCheck() {
        let required = ["a:read", "b:write"]
        XCTAssertEqual(ZoomScopeCheck.check(required: required, granted: ["a:read", "b:write", "extra"]), .ok)
        XCTAssertEqual(ZoomScopeCheck.check(required: required, granted: ["a:read"]), .needsMore(["b:write"]))
        XCTAssertEqual(ZoomScopeCheck.check(required: required, granted: ["a:read:admin", "b:write:admin"]), .ok)
        XCTAssertEqual(ZoomScopeCheck.check(required: required, granted: nil), .unknown)
        XCTAssertEqual(ZoomScopeCheck.check(required: required, granted: []), .unknown)
        // A scope added to the list later is reported until the person signs in again.
        XCTAssertEqual(ZoomScopeCheck.check(required: required + ["c:new"], granted: ["a:read", "b:write"]), .needsMore(["c:new"]))
    }

    func testTodaysRequiredScopesAndTheUpgradeFromFive() {
        let five = "user:read:user user:read:token user:read:zak meeting:read:list_meetings meeting:write:meeting"
        let added: Set<String> = ["meeting:read:meeting", "meeting:update:meeting",
                                  "meeting:update:status", "meeting:delete:meeting"]
        XCTAssertEqual(Set(ZoomOAuth.requiredScopes), ZoomScopeCheck.parse(five).union(added))
        // Someone who signed in with the first five is asked for exactly the four new ones.
        guard case .needsMore(let missing) = ZoomScopeCheck.check(required: ZoomOAuth.requiredScopes,
                                                                  granted: ZoomScopeCheck.parse(five)) else {
            return XCTFail("expected needsMore")
        }
        XCTAssertEqual(Set(missing), added)
        XCTAssertEqual(ZoomScopeCheck.check(required: ZoomOAuth.requiredScopes,
                                            granted: ZoomScopeCheck.parse(five + " " + added.joined(separator: " "))), .ok)
    }

    func testCredentialCheckSameIDIsOK() {
        XCTAssertEqual(ZoomCredentialCheck.check(storedClientID: "abc", currentClientID: "abc"), .ok)
    }

    func testCredentialCheckDifferentIDNeedsSignIn() {
        XCTAssertEqual(ZoomCredentialCheck.check(storedClientID: "old", currentClientID: "new"), .needsSignIn)
    }

    func testCredentialCheckNoIDRecordedIsTheDevelopmentClient() {
        XCTAssertEqual(ZoomCredentialCheck.check(storedClientID: nil, currentClientID: ZoomOAuth.developmentClientID), .ok)
        XCTAssertEqual(ZoomCredentialCheck.check(storedClientID: "", currentClientID: ZoomOAuth.developmentClientID), .ok)
        XCTAssertEqual(ZoomCredentialCheck.check(storedClientID: nil, currentClientID: "production"), .needsSignIn)
    }
}
