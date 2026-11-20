//
//  ZoomUserAuth.swift
//  Greenroom
//
//  "Sign in with Zoom": the person's own Zoom account, through the system
//  browser, with PKCE and Greenroom's PUBLIC client (no secret anywhere in the
//  app). Gives Greenroom a user access token, from which it creates, lists and
//  ends meetings and fetches the host key (ZAK), the same calls the
//  Server-to-Server client makes, but as the person.
//
//  Tokens: the refresh token lives in SecretStore (plain UserDefaults, like
//  every other credential here; no Keychain by design). The access token stays
//  in memory with its expiry and is renewed a minute early. Zoom rotates the
//  refresh token on each use, so the new one replaces the old.
//
//  Zoom types stay in App/Zoom: outside callers see `ZoomUserProfile`, plain
//  values and the existing `ZoomServerToServerClient` meeting structs.
//
import AppKit
import Combine
import Foundation

struct ZoomUserProfile: Codable, Equatable {
    var id: String
    var name: String
    var email: String
    var accountID: String
}

enum ZoomUserAuthError: LocalizedError, Equatable {
    case cancelled, timedOut, noPort(String), refused(String)
    case notSignedIn, signInExpired, requestFailed(String), badResponse

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign-in was cancelled."
        case .timedOut: return "Zoom didn\u{2019}t answer within five minutes. Try signing in again."
        case .noPort(let why): return "Greenroom couldn\u{2019}t open a local page for Zoom to come back to (\(why))."
        case .refused(let why): return why
        case .notSignedIn: return "You\u{2019}re not signed in with Zoom. Settings \u{2192} Zoom \u{2192} Sign in with Zoom."
        case .signInExpired: return "Your Zoom sign-in has expired. Sign in again in Settings \u{2192} Zoom."
        case .requestFailed(let why): return "Zoom refused that: \(why)"
        case .badResponse: return "Zoom\u{2019}s answer wasn\u{2019}t what Greenroom expected."
        }
    }
}

@MainActor
final class ZoomUserAuth: ObservableObject {

    enum Phase: Equatable { case signedOut, signingIn, signedIn }

    @Published private(set) var phase: Phase
    @Published private(set) var profile: ZoomUserProfile?
    /// Plain-words reason the last sign-in did not finish; nil after success.
    @Published private(set) var lastError: String?

    private static let refreshKey = "zoomUserRefreshToken"
    private static let profileKey = "zoomUserProfile"

    private var tokens: ZoomTokenSet?
    private var signInTask: Task<Void, Error>?
    private var refreshTask: Task<ZoomTokenSet, Error>?
    private let defaults = UserDefaults.standard

    init() {
        let hasRefresh = !(SecretStore.get(Self.refreshKey) ?? "").isEmpty
        phase = hasRefresh ? .signedIn : .signedOut
        if hasRefresh, let data = defaults.data(forKey: Self.profileKey) {
            profile = try? JSONDecoder().decode(ZoomUserProfile.self, from: data)
        }
    }

    var isSignedIn: Bool { phase == .signedIn }
    private var refreshToken: String? {
        let value = SecretStore.get(Self.refreshKey) ?? ""
        return value.isEmpty ? nil : value
    }

    // MARK: Sign in and out

    /// Opens the system browser and waits for Zoom to call back. Runs up to
    /// five minutes; `cancelSignIn()` ends it at once.
    func signIn() async throws {
        guard signInTask == nil else { return }
        phase = .signingIn
        lastError = nil
        let task = Task { try await self.performSignIn() }
        signInTask = task
        defer { signInTask = nil }
        do {
            try await task.value
            phase = .signedIn
        } catch {
            phase = refreshToken == nil ? .signedOut : .signedIn
            let mapped = Self.map(error)
            lastError = mapped.errorDescription
            throw mapped
        }
    }

    func cancelSignIn() { signInTask?.cancel() }

    /// Revokes at Zoom when the public client is allowed to, and always
    /// forgets the account here. Returns true when Zoom confirmed the revoke,
    /// false when only the local copy was deleted.
    @discardableResult
    func signOut() async -> Bool {
        var revoked = false
        let current = try? await accessToken()
        if let token = current {
            var request = URLRequest(url: URL(string: ZoomOAuth.revokeURL)!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = ZoomAuthRequest.formBody(["token": token, "client_id": ZoomOAuth.publicClientID])
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                revoked = true
            }
        }
        clearLocal()
        lastError = nil
        return revoked
    }

    private func performSignIn() async throws {
        let pkce = ZoomPKCE.pair()
        let state = ZoomPKCE.randomState()
        let listener = try ZoomLoopbackListener.start()
        defer { listener.stop() }
        let redirectURI = ZoomOAuth.redirectURI(port: listener.port)
        guard let url = ZoomAuthRequest.authorizeURL(clientID: ZoomOAuth.publicClientID, redirectURI: redirectURI,
                                                     state: state, challenge: pkce.challenge) else {
            throw ZoomUserAuthError.badResponse
        }
        NSWorkspace.shared.open(url)
        let code = try await listener.waitForCode(expectedState: state, timeout: ZoomOAuth.signInTimeout)
        do {
            let form = ZoomAuthRequest.codeExchangeForm(code: code, verifier: pkce.verifier,
                                                        redirectURI: redirectURI, clientID: ZoomOAuth.publicClientID)
            let set = try await tokenRequest(form)
            guard let refresh = set.refreshToken else { throw ZoomUserAuthError.badResponse }
            SecretStore.set(refresh, forKey: Self.refreshKey)
            tokens = set
            profile = try await loadProfile()
            listener.reply(success: true, detail: "")
        } catch {
            clearLocal()
            listener.reply(success: false, detail: Self.map(error).errorDescription ?? "")
            throw error
        }
    }

    private func clearLocal() {
        SecretStore.set("", forKey: Self.refreshKey)
        defaults.removeObject(forKey: Self.profileKey)
        tokens = nil
        profile = nil
        phase = .signedOut
    }

    private static func map(_ error: Error) -> ZoomUserAuthError {
        if let mine = error as? ZoomUserAuthError { return mine }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
        return .requestFailed(error.localizedDescription)
    }

    // MARK: Tokens

    /// A valid access token, renewed first when it is about to expire.
    func accessToken() async throws -> String {
        switch ZoomTokenRules.decide(cachedExpiry: tokens?.expiresAt, hasRefreshToken: refreshToken != nil, now: Date()) {
        case .useCached: return tokens!.accessToken
        case .refresh: return try await refresh().accessToken
        case .signIn: throw ZoomUserAuthError.notSignedIn
        }
    }

    private func refresh() async throws -> ZoomTokenSet {
        if let running = refreshTask { return try await running.value }
        guard let old = refreshToken else { throw ZoomUserAuthError.notSignedIn }
        let task = Task { try await self.tokenRequest(ZoomAuthRequest.refreshForm(refreshToken: old, clientID: ZoomOAuth.publicClientID)) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let set = try await task.value
            SecretStore.set(ZoomTokenRules.refreshToStore(old: old, response: set), forKey: Self.refreshKey)
            tokens = set
            return set
        } catch ZoomUserAuthError.signInExpired {
            clearLocal()
            lastError = ZoomUserAuthError.signInExpired.errorDescription
            throw ZoomUserAuthError.signInExpired
        }
    }

    private func tokenRequest(_ form: [String: String]) async throws -> ZoomTokenSet {
        var request = URLRequest(url: URL(string: ZoomOAuth.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = ZoomAuthRequest.formBody(form)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if (json["error"] as? String) == "invalid_grant", form["grant_type"] == "refresh_token" {
                throw ZoomUserAuthError.signInExpired
            }
            let why = (json["reason"] as? String) ?? (json["error_description"] as? String)
                ?? (json["error"] as? String) ?? "HTTP \(status)"
            throw ZoomUserAuthError.refused("Zoom refused the sign-in: \(why)")
        }
        guard let set = ZoomTokenSet.parse(json, now: Date()) else { throw ZoomUserAuthError.badResponse }
        return set
    }

    // MARK: Profile

    @discardableResult
    func loadProfile() async throws -> ZoomUserProfile {
        let (data, _) = try await call("GET", "/users/me")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ZoomUserAuthError.badResponse }
        let first = json["first_name"] as? String ?? ""
        let last = json["last_name"] as? String ?? ""
        let name = (json["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        let profile = ZoomUserProfile(id: json["id"] as? String ?? "", name: name,
                                      email: json["email"] as? String ?? "",
                                      accountID: json["account_id"] as? String ?? "")
        self.profile = profile
        defaults.set(try? JSONEncoder().encode(profile), forKey: Self.profileKey)
        return profile
    }

    // MARK: REST (the same endpoints ZoomServerToServerClient calls, as the person)

    /// One call with the user's token; a 401 renews the token once and retries.
    private func call(_ method: String, _ path: String, body: Data? = nil) async throws -> (Data, Int) {
        func send(_ token: String) async throws -> (Data, Int) {
            var request = URLRequest(url: URL(string: "https://api.zoom.us/v2\(path)")!)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        var result = try await send(try await accessToken())
        if result.1 == 401 {
            tokens = nil
            result = try await send(try await accessToken())
        }
        return result
    }

    private func ok(_ result: (Data, Int)) throws -> Data {
        guard (200...299).contains(result.1) else {
            throw ZoomUserAuthError.requestFailed(ZoomServerToServerError.plainMessage(String(decoding: result.0, as: UTF8.self)))
        }
        return result.0
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ZoomUserAuthError.badResponse }
        return json
    }

    /// The host key. Short-lived: fetch fresh per start.
    func zak() async throws -> String {
        let json = try object(try ok(try await call("GET", "/users/me/token?type=zak")))
        guard let token = json["token"] as? String, !token.isEmpty else { throw ZoomUserAuthError.badResponse }
        return token
    }

    func startInstantMeeting(topic: String) async throws -> ZoomServerToServerClient.CreatedMeeting {
        let body = try JSONSerialization.data(withJSONObject: ["topic": topic, "type": 1])
        let json = try object(try ok(try await call("POST", "/users/me/meetings", body: body)))
        guard let id = json["id"] as? Int64, let startString = json["start_url"] as? String,
              let startURL = URL(string: startString) else { throw ZoomUserAuthError.badResponse }
        let zak = URLComponents(url: startURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "zak" }?.value
        return .init(number: String(id), password: json["password"] as? String ?? "", startURL: startURL, zak: zak)
    }

    func createScheduledMeeting(_ spec: NewMeetingRequest) async throws -> ZoomServerToServerClient.CreatedScheduledMeeting {
        let body = try JSONSerialization.data(withJSONObject: spec.body())
        let json = try object(try ok(try await call("POST", "/users/me/meetings", body: body)))
        guard let id = json["id"] as? Int64, let joinURL = json["join_url"] as? String else { throw ZoomUserAuthError.badResponse }
        return .init(id: id, topic: json["topic"] as? String ?? spec.trimmedName, joinURL: joinURL,
                     password: json["password"] as? String ?? "")
    }

    func listMeetings() async throws -> (meetings: [ZoomServerToServerClient.ScheduledMeeting], warning: String?) {
        let json = try object(try ok(try await call("GET", "/users/me/meetings?type=scheduled&page_size=30")))
        guard let items = json["meetings"] as? [[String: Any]] else { throw ZoomUserAuthError.badResponse }
        let iso = ISO8601DateFormatter()
        var meetings = ZoomServerToServerClient.scheduledMeetings(from: items, iso: iso)
        var warning: String?
        for index in meetings.indices where meetings[index].isRecurring {
            do {
                let token = try await accessToken()
                meetings[index].startTime = try await ZoomServerToServerClient.nextOccurrence(
                    meetingID: meetings[index].id, token: token, iso: iso)
            } catch {
                warning = "Couldn\u{2019}t read the next time of your recurring meetings: \(error.localizedDescription)"
                break
            }
        }
        return (meetings, warning)
    }

    func meetingDetails(id: Int64) async throws -> [String: Any] {
        try object(try ok(try await call("GET", "/meetings/\(id)")))
    }

    func updateScheduledMeeting(id: Int64, _ spec: NewMeetingRequest) async throws {
        _ = try ok(try await call("PATCH", "/meetings/\(id)", body: try JSONSerialization.data(withJSONObject: spec.body())))
    }

    func deleteScheduledMeeting(id: Int64) async throws {
        _ = try ok(try await call("DELETE", "/meetings/\(id)"))
    }

    /// Best-effort, like the S2S one: a pre-flight tidy never blocks a start.
    func liveMeetings() async -> [Int64] {
        guard let data = try? ok(try await call("GET", "/users/me/meetings?type=live")),
              let json = try? object(data), let items = json["meetings"] as? [[String: Any]] else { return [] }
        return items.compactMap { $0["id"] as? Int64 }
    }

    func endMeeting(id: Int64) async -> (ok: Bool, status: Int, code: Int?, detail: String) {
        guard let body = try? JSONSerialization.data(withJSONObject: ["action": "end"]),
              let (data, status) = try? await call("PUT", "/meetings/\(id)/status", body: body)
        else { return (false, 0, nil, "no response") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let detail = [json?["code"].map { "code=\($0)" }, json?["message"] as? String].compactMap { $0 }.joined(separator: " ")
        return ((200...299).contains(status), status, json?["code"] as? Int, detail)
    }

    // MARK: Meeting SDK signature

    /// Asks the signature worker for the Meeting SDK JWT, proving who is asking
    /// with the person's Zoom access token. `meetingNumber` is omitted for SDK
    /// start-up and given when the worker should check the meeting is theirs.
    func sdkSignature(endpoint: String, meetingNumber: String? = nil, role: Int = 1) async throws -> String {
        guard let url = URL(string: endpoint), url.scheme == "https" else {
            throw ZoomUserAuthError.requestFailed("the signature address isn\u{2019}t a valid https address")
        }
        var payload: [String: Any] = ["role": role]
        if let meetingNumber { payload["meetingNumber"] = meetingNumber }
        func send(_ token: String) async throws -> (Data, Int) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        var result = try await send(try await accessToken())
        if result.1 == 401 {
            tokens = nil
            result = try await send(try await accessToken())
        }
        let json = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any]
        guard (200...299).contains(result.1), let signature = json?["signature"] as? String, !signature.isEmpty else {
            throw ZoomUserAuthError.requestFailed((json?["error"] as? String) ?? "the signature service answered \(result.1)")
        }
        return signature
    }
}
