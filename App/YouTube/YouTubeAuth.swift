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
//  It grants managing the channel's own videos (youtube.force-ssl, see
//  `scope`) and is revoked at Google when the teacher presses Disconnect.
//
import AppKit
import CryptoKit
import Foundation
import Darwin

enum YouTubeAuth {

    enum AuthError: LocalizedError {
        case noPort(String), timedOut, badRedirect(String), tokenExchange(String), notConnected, refreshFailed(String), signInExpired

        var errorDescription: String? {
            switch self {
            case .noPort(let why): return "Couldn't open a local port for Google to call back on (\(why))."
            case .timedOut: return "Google did not call back within five minutes."
            case .badRedirect(let why): return "Google's callback was not what was expected: \(why)"
            case .tokenExchange(let why): return "Google refused the sign-in code: \(why). Check that the Client Secret belongs to this Client ID (Google Cloud \u{2192} Credentials \u{2192} the Desktop app client) and re-copy both."
            case .notConnected: return "No Google account is connected. Settings \u{2192} YouTube \u{2192} Connect."
            case .refreshFailed(let why): return "Google would not renew the sign-in: \(why). Connect again in Settings \u{2192} YouTube."
            case .signInExpired: return "Your Google sign-in has expired. Connect again in Settings \u{2192} YouTube. (Google ends sign-ins after 7 days while the Google Cloud project is in Testing; publish it to stop this.)"
            }
        }
    }

    /// Upload and edit the account's own videos. `youtube.upload` alone
    /// cannot change a title afterwards, and there is no Google scope between
    /// "add only" and "manage videos" - so this is the narrowest that lets a
    /// class be renamed on YouTube after the fact. Greenroom uses it for
    /// uploads, title changes, deleting a video the teacher chose to delete,
    /// and Cues video search when that is on - nothing else.
    static let scope = "https://www.googleapis.com/auth/youtube.force-ssl"

    /// Tokens granted before the scope widened can upload but not rename.
    /// Google answers 403 insufficientPermissions; this is the message.
    static let reconnectHint = "Google needs a new permission for that \u{2014} in Settings \u{2192} YouTube, Disconnect and then Connect again."
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

        let listener = try LoopbackListener.start()
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

        // The browser tab is answered only once the exchange has actually
        // succeeded, so it never says "connected" over a failure.
        let form = [
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ]
        do {
            let json = try await postForm("https://oauth2.googleapis.com/token", form, failure: AuthError.tokenExchange)
            guard let refresh = json["refresh_token"] as? String, !refresh.isEmpty else {
                throw AuthError.tokenExchange("no refresh token in the response")
            }
            SecretStore.set(refresh, forKey: refreshTokenKey)
            cacheAccess(from: json)
            listener.reply(success: true, detail: "")
        } catch {
            listener.reply(success: false, detail: error.localizedDescription)
            throw error
        }
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
        let json: [String: Any]
        do {
            json = try await postForm("https://oauth2.googleapis.com/token", form,
                                      failure: AuthError.refreshFailed, invalidGrant: .signInExpired)
        } catch AuthError.signInExpired {
            // invalid_grant means this refresh token is dead (expired or
            // revoked). Forget it so the app stops believing it is connected;
            // no revoke call, Google has already ended it.
            SecretStore.set("", forKey: refreshTokenKey)
            cachedAccess = nil
            throw AuthError.signInExpired
        }
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
                                 failure: (String) -> AuthError,
                                 invalidGrant: AuthError? = nil) async throws -> [String: Any] {
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
            if let invalidGrant, (json["error"] as? String) == "invalid_grant" { throw invalidGrant }
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

/// Receives the single HTTP request Google makes to the redirect URI, on a
/// plain BSD socket bound to 127.0.0.1 with a kernel-chosen port. Answers
/// with a "you can close this tab" page and hands back the code. Loopback
/// only: nothing off this Mac can reach it, and it is closed the moment the
/// sign-in completes. A raw socket rather than Network.framework, whose
/// NWListener rejects loopback-only binds (EINVAL, seen live).
private final class LoopbackListener: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    /// The browser connection carrying Google's redirect, held open until
    /// connect() knows whether the exchange worked - the page it shows is
    /// then true.
    private var pendingClient: Int32 = -1

    private init(fd: Int32, port: UInt16) {
        self.fd = fd
        self.port = port
    }

    /// Answers the waiting browser tab and closes it.
    func reply(success: Bool, detail: String) {
        guard pendingClient >= 0 else { return }
        let body = YouTubeCallbackPage.html(success: success, detail: detail)
        Self.respond(pendingClient, status: "200 OK", html: body)
        pendingClient = -1
    }

    static func start() throws -> LoopbackListener {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw YouTubeAuth.AuthError.noPort(String(cString: strerror(errno))) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0 // the kernel picks a free port
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            let why = String(cString: strerror(errno))
            close(fd)
            throw YouTubeAuth.AuthError.noPort(why)
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else {
            close(fd)
            throw YouTubeAuth.AuthError.noPort("could not read the assigned port")
        }
        return LoopbackListener(fd: fd, port: UInt16(bigEndian: assigned.sin_port))
    }

    /// Accepts connections until one carries Google's redirect (a code, or
    /// an error), answering anything else - a favicon probe, a speculative
    /// second connection - with a 404. Times out after `timeout` seconds.
    func waitForCode(expectedState: String, timeout: TimeInterval) async throws -> String {
        let result: (code: String, state: String) = try await withThrowingTaskGroup(of: (code: String, state: String).self) { group in
            group.addTask { try await self.acceptRedirect() }
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
        // A tab still waiting (timeout, cancellation) gets an answer rather
        // than a spinner, then the listening socket closes, which makes a
        // blocked accept() return -1 and ends the accept loop.
        reply(success: false, detail: "Greenroom stopped waiting.")
        close(fd)
    }

    private func acceptRedirect() async throws -> (code: String, state: String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                while true {
                    let client = accept(self.fd, nil, nil)
                    guard client >= 0 else {
                        continuation.resume(throwing: YouTubeAuth.AuthError.badRedirect("the callback listener closed"))
                        return
                    }
                    var buffer = [UInt8](repeating: 0, count: 16_384)
                    let count = read(client, &buffer, buffer.count)
                    let request = count > 0 ? String(decoding: buffer[0..<count], as: UTF8.self) : ""

                    // "GET /?state=...&code=... HTTP/1.1"
                    let requestLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
                    let path = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    let items = URLComponents(string: "http://127.0.0.1\(path)")?.queryItems ?? []
                    let code = items.first { $0.name == "code" }?.value
                    let state = items.first { $0.name == "state" }?.value
                    let error = items.first { $0.name == "error" }?.value

                    if let code, let state {
                        // Answered later by reply(), once the exchange is known.
                        self.pendingClient = client
                        continuation.resume(returning: (code, state))
                        return
                    }
                    if let error {
                        Self.respond(client, status: "200 OK",
                                     html: YouTubeCallbackPage.html(success: false, detail: error))
                        continuation.resume(throwing: YouTubeAuth.AuthError.badRedirect(error))
                        return
                    }
                    // Not the redirect (favicon, a probe): answer and keep waiting.
                    Self.respond(client, status: "404 Not Found", html: "")
                }
            }
        }
    }

    /// `html` is the finished document; Content-Length is its UTF-8 byte count.
    private static func respond(_ client: Int32, status: String, html: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        _ = response.withCString { write(client, $0, strlen($0)) }
        close(client)
    }
}

// MARK: - Callback page

// CALLBACK-PAGE-BEGIN (scripts and previews extract this block; keep it self-contained)
/// The page the browser tab shows after Google redirects back. Everything is
/// inline (no network is assumed): CSS, the mark as SVG, the system font
/// stack. Colours are the site's tokens (DESIGN.md): green text is
/// --brand-green, lime is a fill only. There is no custom URL scheme, so no
/// "Back to Greenroom" button, and no script: window.close() does not work on
/// a tab the page did not open.
enum YouTubeCallbackPage {
    /// Escapes text for HTML body and attribute use. `detail` can carry the
    /// redirect's query string, which anyone can write.
    static func escape(_ text: String) -> String {
        var out = ""
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    static func html(success: Bool, detail: String) -> String {
        let heading = success ? "Connected to YouTube" : "Sign-in didn\u{2019}t finish"
        let icon = success
            ? #"<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><path d="M6 12.5l4 4 8-9" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/></svg>"#
            : #"<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><path d="M12 6.5v7M12 17.4v.1" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round"/></svg>"#
        let lines: String
        if success {
            lines = "<p>Recordings can now go to your channel. You can close this tab.</p>"
        } else {
            let why = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            lines = (why.isEmpty ? "" : "<p>\(escape(why))</p>")
                + "<p>Close this tab and try again from Greenroom \u{2192} Settings \u{2192} YouTube.</p>"
        }
        return #"""
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <title>Greenroom \#u{00B7} YouTube</title>
        <style>
        :root{--ink:#101828;--body:#475467;--line:#EAECF0;--bg:#F9FAFB;--card:#FFFFFF;--brand-deep:#00401C;--brand-green:#2F6118;--accent-lime:#78C000;--mark:#00401C;--badge-bg:#2F6118;--badge-fg:#FFFFFF;--shadow:0 1px 2px rgba(16,24,40,.06),0 12px 32px rgba(16,24,40,.06)}
        @media (prefers-color-scheme:dark){:root{--ink:#F2F4F7;--body:#B6BDC9;--line:#2A3342;--bg:#0C111B;--card:#141B27;--mark:#FFFFFF;--badge-bg:#78C000;--badge-fg:#00401C;--shadow:none}}
        *{box-sizing:border-box}
        html,body{margin:0;min-height:100%}
        body{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px;background:var(--bg);color:var(--body);font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Roboto,Helvetica,Arial,sans-serif;-webkit-font-smoothing:antialiased}
        main{width:100%;max-width:420px;text-align:center;background:var(--card);border:1px solid var(--line);border-radius:14px;box-shadow:var(--shadow);padding:40px 32px 36px}
        .mark{display:block;width:34px;height:auto;margin:0 auto 22px}
        .mark .body{fill:var(--mark)}
        .mark .head{fill:var(--accent-lime)}
        .badge{display:inline-flex;align-items:center;justify-content:center;width:40px;height:40px;border-radius:999px;background:var(--badge-bg);color:var(--badge-fg);margin-bottom:16px}
        .badge.fail{background:var(--line);color:var(--ink)}
        h1{margin:0 0 10px;font-size:22px;line-height:1.25;font-weight:700;letter-spacing:-.01em;color:var(--ink)}
        p{margin:0 0 8px;font-size:15px;line-height:1.5}
        p:last-child{margin-bottom:0}
        </style>
        </head>
        <body>
        <main>
        <svg class="mark" viewBox="0 0 965 1000" role="img" aria-label="Greenroom"><path class="body" d="M0,240C0,107.452 107.452,0 240,0L585,0C623.66,0 655,31.34 655,70L655,165C655,203.66 623.66,235 585,235L275,235C252.909,235 235,252.909 235,275L235,725C235,747.091 252.909,765 275,765L690,765C712.091,765 730,747.091 730,725L730,598.419C730,585.614 718.134,576.107 705.637,578.901L552.27,613.182C514.541,621.616 477.119,597.867 468.686,560.138C460.252,522.409 484.001,484.987 521.73,476.554L726.768,430.722C728.916,430.242 731.111,430 733.312,430L910,430C940.376,430 965,454.624 965,485L965,860C965,937.32 902.32,1000 825,1000L240,1000C107.452,1000 0,892.548 0,760Z"/><path class="head" d="M730,230C730,188.579 763.579,155 805,155L890,155C931.421,155 965,188.579 965,230L965,315C965,356.421 931.421,390 890,390L805,390C763.579,390 730,356.421 730,315Z"/></svg>
        <div class="badge\#(success ? "" : " fail")">\#(icon)</div>
        <h1>\#(heading)</h1>
        \#(lines)
        </main>
        </body>
        </html>
        """#
    }
}
// CALLBACK-PAGE-END
