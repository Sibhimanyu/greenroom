//
//  YouTubeAccountChoiceRules.swift
//  Greenroom
//
//  Settings -> YouTube's account as one choice of two (owner, 2026-11-26:
//  "like the two options how we did for the Zoom one"), the YouTube twin of
//  ZoomRouteChoiceRules. The person picks "Greenroom's Google app" or "Your
//  own Google app" at the top of the section, bound to the same stored
//  choice the old toggle used (`youtubeUsesOwnApp`). Only the chosen
//  option's section shows; this file decides what it says: the account line,
//  its buttons, your own app's setup status, and where "Set up… / Edit
//  setup…" opens the setup guide.
//
//  Strict, never a silent fallback: a sign-in counts for the chosen option
//  only when the chosen app issued it. A token from the other app is still
//  refreshed with the app that issued it (YouTubeRouteRules.tokenApp), but
//  uploads wait for a sign-in through the chosen one (`readyToUpload`).
//  Pure: Foundation only.
//
import Foundation

/// The two Google apps YouTube sign-in can go through, in the order the page shows them.
enum YouTubeAppOption: String, CaseIterable, Equatable {
    case greenroom, own

    init(prefersOwnApp: Bool) { self = prefersOwnApp ? .own : .greenroom }

    /// The stored choice (`youtubeUsesOwnApp`).
    var prefersOwnApp: Bool { self == .own }

    var app: YouTubeGoogleApp {
        switch self {
        case .greenroom: return .shared
        case .own: return .own
        }
    }

    var title: String {
        switch self {
        case .greenroom: return "Greenroom\u{2019}s Google app"
        case .own: return "Your own Google app"
        }
    }

    /// The one grey line under the choice.
    var note: String {
        switch self {
        case .greenroom:
            return "Sign in with any Google account. Google may show \u{201C}hasn\u{2019}t verified this app\u{201D}: click Advanced, then Go to Greenroom."
        case .own:
            return "For when Greenroom\u{2019}s app has reached Google\u{2019}s 100-person limit, or to have your own daily upload limit."
        }
    }
}

/// Where a deep link opens the setup guide's YouTube step.
enum YouTubeGuideSpot: String, Equatable, Hashable {
    /// The step's top (its own open card).
    case step
    /// The account card, at the own-app part (Client ID, Secret, Google Cloud steps).
    case ownApp
}

/// Settings' one button into the guide, for your own Google app.
struct YouTubeSetupEntry: Equatable {
    var title: String
    var spot: YouTubeGuideSpot
}

enum YouTubeAccountButton: Equatable { case signIn, useAnotherAccount, signOut }

enum YouTubeStatusTone: Equatable { case good, waiting, problem }

struct YouTubeAccountFacts: Equatable {
    var route: YouTubeRouteFacts
    /// A refresh token is stored.
    var signedIn: Bool
    /// The app that issued it.
    var tokenApp: YouTubeGoogleApp
    var channelName: String?
    /// The browser sign-in is under way.
    var signingIn: Bool
}

/// What the chosen option's section shows.
struct YouTubeAccountChoice: Equatable {
    var selected: YouTubeAppOption
    /// The account line: "Signed in as …", "Not signed in", …
    var account: String
    var accountTone: YouTubeStatusTone
    /// What to do next, under the account line; nil when nothing is needed.
    var hint: String?
    /// Your own app only: "Ready" or what is missing.
    var setupStatus: String?
    var setupTone: YouTubeStatusTone?
    var buttons: [YouTubeAccountButton]
    /// Sign in (and Use another account) can run now.
    var signInEnabled: Bool
    /// Your own app only: "Set up…" / "Edit setup…" and where it lands.
    var setupEntry: YouTubeSetupEntry?
    /// Uploads can go: signed in through the chosen app, and that app can refresh.
    var readyToUpload: Bool
    /// A sign-in on the chosen app (shown with its channel picture).
    var signedInHere: Bool
    /// Google is open in the browser for a sign-in.
    var waiting: Bool
}

enum YouTubeAccountRules {
    static func choice(_ f: YouTubeAccountFacts) -> YouTubeAccountChoice {
        let selected = YouTubeAppOption(prefersOwnApp: f.route.prefersOwnApp)
        let route = YouTubeRouteRules.signInRoute(f.route)
        let routeWorks = route.app == selected.app
        let here = f.signedIn && f.tokenApp == selected.app
        let otherApp = f.signedIn && !here

        var setupStatus: String? = nil, setupTone: YouTubeStatusTone? = nil, entry: YouTubeSetupEntry? = nil
        if selected == .own {
            let id = !f.route.ownClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let secret = !f.route.ownClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            switch (id, secret) {
            case (true, true): (setupStatus, setupTone) = ("Ready", .good)
            case (false, false): (setupStatus, setupTone) = ("Needs a Client ID and Secret", .waiting)
            case (true, false): (setupStatus, setupTone) = ("Needs the Client Secret", .problem)
            case (false, true): (setupStatus, setupTone) = ("Needs the Client ID", .problem)
            }
            entry = YouTubeSetupEntry(title: id || secret ? "Edit setup\u{2026}" : "Set up\u{2026}", spot: .ownApp)
        }

        let account: String, tone: YouTubeStatusTone, buttons: [YouTubeAccountButton]
        var hint: String? = nil
        if f.signingIn {
            (account, tone, buttons) = ("Waiting for Google in your browser\u{2026}", .waiting, [.signIn])
        } else if here {
            let name = f.channelName?.trimmingCharacters(in: .whitespaces) ?? ""
            account = name.isEmpty ? "Signed in" : "Signed in as \(name)"
            (tone, buttons) = (.good, [.useAnotherAccount, .signOut])
        } else if otherApp {
            account = selected == .greenroom ? "Not signed in with Greenroom\u{2019}s Google app"
                                             : "Not signed in with your own Google app"
            (tone, buttons) = (.waiting, [.signIn, .signOut])
            hint = selected == .greenroom
                ? "You are signed in through your own Google app. Sign in again to use Greenroom\u{2019}s."
                : "You are signed in through Greenroom\u{2019}s Google app. Sign in again to use your own."
        } else if route == .none(.sharedNotAvailableYet) {
            (account, tone, buttons) = ("Not available yet", .waiting, [.signIn])
            hint = YouTubeRouteGap.sharedNotAvailableYet.message
        } else {
            (account, tone, buttons) = ("Not signed in", .waiting, [.signIn])
            if selected == .own && !routeWorks { hint = "Set up your Google app first, then sign in." }
        }

        return YouTubeAccountChoice(
            selected: selected, account: account, accountTone: tone, hint: hint,
            setupStatus: setupStatus, setupTone: setupTone, buttons: buttons,
            signInEnabled: routeWorks && !f.signingIn, setupEntry: entry,
            readyToUpload: here && routeWorks, signedInHere: here, waiting: f.signingIn)
    }
}

/// Making your own Google app, step by step: the setup guide's own-app part.
enum YouTubeCloudGuide {
    static let url = URL(string: "https://console.cloud.google.com/apis/credentials")!
    static let linkTitle = "Open Google Cloud"
    static let steps = [
        "In Google Cloud, choose or create a project.",
        "In APIs & Services \u{2192} Library, turn on YouTube Data API v3.",
        "Set up the OAuth consent screen. While it is in Testing, add your Google account as a test user.",
        "In Credentials, create an OAuth client ID of type Desktop app.",
        "Paste its Client ID and Client Secret here, then sign in.",
    ]
    /// Under the fields: the one detail people trip on.
    static let testingNote = "While the Google project is in Testing, the sign-in lasts seven days. Publish it in the consent screen to keep it."
    /// The field's hover help.
    static let clientHelp = "From a Google Cloud OAuth client of type \u{201C}Desktop app\u{201D} with YouTube Data API v3 turned on. While the Google project is in Testing, the sign-in lasts seven days."
}
