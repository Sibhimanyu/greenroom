//
//  YouTubeAuth.swift
//  Greenroom
//
//  Google sign-in for the YouTube upload, done the way Google documents for
//  desktop apps: the system browser shows the consent page, Google redirects
//  to a loopback address this process is listening on for those few seconds,
//  and the one-time code is exchanged for tokens with PKCE. No embedded web
//  view, no password ever passes through Greenroom.
//
//  What is kept: the refresh token, in the same plain UserDefaults slot the
//  Zoom credentials use (SecretStore) - same honesty, same local-only risk.
//  It grants exactly one thing (youtube.upload: add videos to the channel)
//  and is revoked at Google when the teacher presses Disconnect.
//
import AppKit
import CryptoKit
import Foundation
import Network

enum YouTubeAuth {

    enum AuthError: LocalizedError {
        case noPort, timedOut, badRedirect(String), tokenExchange(String), notConnected, refreshFailed(String)

        var errorDescription: String? {
            switch self {
            case .noPort: return "Couldn't open a local port for Google to call back on."
            case .timedOut: return "Google did not call back within five minutes."
            case .badRedirect(let why): return "Google's callback was not what was expected: \(why)"
            case .tokenExchange(let why): return "Google refused the sign-in code: \(why)"
            case .notConnected: return "No Google account is connected. Settings \u{2192} YouTube \u{2192} Connect."
            case .refreshFailed(let why): return "Google would not renew the sign-in: \(why). Connect again in Settings \u{2192} YouTube."
            }
        }
    }

    /// The only thing asked for: adding videos. Not reading the channel, not
    /// managing anything.
    static let scope = "https://www.googleapis.com/auth/youtube.upload"
    private static let refreshTokenKey = "youtubeRefreshToken"

    static var isConnected: Bool { !(SecretStore.get(refreshTokenKey) ?? "").isEmpty }

    /// Short-lived access token, cached until a few minutes before expiry.
    private static var cachedAccess: (token: String, expiresAt: Date)?

    // MARK: Connect

    /// Opens the consent page and waits for Google's callback. Returns once
    /// a refresh token is stored. Runs for as long as the teacher takes to
    /// sign in, up to five minutes.
    @MainActor
    static func connect(clientID: String, clientSecret: String) async throws {
        let verifier = randomToken(bytes: 48)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomToken(bytes: 12)

        let listener = try LoopbackListener()
        defer { listener.stop() }
        let redirectURI = "http://127.0.0.1:\(listener.port)"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // offline + consent: the only combination that reliably returns a
            // refresh token on every connect, including re-connects.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        NSWorkspace.shared.open(components.url!)

        let code = try await listener.waitForCode(expectedState: state, timeout: 300)

        let form = [
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ]
        let json = try await postForm("https://oauth2.googleapis.com/token", form, failure: AuthError.tokenExchange)
        guard let refresh = json["refresh_token"] as? String, !refresh.isEmpty else {
            throw AuthError.tokenExchange("no refresh token in the response")
        }
        SecretStore.set(refresh, forKey: refreshTokenKey)
        cacheAccess(from: json)
    }

    /// Forgets the account here and tells Google to revoke the grant. The
    /// revoke is best-effort: the local token is gone either way.
    static func disconnect() async {
        if let refresh = SecretStore.get(refreshTokenKey), !refresh.isEmpty,
           let url = URL(string: "https://oauth2.googleapis.com/revoke?token=\(refresh)") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            _ = try? await URLSession.shared.data(for: request)
        }
        SecretStore.set("", forKey: refreshTokenKey)
        cachedAccess = nil
    }

    // MARK: Access tokens

    /// A valid access token, renewed with the refresh token when needed.
    static func accessToken(clientID: String, clientSecret: String) async throws -> String {
        if let cached = cachedAccess, cached.expiresAt.timeIntervalSinceNow > 300 {
            return cached.token
        }
        guard let refresh = SecretStore.get(refreshTokenKey), !refresh.isEmpty else {
            throw AuthError.notConnected
        }
        let form = [
            "refresh_token": refresh,
            "client_id": clientID,
            "client_secret": clientSecret,
            "grant_type": "refresh_token",
        ]
        let json = try await postForm("https://oauth2.googleapis.com/token", form, failure: AuthError.refreshFailed)
        guard let token = cacheAccess(from: json) else {
            throw AuthError.refreshFailed("no access token in the response")
        }
        return token
    }

    @discardableResult
    private static func cacheAccess(from json: [String: Any]) -> String? {
        guard let token = json["access_token"] as? String else { return nil }
        let seconds = (json["expires_in"] as? Double) ?? 3600
        cachedAccess = (token, Date().addingTimeInterval(seconds))
        return token
    }

    // MARK: HTTP

    private static func postForm(_ urlString: String,
                                 _ fields: [String: String],
                                 failure: (String) -> AuthError) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields
            .map { "\($0.key)=\(formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let why = (json["error_description"] as? String) ?? (json["error"] as? String) ?? "HTTP \(status)"
            throw failure(why)
        }
        return json
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func randomToken(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Loopback listener

/// Listens on 127.0.0.1 for the single HTTP request Google's redirect makes,
/// answers it with a "you can close this tab" page, and hands back the code.
/// Loopback only: nothing off this Mac can reach it, and it is gone the
/// moment the sign-in completes.
private final class LoopbackListener: @unchecked Sendable {
    let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "greenroom.youtube.loopback")
    private var continuation: CheckedContinuation<(code: String, state: String), Error>?
    private var connections: [NWConnection] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.start(queue: queue)

        // The port is assigned asynchronously; wait briefly for it.
        var assigned: UInt16?
        for _ in 0..<50 {
            if let p = listener.port?.rawValue, p != 0 { assigned = p; break }
            usleep(10_000)
        }
        guard let assigned else {
            listener.cancel()
            throw YouTubeAuth.AuthError.noPort
        }
        port = assigned
        // Set after every stored property exists (the closure captures self).
        // Nothing can connect before the consent URL is opened, so no
        // connection is missed by attaching the handler here.
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    }

    func waitForCode(expectedState: String, timeout: TimeInterval) async throws -> String {
        let result: (code: String, state: String) = try await withThrowingTaskGroup(of: (code: String, state: String).self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.queue.async { self.continuation = continuation }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw YouTubeAuth.AuthError.timedOut
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        guard result.state == expectedState else {
            throw YouTubeAuth.AuthError.badRedirect("state mismatch")
        }
        return result.code
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { return }
            self.handle(request: request, on: connection)
        }
    }

    private func handle(request: String, on connection: NWConnection) {
        // "GET /?state=...&code=... HTTP/1.1"
        let requestLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
        let path = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let components = URLComponents(string: "http://127.0.0.1\(path)")
        let items = components?.queryItems ?? []
        let code = items.first { $0.name == "code" }?.value
        let state = items.first { $0.name == "state" }?.value
        let error = items.first { $0.name == "error" }?.value

        let body: String
        if let code, let state {
            body = "<h2>Greenroom is connected to YouTube.</h2><p>You can close this tab and go back to Greenroom.</p>"
            continuation?.resume(returning: (code, state))
        } else {
            body = "<h2>Sign-in did not complete.</h2><p>\(error ?? "No code was returned.") Close this tab and try again from Greenroom.</p>"
            continuation?.resume(throwing: YouTubeAuth.AuthError.badRedirect(error ?? "no code"))
        }
        continuation = nil

        let html = "<!doctype html><meta charset=utf-8><title>Greenroom</title><body style=\"font-family:-apple-system,sans-serif;text-align:center;padding:60px\">\(body)</body>"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
