//
//  ZoomRouteRules.swift
//  Greenroom
//
//  Which Zoom Start uses, as ONE rule. There are two routes, and Start takes
//  both of its halves (the meeting and host key over REST, and the Meeting
//  SDK's JWT) from the same one:
//
//  - Greenroom's Zoom app: signed in with Zoom. REST as the person
//    (`ZoomUserAuth`), the JWT from the signing function (Catalyst).
//  - Your own Zoom apps: the pasted Server-to-Server app for REST and the
//    pasted Meeting SDK key and secret for the JWT.
//
//  Before this file the two halves were picked separately (sign-in won each
//  one), so a person with both set up could not tell which they were using
//  (owner, 2026-11-26). Settings' top line, Home's readiness, the Start path
//  and the session log all read this, so none of them can disagree with what
//  Start does. Pure: Foundation only.
//
import Foundation

/// Why neither route can start a meeting.
enum ZoomRouteGap: Equatable {
    /// Nothing set up.
    case notSetUp
    /// Signed in, but Greenroom has no signing service to use (never true in a release).
    case signInNotFinished
    /// Not signed in and only half of "your own Zoom apps" is filled in.
    case ownAppsIncomplete
}

enum ZoomRoute: Equatable {
    /// The person's own Zoom account, through Greenroom's Zoom app.
    case greenroomApp(account: String)
    /// The person's own Meeting SDK and Server-to-Server apps.
    case ownApps(sdkClientID: String)
    case none(ZoomRouteGap)

    var usesGreenroomApp: Bool { if case .greenroomApp = self { return true } else { return false } }
    var isUsable: Bool { if case .none = self { return false } else { return true } }
}

/// Plain facts the coordinator reads off its stored values.
struct ZoomRouteFacts: Equatable {
    var signedIn: Bool
    var accountName: String
    var accountEmail: String
    /// The signing function's address is set (a constant in releases).
    var endpointSet: Bool
    /// Meeting SDK key and secret both pasted.
    var ownSDKComplete: Bool
    /// Server-to-Server account ID, client ID and secret all pasted.
    var ownS2SComplete: Bool
    var sdkClientID: String
    /// The Settings switch: when both routes work, use your own Zoom apps.
    var prefersOwnApps: Bool
}

enum ZoomRouteRules {
    /// The precedence, in order: when both routes work, the switch picks
    /// (signed in wins unless it is on); otherwise whichever works; otherwise
    /// the reason neither does. "Your own Zoom apps" works only with both
    /// halves, because Start needs REST to make the meeting and the SDK to run it.
    static func route(_ f: ZoomRouteFacts) -> ZoomRoute {
        let greenroom = greenroomAvailable(f)
        let own = ownAvailable(f)
        let account = displayName(f)
        let clientID = f.sdkClientID.trimmingCharacters(in: .whitespaces)
        if greenroom && own {
            return f.prefersOwnApps ? .ownApps(sdkClientID: clientID) : .greenroomApp(account: account)
        }
        if greenroom { return .greenroomApp(account: account) }
        if own { return .ownApps(sdkClientID: clientID) }
        if f.signedIn { return .none(.signInNotFinished) }
        if f.ownSDKComplete || f.ownS2SComplete { return .none(.ownAppsIncomplete) }
        return .none(.notSetUp)
    }

    /// Both routes work, so Settings says which wins and offers the switch.
    static func bothSetUp(_ f: ZoomRouteFacts) -> Bool { greenroomAvailable(f) && ownAvailable(f) }

    /// Who answers REST (create, list, host key) on this route.
    static func restSource(_ route: ZoomRoute) -> ZoomCredentialRules.RESTSource {
        switch route {
        case .greenroomApp: return .signedIn
        case .ownApps: return .ownApps
        case .none: return .none
        }
    }

    /// Who signs the Meeting SDK's JWT on this route.
    static func sdkAuth(_ route: ZoomRoute) -> ZoomCredentialRules.SDKAuth {
        switch route {
        case .greenroomApp: return .worker
        case .ownApps: return .ownKeys
        case .none(.signInNotFinished): return .notFinished
        case .none: return .missingKeys
        }
    }

    private static func greenroomAvailable(_ f: ZoomRouteFacts) -> Bool { f.signedIn && f.endpointSet }
    private static func ownAvailable(_ f: ZoomRouteFacts) -> Bool { f.ownSDKComplete && f.ownS2SComplete }

    private static func displayName(_ f: ZoomRouteFacts) -> String {
        let name = f.accountName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? f.accountEmail.trimmingCharacters(in: .whitespaces) : name
    }
}

/// The words for the route. One phrase, used by Settings, the log and failures.
enum ZoomRouteWords {
    /// "your Zoom account (Name), through Greenroom's Zoom app" and the like.
    static func phrase(_ route: ZoomRoute) -> String {
        switch route {
        case .greenroomApp(let account):
            let who = account.isEmpty ? "" : " (\(account))"
            return "your Zoom account\(who), through Greenroom\u{2019}s Zoom app"
        case .ownApps(let id):
            return "your own Zoom apps (client ID \(clientIDTail(id)))"
        case .none(.notSetUp):
            return "nothing yet: sign in with Zoom, or set up your own Zoom apps"
        case .none(.signInNotFinished):
            return "nothing yet: Sign in with Zoom isn\u{2019}t finished setting up"
        case .none(.ownAppsIncomplete):
            return "nothing yet: your own Zoom apps need both the Meeting SDK and the Server-to-Server app"
        }
    }

    /// Settings' top line, and the line under a Start failure.
    static func line(_ route: ZoomRoute) -> String {
        switch route {
        case .greenroomApp, .ownApps: return "Start uses: \(phrase(route))."
        case .none(.notSetUp): return "Start can\u{2019}t run yet: sign in with Zoom, or set up your own Zoom apps."
        case .none(.signInNotFinished): return "Start can\u{2019}t run yet: Sign in with Zoom isn\u{2019}t finished setting up. Use your own Zoom apps for now."
        case .none(.ownAppsIncomplete): return "Start can\u{2019}t run yet: your own Zoom apps need both the Meeting SDK and the Server-to-Server app."
        }
    }

    /// The session log's line at Start.
    static func logLine(_ route: ZoomRoute) -> String { "Zoom route: \(phrase(route))." }

    /// The last four characters, enough to recognise a client ID without showing it.
    static func clientIDTail(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        return trimmed.count <= 4 ? trimmed : "\u{2026}" + trimmed.suffix(4)
    }

    /// Under the top line when both routes work: which one wins.
    static func bothNote(_ route: ZoomRoute) -> String? {
        switch route {
        case .greenroomApp: return "Your own Zoom apps are set up too. Start uses your Zoom account while you are signed in."
        case .ownApps: return "You are signed in with Zoom too. Start uses your own Zoom apps."
        case .none: return nil
        }
    }

    /// The one-click switch to the other route.
    static func switchTitle(_ route: ZoomRoute) -> String? {
        switch route {
        case .greenroomApp: return "Use my own Zoom apps"
        case .ownApps: return "Use my Zoom account"
        case .none: return nil
        }
    }

    /// A Start failure, followed by the route it used.
    static func failure(_ message: String, route: ZoomRoute) -> String {
        "\(message)\n\n\(line(route))"
    }
}
