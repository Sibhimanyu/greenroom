//
//  YouTubeRouteRules.swift
//  Greenroom
//
//  Which Google app (OAuth client) YouTube sign-in goes through, as ONE rule,
//  like ZoomRouteRules:
//
//  - Greenroom's Google app (`.shared`): the default. Nothing to paste; any
//    Google account. `YouTubeOAuth.sharedClient`.
//  - Your own Google app (`.own`): a Desktop client the person made in Google
//    Cloud and pasted into Settings -> YouTube -> Use your own Google app. For
//    people past the shared app's 100-user cap, or who want their own quota.
//
//  The choice is the route: when the chosen way is not ready, sign-in says
//  what is missing and never quietly takes the other. A refresh token only
//  works with the app that issued it, so refreshing reads `tokenApp`, not
//  the current choice. Pure: Foundation only.
//
import Foundation

/// Which Google app issued (or will issue) the sign-in.
enum YouTubeGoogleApp: String, Equatable {
    case shared, own
}

enum YouTubeRouteGap: Equatable {
    /// The shared client is still the placeholder (the owner has not pasted it yet).
    case sharedNotAvailableYet
    /// Your own Google app is chosen and nothing is pasted.
    case ownAppNotSetUp
    /// Your own Google app is chosen and only one of ID and secret is pasted.
    case ownAppIncomplete

    var message: String {
        switch self {
        case .sharedNotAvailableYet:
            return "Sign in with Google isn\u{2019}t available in this version yet. Use your own Google app, or Upload in YouTube Studio."
        case .ownAppNotSetUp:
            return "Paste your Google app\u{2019}s Client ID and Client Secret first."
        case .ownAppIncomplete:
            return "Paste both the Client ID and the Client Secret."
        }
    }
}

enum YouTubeRoute: Equatable {
    case shared, own
    case none(YouTubeRouteGap)

    /// Why sign-in can't run, in words; nil when it can.
    var noneMessage: String? {
        if case .none(let gap) = self { return gap.message }
        return nil
    }

    var app: YouTubeGoogleApp? {
        switch self {
        case .shared: return .shared
        case .own: return .own
        case .none: return nil
        }
    }
}

struct YouTubeRouteFacts: Equatable {
    /// Settings -> YouTube -> Use your own Google app -> the switch.
    var prefersOwnApp: Bool
    var sharedClientID: String
    var ownClientID: String
    var ownClientSecret: String
}

enum YouTubeRouteRules {
    /// What Sign in with Google uses right now.
    static func signInRoute(_ f: YouTubeRouteFacts) -> YouTubeRoute {
        if f.prefersOwnApp {
            let id = !f.ownClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let secret = !f.ownClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if id && secret { return .own }
            return .none(id || secret ? .ownAppIncomplete : .ownAppNotSetUp)
        }
        return sharedAvailable(clientID: f.sharedClientID) ? .shared : .none(.sharedNotAvailableYet)
    }

    /// The shipped client is real (not the placeholder, not empty).
    static func sharedAvailable(clientID: String) -> Bool {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        return !id.isEmpty && !id.hasPrefix("PLACEHOLDER")
    }

    /// The app to refresh a stored token with. Tokens saved before the shared
    /// app existed carry no record, and could only have come from your own.
    static func tokenApp(issuedBy: YouTubeGoogleApp?) -> YouTubeGoogleApp {
        issuedBy ?? .own
    }

    /// The choice at launch. A saved choice wins; otherwise people who had
    /// pasted their own app (everyone, before 2026-11-26) keep it, and
    /// everyone else starts on Sign in with Google.
    static func initialPrefersOwnApp(saved: Bool?, ownClientComplete: Bool) -> Bool {
        saved ?? ownClientComplete
    }
}
