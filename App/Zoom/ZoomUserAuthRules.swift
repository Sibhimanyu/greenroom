//
//  ZoomUserAuthRules.swift
//  Greenroom
//
//  The pure half of "Sign in with Zoom": PKCE, the authorize URL, reading the
//  browser's callback, when a token needs renewing, and the two decisions about
//  where credentials come from. No network, no SDK, no UI, so Tests/ compiles
//  it on its own.
//
//  The client below is Greenroom's PUBLIC Zoom client: it has no secret to hide
//  (that is the point of PKCE), so its ID can sit in the source. The matching
//  confidential client's secret must never be in the app or the repo; it lives
//  only as a secret on the signature worker (server/sdk-signature).
//
import CryptoKit
import Foundation

enum ZoomOAuth {
    /// The public (PKCE, no secret) Client ID of Greenroom's General app.
    static let publicClientID = "Ug3v8EwRZS4jii6_g8crg"
    static let authorizeURL = "https://zoom.us/oauth/authorize"
    static let tokenURL = "https://zoom.us/oauth/token"
    static let revokeURL = "https://zoom.us/oauth/revoke"
    /// THE list of scopes the signed-in path needs. To change what Greenroom asks
    /// of Zoom: add the scope to the Marketplace app first, then here, then ship.
    /// People who signed in before see "Greenroom needs one more Zoom permission"
    /// with a Sign in again button (see ZoomScopeCheck).
    ///
    /// What each call needs (granular names; classic `user:read` style names are
    /// also accepted when granted):
    ///   GET  /users/me                      user:read:user
    ///   GET  /users/me/token?type=zak       user:read:token (user:read:zak also granted)
    ///   POST /users/me/meetings             meeting:write:meeting
    ///   GET  /users/me/meetings (list, live) meeting:read:list_meetings
    /// Calls the app makes that these do NOT cover yet (each fails with a scope
    /// error, none blocks a start):
    ///   PUT    /meetings/{id}/status        meeting:update:status
    ///   GET    /meetings/{id}               meeting:read:meeting
    ///   PATCH  /meetings/{id}               meeting:update:meeting
    ///   DELETE /meetings/{id}               meeting:delete:meeting
    static let requiredScopes = [
        "user:read:user", "user:read:token", "user:read:zak",
        "meeting:read:list_meetings", "meeting:write:meeting",
        "meeting:read:meeting", "meeting:update:meeting",
        "meeting:update:status", "meeting:delete:meeting",
    ]

    /// Zoom ignores the port for a loopback redirect but not the path.
    static let callbackPath = "/callback"
    static let preferredPort: UInt16 = 53682
    /// How long the browser tab gets before Greenroom stops waiting.
    static let signInTimeout: TimeInterval = 300

    /// Where the Meeting SDK's JWT is signed for people who signed in with
    /// Zoom: the Catalyst function in server/sdk-signature. Empty until the
    /// owner deploys it, then
    /// https://<project>.catalystserverless.com/server/sdk_signature/execute/signature
    static let sdkSignatureEndpoint = "https://greenroom-60083782173.development.catalystserverless.in/server/sdk_signature/execute/signature"

    static func redirectURI(port: UInt16) -> String { "http://127.0.0.1:\(port)\(callbackPath)" }
}

// MARK: - PKCE

enum ZoomPKCE {
    /// RFC 7636 S256: base64url(SHA256(verifier)), no padding.
    static func challenge(forVerifier verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// A verifier of `byteCount` random bytes (48 bytes is 64 characters, in
    /// RFC 7636's 43...128 range) and its challenge. `bytes` is injectable so
    /// tests are deterministic.
    static func pair(bytes: [UInt8]? = nil, byteCount: Int = 48) -> (verifier: String, challenge: String) {
        let verifier = base64URL(Data(bytes ?? randomBytes(byteCount)))
        return (verifier, challenge(forVerifier: verifier))
    }

    static func randomState(byteCount: Int = 16) -> String { base64URL(Data(randomBytes(byteCount))) }

    static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess { bytes = (0..<count).map { _ in UInt8.random(in: 0...255) } }
        return bytes
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - URLs and form bodies

enum ZoomAuthRequest {
    static func authorizeURL(clientID: String, redirectURI: String, state: String, challenge: String) -> URL? {
        var components = URLComponents(string: ZoomOAuth.authorizeURL)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components?.url
    }

    /// Public client: the client ID and the verifier in the body, and no secret
    /// and no Basic header anywhere.
    static func codeExchangeForm(code: String, verifier: String, redirectURI: String, clientID: String) -> [String: String] {
        ["grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
         "code_verifier": verifier, "client_id": clientID]
    }

    static func refreshForm(refreshToken: String, clientID: String) -> [String: String] {
        ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID]
    }

    static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let text = fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        return Data(text.utf8)
    }
}

// MARK: - The browser's callback

enum ZoomCallback {
    enum Outcome: Equatable {
        /// A good redirect: the one-time code.
        case code(String)
        /// The person said no, or Zoom refused: `error` (and its description).
        case refused(error: String, description: String?)
        /// The redirect carried a state other than the one Greenroom sent.
        case stateMismatch
        /// Not the redirect at all (a favicon probe, another path).
        case notCallback
    }

    /// `target` is the request target of the HTTP request line, for example
    /// "/callback?code=abc&state=xyz".
    static func parse(target: String, expectedState: String) -> Outcome {
        guard let components = URLComponents(string: "http://127.0.0.1\(target)"),
              components.path == ZoomOAuth.callbackPath else { return .notCallback }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("code") != nil || value("error") != nil else { return .notCallback }
        // The state is checked before anything else is believed, errors included.
        guard value("state") == expectedState else { return .stateMismatch }
        if let error = value("error") { return .refused(error: error, description: value("error_description")) }
        if let code = value("code"), !code.isEmpty { return .code(code) }
        return .notCallback
    }

    /// "GET /callback?x=y HTTP/1.1" to "/callback?x=y".
    static func requestTarget(fromRequest request: String) -> String {
        let line = request.split(separator: "\r\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
    }
}

// MARK: - Tokens

struct ZoomTokenSet: Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    /// Space-separated scopes Zoom says the token carries, when it says.
    var scope: String? = nil

    /// Reads Zoom's token response. A refresh grant rotates the refresh token,
    /// so `refreshToken` is nil only when Zoom did not send one.
    static func parse(_ json: [String: Any], now: Date) -> ZoomTokenSet? {
        guard let access = json["access_token"] as? String, !access.isEmpty else { return nil }
        let seconds = (json["expires_in"] as? Double) ?? Double(json["expires_in"] as? Int ?? 3600)
        let refresh = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let scope = (json["scope"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        return ZoomTokenSet(accessToken: access, refreshToken: refresh, expiresAt: now.addingTimeInterval(seconds), scope: scope)
    }
}

enum ZoomTokenRules {
    enum Decision: Equatable { case useCached, refresh, signIn }

    /// Renew a minute early so a token never expires mid-request.
    static let skew: TimeInterval = 60

    static func decide(cachedExpiry: Date?, hasRefreshToken: Bool, now: Date) -> Decision {
        if let expiry = cachedExpiry, expiry.timeIntervalSince(now) > skew { return .useCached }
        return hasRefreshToken ? .refresh : .signIn
    }

    /// Zoom rotates the refresh token on each use; keep the new one, or the old
    /// one when none came back.
    static func refreshToStore(old: String, response: ZoomTokenSet) -> String { response.refreshToken ?? old }
}

// MARK: - Granted scopes versus required

enum ZoomScopeCheck {
    enum Result: Equatable {
        case ok
        /// Zoom never told us what was granted; nothing to compare, so no nagging.
        case unknown
        case needsMore([String])
    }

    static func parse(_ scope: String?) -> Set<String> {
        Set((scope ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
    }

    /// A required scope is met by its own name or the same name with ":admin".
    static func isGranted(_ required: String, in granted: Set<String>) -> Bool {
        granted.contains(required) || granted.contains(required + ":admin")
    }

    static func missing(required: [String], granted: Set<String>) -> [String] {
        required.filter { !isGranted($0, in: granted) }
    }

    static func check(required: [String], granted: Set<String>?) -> Result {
        guard let granted, !granted.isEmpty else { return .unknown }
        let gap = missing(required: required, granted: granted)
        return gap.isEmpty ? .ok : .needsMore(gap)
    }

    static let promptTitle = "Greenroom needs one more Zoom permission"
    static let promptDetail = "Sign in again and approve it in your browser. Your meetings and settings stay as they are."
}

// MARK: - Where credentials come from

enum ZoomCredentialRules {
    /// Who answers the REST calls (meetings, list, ZAK).
    enum RESTSource: Equatable { case signedIn, ownApps, none }

    static func restSource(signedIn: Bool, ownS2SComplete: Bool) -> RESTSource {
        if signedIn { return .signedIn }
        return ownS2SComplete ? .ownApps : .none
    }

    /// Who signs the Meeting SDK's JWT.
    enum SDKAuth: Equatable {
        /// The worker signs it, with the signed-in person's Zoom token as proof.
        case worker
        /// Greenroom signs it from the SDK key and secret the person pasted.
        case ownKeys
        /// Signed in, but no worker is set up and no own keys: say so.
        case notFinished
        /// Not signed in and no own keys.
        case missingKeys
    }

    static func sdkAuth(signedIn: Bool, endpointSet: Bool, ownKeysPresent: Bool) -> SDKAuth {
        if signedIn && endpointSet { return .worker }
        if ownKeysPresent { return .ownKeys }
        return signedIn ? .notFinished : .missingKeys
    }

    static let notFinishedText = "Sign in with Zoom isn\u{2019}t finished setting up yet. Use your own Zoom apps (advanced) in Settings \u{2192} Zoom for now."
}

// MARK: - Plain words for failures

enum ZoomSignInWords {
    static func refusal(error: String, description: String?) -> String {
        switch error {
        case "access_denied": return "Sign-in was cancelled in Zoom."
        default:
            let why = (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return why.isEmpty ? "Zoom refused the sign-in (\(error))." : "Zoom refused the sign-in: \(why)"
        }
    }
}
