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
//  (owner, 2026-11-26). Settings' choice, Home's readiness, the Start path
//  and the session log all read this, so none of them can disagree with what
//  Start does. Pure: Foundation only.
//
import Foundation

/// Why neither route can start a meeting.
enum ZoomRouteGap: Equatable {
    /// Your own Zoom apps are chosen and neither app is filled in.
    case ownAppsNotSetUp
    /// Your own Zoom apps are chosen and only one of the two apps is filled in.
    case ownAppsIncomplete
    /// Sign in with Zoom is chosen and nobody is signed in.
    case notSignedIn
    /// Signed in, but Greenroom has no signing service to use (never true in a release).
    case signInNotFinished
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
    /// The Settings switch: when both routes work, use the sign-in instead of your own Zoom apps.
    var prefersSignIn: Bool
}

enum ZoomRouteRules {
    /// The choice is the route (owner, 2026-11-26: "what is selected is what
    /// Start uses"). `prefersSignIn` is the page's choice; when the chosen way
    /// is not ready, Start says what it is missing and never quietly takes the
    /// other one. "Your own Zoom apps" works only with both halves, because
    /// Start needs REST to make the meeting and the SDK to run it.
    static func route(_ f: ZoomRouteFacts) -> ZoomRoute {
        if f.prefersSignIn {
            if greenroomAvailable(f) { return .greenroomApp(account: displayName(f)) }
            return .none(f.signedIn ? .signInNotFinished : .notSignedIn)
        }
        if ownAvailable(f) { return .ownApps(sdkClientID: f.sdkClientID.trimmingCharacters(in: .whitespaces)) }
        return .none(f.ownSDKComplete || f.ownS2SComplete ? .ownAppsIncomplete : .ownAppsNotSetUp)
    }

    /// Both routes work.
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
        case .none(.ownAppsNotSetUp):
            return "nothing yet: your own Zoom apps aren\u{2019}t set up"
        case .none(.notSignedIn):
            return "nothing yet: you are not signed in with Zoom"
        case .none(.signInNotFinished):
            return "nothing yet: Sign in with Zoom isn\u{2019}t finished setting up"
        case .none(.ownAppsIncomplete):
            return "nothing yet: your own Zoom apps need both the Meeting SDK and the Server-to-Server app"
        }
    }

    /// The Settings choice's tooltip, and the line under a Start failure.
    static func line(_ route: ZoomRoute) -> String {
        switch route {
        case .greenroomApp, .ownApps: return "Start uses: \(phrase(route))."
        case .none(.ownAppsNotSetUp): return "Start can\u{2019}t run yet: your own Zoom apps aren\u{2019}t set up."
        case .none(.notSignedIn): return "Start can\u{2019}t run yet: you are not signed in with Zoom."
        case .none(.signInNotFinished): return "Start can\u{2019}t run yet: Sign in with Zoom isn\u{2019}t finished setting up. Use your own Zoom apps for now."
        case .none(.ownAppsIncomplete): return "Start can\u{2019}t run yet: your own Zoom apps need both the Meeting SDK and the Server-to-Server app."
        }
    }

    /// Home's Zoom pill and the menu bar, when Start can't run.
    static func homeProblem(_ route: ZoomRoute) -> String? {
        switch route {
        case .greenroomApp, .ownApps: return nil
        case .none(.ownAppsNotSetUp), .none(.ownAppsIncomplete): return "Zoom: set up your apps"
        case .none(.notSignedIn): return "Zoom: sign in"
        case .none(.signInNotFinished): return "Zoom: sign-in not ready"
        }
    }

    /// The session log's line at Start.
    static func logLine(_ route: ZoomRoute) -> String { "Zoom route: \(phrase(route))." }

    /// The last four characters, enough to recognise a client ID without showing it.
    static func clientIDTail(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        return trimmed.count <= 4 ? trimmed : "\u{2026}" + trimmed.suffix(4)
    }

    /// A Start failure, followed by the route it used.
    static func failure(_ message: String, route: ZoomRoute) -> String {
        "\(message)\n\n\(line(route))"
    }
}

// MARK: - Error 63: Zoom refused the account

/// What the failure card's button does instead of Try again.
enum StartFailureFix: Equatable {
    /// Settings -> Zoom with "Your own Zoom apps" chosen.
    case openOwnZoomApps
    var title: String { "Open Settings" }
}

/// Error 63 (`ZoomSDKMeetingError_UnableToJoinExternalMeeting`) in plain words.
/// On Greenroom's Zoom app it means the meeting is on an account other than
/// the one that owns the app (proven 2026-11-26: meeting created on the
/// signed-in account, started with its own ZAK, refused at Connecting). Zoom
/// staff say a Meeting SDK app cannot start meetings for external users at
/// all (devforum 145559, 146160), so the advice is the route that works:
/// your own Zoom apps, which live on your own account. A refusal is
/// remembered per account so Home warns before the next Start, and cleared
/// by the next Start that works.
enum ZoomRefusalRules {
    static func startFailure(_ text: String, crossAccount: Bool, route: ZoomRoute) -> (message: String, fix: StartFailureFix?) {
        guard crossAccount else { return (ZoomRouteWords.failure(text, route: route), nil) }
        let why: String
        switch route {
        case .greenroomApp(let account):
            let who = account.isEmpty ? "Your account" : "Your account (\(account))"
            why = "Zoom refused to start this meeting on your account. "
                + "Greenroom\u{2019}s Zoom app can only start meetings on the Zoom account that made it, "
                + "and Zoom has not opened it to other accounts yet. \(who) is a different one. "
                + "To host from Greenroom now, use your own Zoom apps: Settings \u{2192} Zoom \u{2192} Your own Zoom apps."
        case .ownApps, .none:
            why = "Zoom refused to start this meeting. Your Meeting SDK app and your Server-to-Server app "
                + "need to be on the same Zoom account. Check both in Settings \u{2192} Zoom."
        }
        return (ZoomRouteWords.failure(why, route: route), .openOwnZoomApps)
    }

    /// The remembered refusals after a Start ended (refused or live).
    static func afterStart(_ refused: Set<String>, accountID: String, route: ZoomRoute,
                           crossAccountRefusal: Bool) -> Set<String> {
        guard route.usesGreenroomApp, !accountID.isEmpty else { return refused }
        var next = refused
        if crossAccountRefusal { next.insert(accountID) } else { next.remove(accountID) }
        return next
    }

    static func wasRefused(route: ZoomRoute, accountID: String, refused: Set<String>) -> Bool {
        route.usesGreenroomApp && !accountID.isEmpty && refused.contains(accountID)
    }

    /// Home's Zoom pill. A warning only: Start still runs, in case Zoom has opened the app since.
    static func homeWarning(route: ZoomRoute, accountID: String, refused: Set<String>) -> String? {
        wasRefused(route: route, accountID: accountID, refused: refused) ? "Zoom: this account can\u{2019}t host yet" : nil
    }

    /// Under the sign-in's status in Settings -> Zoom.
    static func settingsNote(route: ZoomRoute, accountID: String, refused: Set<String>) -> String? {
        wasRefused(route: route, accountID: accountID, refused: refused)
            ? "Zoom refused the last Start with this account. Greenroom\u{2019}s Zoom app can\u{2019}t start meetings on it yet, so choose Your own Zoom apps above."
            : nil
    }

    static func encode(_ refused: Set<String>) -> String { refused.sorted().joined(separator: ",") }
    static func decode(_ stored: String?) -> Set<String> {
        Set((stored ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }
}
