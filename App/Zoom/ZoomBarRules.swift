//
//  ZoomBarRules.swift
//  Greenroom
//
//  The Greenroom bar at the top of the Zoom window (spec R13): which part and
//  step the page is, the contextual button (Copy scopes, "set up" with a
//  check, Sign in) and the primary button (Next: <other part>, Back to
//  Greenroom). Facts come from the same page/step rules the guide and the coach
//  use. Pure: Foundation only.
//
import Foundation

struct ZoomBarFacts: Equatable {
    /// The part being worked on when the page is not an app page of either kind.
    var part: ZoomGuidePart
    var page: ZoomMarketplacePage?
    var ids: ZoomAppIDs
    /// All of the part's keys are in Greenroom.
    var meetingComplete: Bool
    var hostingComplete: Bool
    var signIn: ZoomSignInState = .unknown
    /// On Created apps: a row of the part's app type is in the table.
    var hasMatchingRow = false
    /// A "Do this step" run is under way.
    var working = false
}

enum ZoomBarContext: Equatable {
    case none
    case copyScopes
    /// "Hosting app is set up", with a green check.
    case setUp(String)
    case signIn
    /// On a passkey page: Safari is the way through, right there in the bar.
    case openInSafari
    /// A "Do this step" run is under way.
    case working

    var title: String {
        switch self {
        case .none: return ""
        case .copyScopes: return "Copy scopes"
        case .setUp(let text): return text
        case .signIn: return "Sign in"
        case .openInSafari: return "Open in Safari"
        case .working: return ZoomActorRules.busyTitle
        }
    }
}

enum ZoomBarPrimary: Equatable {
    case none
    case next(ZoomGuidePart, ZoomMarketplacePage)
    case backToGreenroom

    var title: String {
        switch self {
        case .none: return ""
        case .next: return "Continue"
        case .backToGreenroom: return "Back to Greenroom"
        }
    }
}

struct ZoomBar: Equatable {
    var title: String
    var context: ZoomBarContext
    var primary: ZoomBarPrimary
    var offersSignOut: Bool
}

enum ZoomBarRules {
    private static let dot = " \u{00B7} "
    static func bar(_ f: ZoomBarFacts) -> ZoomBar {
        let onSignInPage = f.page?.isSignIn == true
        let offersSignOut = ZoomSignInStateRules.offersSignOut(f.signIn) && !onSignInPage
        let part: ZoomGuidePart = f.page?.app.map { $0 == .sdk ? .meetingApp : .hostingApp } ?? f.part
        let isSignedOut = onSignInPage || f.signIn == .signedOut

        // Title: one counter across both apps ("Step 5 of 7 \u{00B7} Add the permissions").
        let title: String
        let appWord = part == .meetingApp ? "meeting" : "hosting"
        if isSignedOut {
            title = "Sign in to Zoom"
        } else if let page = f.page, page != .createdApps, let step = ZoomGuideFollowRules.step(part: part, page: page) {
            var t = ZoomRun.counter(step) + dot + ZoomRun.name(step)
            // The two "Copy its keys" steps say which app they are for; every other name already does.
            if step == 3 || step == 7 { t += dot + part.title }
            title = t
        } else if let page = f.page, page.app != nil {
            title = part.title + dot + "Set up the app"
        } else if let first = ZoomRun.firstStep(of: part), f.page == .createdApps {
            title = ZoomRun.counter(first) + dot + (f.hasMatchingRow ? "Find the \(appWord) app" : ZoomRun.name(first))
        } else if let first = ZoomRun.firstStep(of: part) {
            title = ZoomRun.counter(first) + dot + "Find or create the \(appWord) app"
        } else {
            title = part.title
        }

        // Contextual button.
        let partComplete = part == .meetingApp ? f.meetingComplete : f.hostingComplete
        let onCredentials = f.page.map { ZoomMarketplacePages.keyFields(on: $0) != nil } ?? false
        let context: ZoomBarContext
        if f.working && !onSignInPage { context = .working }
        else if f.page == .passkey { context = .openInSafari }
        else if onSignInPage { context = .none }
        else if f.signIn == .signedOut { context = .signIn }
        else if f.page == .s2s(f.page?.appID ?? "", .scopes), part == .hostingApp { context = .copyScopes }
        else if onCredentials && partComplete { context = .setUp("\(part.title) is set up") }
        else { context = .none }

        // Primary button.
        let primary: ZoomBarPrimary
        if onSignInPage { primary = .none }
        else if f.meetingComplete && f.hostingComplete { primary = .backToGreenroom }
        else if onCredentials && partComplete {
            let other: ZoomGuidePart = part == .meetingApp ? .hostingApp : .meetingApp
            primary = .next(other, nextPage(other, f.ids))
        } else { primary = .none }

        return ZoomBar(title: title, context: context, primary: primary, offersSignOut: offersSignOut)
    }

    /// Where "Continue" takes the window: step 4 (Created apps, for the hosting app); the Meeting app's keys page when its ID is known.
    private static func nextPage(_ part: ZoomGuidePart, _ ids: ZoomAppIDs) -> ZoomMarketplacePage {
        switch part {
        case .meetingApp: return ids.meeting.map { .general($0, .information) } ?? .createdApps
        // Step 4 always starts at Created apps, coached for the hosting app.
        case .hostingApp: return .createdApps
        case .check: return .createdApps
        }
    }

    /// Back to Greenroom starts the check once: not if it is running (the auto check started it) or has results.
    static func shouldCheckOnReturn(checkRunning: Bool, hasResults: Bool, inSession: Bool) -> Bool {
        !checkRunning && !hasResults && !inSession
    }
}
