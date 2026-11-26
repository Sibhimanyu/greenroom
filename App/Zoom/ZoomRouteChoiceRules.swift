//
//  ZoomRouteChoiceRules.swift
//  Greenroom
//
//  Settings -> Zoom as one choice of two. The person picks "Your own Zoom
//  apps" or "Sign in with Zoom" at the top of the page, and the pick IS what
//  Start uses (`ZoomRouteRules.route` follows `prefersSignIn`). Only the
//  chosen option's section shows; this file decides what that section says:
//  its status line, its check, its one button, and what Start does when the
//  chosen way is not ready yet. Also the choice on first run, after an
//  update, and after signing in. Pure: Foundation only.
//
import Foundation

/// The two ways Greenroom connects to Zoom, in the order the page shows them.
enum ZoomRouteOption: String, CaseIterable, Equatable {
    case ownApps, signIn

    var title: String {
        switch self {
        case .ownApps: return "Your own Zoom apps"
        case .signIn: return "Sign in with Zoom"
        }
    }

    /// The one line under the choice: who the option is for.
    var note: String {
        switch self {
        case .ownApps: return "Works for any Zoom account"
        case .signIn: return "Only starts meetings on the account that owns Greenroom\u{2019}s Zoom app"
        }
    }
}

/// The check row under the status line (the shared `ZoomCheckButtonRow`).
enum ZoomRouteCheck: Equatable {
    /// The setup guide's check of both of your own Zoom apps.
    case setup
    /// What Start needs from the sign-in.
    case signIn

    var title: String {
        switch self {
        case .setup: return "Check Zoom setup"
        case .signIn: return "Check sign-in"
        }
    }
}

/// The button beside the status line.
enum ZoomRouteAction: Equatable { case signIn, cancelSignIn }

enum ZoomRouteTone: Equatable { case good, waiting, problem }

struct ZoomRouteChoiceFacts: Equatable {
    var route: ZoomRouteFacts
    /// Any Meeting SDK field filled in (complete or not).
    var ownSDKStarted: Bool
    /// Any Server-to-Server field filled in (complete or not).
    var ownS2SStarted: Bool
    /// The browser sign-in is under way.
    var signingIn: Bool
}

/// What the page shows for the chosen option.
struct ZoomRouteChoice: Equatable {
    var selected: ZoomRouteOption
    var status: String
    var tone: ZoomRouteTone
    var check: ZoomRouteCheck?
    var action: ZoomRouteAction?
    /// "Start uses: ..." (or why it can't): the choice's tooltip and accessibility value.
    var startLine: String
    /// The same line when Start can't run on the chosen way; nil when it can.
    var startBlocked: String?
    /// When the chosen way is not ready but the other one is.
    var otherHint: String?
    /// Sign in with Zoom shows as Coming soon and can't be picked.
    var signInComingSoon = false

    /// Whether the choice control lets this option be picked.
    func isSelectable(_ option: ZoomRouteOption) -> Bool { !(signInComingSoon && option == .signIn) }
    /// The small label beside the option's title ("Coming soon"), or nil.
    func badge(_ option: ZoomRouteOption) -> String? { isSelectable(option) ? nil : ZoomSignInAvailability.label }
    /// The option's tooltip in the choice control.
    func tip(_ option: ZoomRouteOption) -> String { isSelectable(option) ? option.note : ZoomSignInAvailability.tooltip }
}

enum ZoomRouteChoiceRules {
    static func choice(_ f: ZoomRouteChoiceFacts) -> ZoomRouteChoice {
        let r = f.route
        let route = ZoomRouteRules.route(r)
        let line = ZoomRouteWords.line(route)
        let blocked = route.isUsable ? nil : line
        let signInWorks = r.signedIn && r.endpointSet && !r.signInComingSoon
        let ownWorks = r.ownSDKComplete && r.ownS2SComplete
        if r.choosesSignIn {
            let account = [r.accountName, r.accountEmail]
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let status: String, tone: ZoomRouteTone, check: ZoomRouteCheck?, action: ZoomRouteAction?
            if r.signedIn && r.endpointSet {
                status = account.isEmpty ? "Signed in" : "Signed in as " + account.joined(separator: " \u{00B7} ")
                (tone, check, action) = (.good, .signIn, nil)
            } else if r.signedIn {
                let who = account.first.map { " as \($0)" } ?? ""
                status = "Signed in\(who), but Sign in with Zoom isn\u{2019}t finished setting up"
                (tone, check, action) = (.problem, .signIn, nil)
            } else if f.signingIn {
                status = "Waiting for Zoom in your browser\u{2026}"
                (tone, check, action) = (.waiting, nil, .cancelSignIn)
            } else {
                status = "Not signed in"
                (tone, check, action) = (.waiting, nil, .signIn)
            }
            let hint = !signInWorks && ownWorks
                ? "Your own Zoom apps are ready. Choose \(ZoomRouteOption.ownApps.title) to start with those instead." : nil
            return ZoomRouteChoice(selected: .signIn, status: status, tone: tone, check: check, action: action,
                                   startLine: line, startBlocked: blocked, otherHint: hint)
        }
        let status: String, tone: ZoomRouteTone
        if route == .none(.signInComingSoon) {
            (status, tone) = (ZoomRouteWords.setUpOwnApps, .problem)
        } else if ownWorks {
            (status, tone) = ("Ready", .good)
        } else if !f.ownSDKStarted && !f.ownS2SStarted && !r.ownSDKComplete && !r.ownS2SComplete {
            (status, tone) = ("Not set up yet", .waiting)
        } else {
            let needs = [r.ownSDKComplete ? nil : "Meeting SDK", r.ownS2SComplete ? nil : "Server-to-Server"].compactMap { $0 }
            (status, tone) = ("Needs the \(needs.joined(separator: " and ")) keys", .problem)
        }
        let started = f.ownSDKStarted || f.ownS2SStarted || r.ownSDKComplete || r.ownS2SComplete
        var hint = !ownWorks && signInWorks
            ? "You are signed in with Zoom. Choose \(ZoomRouteOption.signIn.title) to start with that instead." : nil
        // Their sign-in is kept, never signed out quietly: say so.
        if r.signInComingSoon && r.signedIn && !ownWorks {
            hint = "You are still signed in with Zoom. Greenroom keeps it for when \(ZoomRouteOption.signIn.title) opens."
        }
        return ZoomRouteChoice(selected: .ownApps, status: status, tone: tone, check: started ? .setup : nil, action: nil,
                               startLine: line, startBlocked: blocked, otherHint: hint,
                               signInComingSoon: r.signInComingSoon)
    }

    /// The choice when Greenroom launches. A saved choice carries over. With
    /// none (a fresh install, or the update that made the choice explicit):
    /// whichever way is set up, and your own Zoom apps when both or neither
    /// are (owner's decision A: they start meetings on any account).
    static func initialPrefersSignIn(saved: Bool?, signedIn: Bool, ownAppsComplete: Bool) -> Bool {
        if let saved { return saved }
        return signedIn && !ownAppsComplete
    }

    /// Signing in (Settings or the setup guide) is choosing the sign-in,
    /// unless your own Zoom apps already work: then the choice stays.
    static func prefersSignInAfterSigningIn(current: Bool, ownAppsComplete: Bool) -> Bool {
        current || !ownAppsComplete
    }
}
