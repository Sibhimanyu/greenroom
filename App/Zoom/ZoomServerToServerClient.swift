//
//  ZoomServerToServerClient.swift
//  Greenroom
//
//  Creates a real Zoom meeting via the plain REST API - a Server-to-Server
//  OAuth app (Account ID + Client ID + Client Secret), a SEPARATE
//  Marketplace app from the Meeting SDK one used elsewhere in App/Zoom/.
//
//  Yes, that means two Marketplace apps. A consolidation onto one app via
//  browser-consent OAuth + PKCE was fully built and then deliberately
//  abandoned (Aug 2026): Zoom only allows loopback redirect URLs for
//  PKCE public-client apps, and even with that configured the portal's
//  redirect/allow-list validation kept rejecting the flow. S2S's headless
//  `account_credentials` grant has none of those moving parts - two HTTP
//  calls, no browser, no redirect registration:
//    1. https://zoom.us/oauth/token (account_credentials grant) -> access token
//    2. POST /v2/users/me/meetings -> a new instant meeting
//  The response's `start_url` is what actually matters for "start a
//  meeting from my app" - opening it launches the native Zoom app and
//  begins hosting immediately, the same as clicking Zoom's own
//  "New Meeting" button.
//
import Foundation

enum ZoomServerToServerClient {

    struct CreatedMeeting {
        let number: String
        let password: String
        let startURL: URL
        /// Host key pulled out of `startURL`'s query - lets the meeting be
        /// started via Zoom's native zoommtg:// scheme instead of routing
        /// the https start_url through the default browser (which stalls
        /// on an "Open Zoom.app?" click that the session flow's Chrome
        /// window then buries - confirmed by a real stuck session).
        let zak: String?
    }

    private static func fetchAccessToken(accountID: String, clientID: String, clientSecret: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://zoom.us/oauth/token")!)
        request.httpMethod = "POST"
        let credentials = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=account_credentials&account_id=\(accountID)".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ZoomServerToServerError.tokenRequestFailed(String(data: data, encoding: .utf8) ?? "unknown error")
        }
        struct TokenResponse: Decodable { let access_token: String }
        return try JSONDecoder().decode(TokenResponse.self, from: data).access_token
    }

    /// Creates an instant meeting (`type: 1`) under the authorized
    /// account. Needs a meeting-write scope (granular name
    /// `meeting:write:meeting:admin` or similar - pick whatever
    /// create-a-meeting scope the S2S app's scope screen offers) enabled
    /// on the Server-to-Server app.
    static func startInstantMeeting(
        topic: String,
        accountID: String,
        clientID: String,
        clientSecret: String
    ) async throws -> CreatedMeeting {
        let token = try await fetchAccessToken(accountID: accountID, clientID: clientID, clientSecret: clientSecret)

        var request = URLRequest(url: URL(string: "https://api.zoom.us/v2/users/me/meetings")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["topic": topic, "type": 1])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ZoomServerToServerError.createMeetingFailed(String(data: data, encoding: .utf8) ?? "unknown error")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? Int64,
              let startURLString = json["start_url"] as? String,
              let startURL = URL(string: startURLString) else {
            throw ZoomServerToServerError.unexpectedResponse
        }
        let password = json["password"] as? String ?? ""
        let zak = URLComponents(url: startURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "zak" }?.value
        return CreatedMeeting(number: String(id), password: password, startURL: startURL, zak: zak)
    }

    /// One meeting from the account's scheduled list. The list endpoint
    /// deliberately omits the passcode, but `joinURL` carries it in
    /// encrypted `pwd=` form - which is exactly what joins accept, and
    /// what ZoomMeetingLinkParser already extracts.
    struct ScheduledMeeting: Identifiable, Hashable {
        let id: Int64
        let topic: String
        /// nil for "recurring, no fixed time" meetings - the standing-
        /// meeting kind, startable any time.
        let startTime: Date?
        let isRecurring: Bool
        let joinURL: String
    }

    /// Lists the account's scheduled meetings (GET /users/me/meetings,
    /// `type=scheduled` - upcoming ones plus recurring meetings with no
    /// fixed time). Needs a meeting READ scope on the Server-to-Server
    /// app, additional to the write scope creating uses - if Zoom answers
    /// with a "does not contain scopes" error, add the list-meetings read
    /// scope on the app's Scopes page.
    static func listScheduledMeetings(
        accountID: String,
        clientID: String,
        clientSecret: String
    ) async throws -> [ScheduledMeeting] {
        let token = try await fetchAccessToken(accountID: accountID, clientID: clientID, clientSecret: clientSecret)

        var request = URLRequest(url: URL(string: "https://api.zoom.us/v2/users/me/meetings?type=scheduled&page_size=30")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ZoomServerToServerError.listMeetingsFailed(String(data: data, encoding: .utf8) ?? "unknown error")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["meetings"] as? [[String: Any]] else {
            throw ZoomServerToServerError.unexpectedResponse
        }

        let iso = ISO8601DateFormatter()
        return items.compactMap { item in
            guard let id = item["id"] as? Int64,
                  let joinURL = item["join_url"] as? String else { return nil }
            // Zoom meeting types: 2 scheduled, 3 recurring/no fixed time,
            // 8 recurring/fixed time.
            let type = (item["type"] as? Int) ?? 2
            return ScheduledMeeting(
                id: id,
                topic: (item["topic"] as? String) ?? "Untitled meeting",
                startTime: (item["start_time"] as? String).flatMap { iso.date(from: $0) },
                isRecurring: type == 3 || type == 8,
                joinURL: joinURL
            )
        }
    }
}

enum ZoomServerToServerError: LocalizedError {
    case tokenRequestFailed(String)
    case createMeetingFailed(String)
    case listMeetingsFailed(String)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .tokenRequestFailed(let body): return "Couldn't get a Zoom API token: \(body)"
        case .createMeetingFailed(let body): return "Couldn't create the meeting: \(body)"
        case .listMeetingsFailed(let body):
            var message = "Couldn't list your Zoom meetings: \(body)"
            if body.contains("scopes") {
                message += " \u{2014} add a meeting READ scope (search \u{201C}meeting\u{201D}, pick the list/view one) on your Server-to-Server app's Scopes page at marketplace.zoom.us."
            }
            return message
        case .unexpectedResponse: return "Zoom's response didn't look like a meeting list."
        }
    }
}
