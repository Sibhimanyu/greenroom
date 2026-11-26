//
//  YouTubeErrorRules.swift
//  Greenroom
//
//  Google's upload and sign-in errors in plain words, each with the buttons
//  that get the person going again. The upload sheet, the session page's
//  share card and the failure toast all show what this returns, so they
//  never disagree. Google's own long prose stays in the status log.
//
//  Pure: Foundation only.
//
import Foundation

/// A button under a YouTube problem.
enum YouTubeAction: String, Equatable, CaseIterable {
    case signIn, signInAnother, openStudio, tryAgain, createChannel, openCloudConsole

    var title: String {
        switch self {
        case .signIn: return "Sign in again"
        case .signInAnother: return "Use another account"
        case .openStudio: return "Upload in YouTube Studio"
        case .tryAgain: return "Try again"
        case .createChannel: return "Create a channel"
        case .openCloudConsole: return "Open Google Cloud"
        }
    }
}

struct YouTubeProblem: Equatable {
    enum Kind: Equatable {
        /// The Cloud project's daily videos.insert bucket is empty.
        case quotaUsedUp
        /// YouTube's own per-account limit on uploads.
        case accountUploadLimit
        /// The refresh token was revoked, expired, or refused.
        case signInEnded
        case notSignedIn
        /// A token from before the scope widened.
        case needsPermission
        /// The Google account has no YouTube channel.
        case noChannel
        /// Your own Google app without YouTube Data API v3 turned on.
        case apiNotEnabled
        /// The connection kept dropping, or Google's servers had trouble.
        case connection
        case unreadable
        case other
    }

    var kind: Kind
    var title: String
    var detail: String
    var actions: [YouTubeAction]
}

enum YouTubeErrorRules {

    /// Said under every problem.
    static let savedNote = "The recording is still on this Mac."

    /// `error.errors[0].reason` and `error.message` from a Google API error
    /// body, or the OAuth `error` / `error_description` pair.
    static func parse(_ data: Data) -> (reason: String?, message: String?) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (nil, nil)
        }
        if let error = json["error"] as? [String: Any] {
            let reason = (error["errors"] as? [[String: Any]])?.first?["reason"] as? String
                ?? error["status"] as? String
            return (reason, error["message"] as? String)
        }
        return (json["error"] as? String, json["error_description"] as? String)
    }

    /// An HTTP error from the YouTube Data API.
    static func problem(status: Int, reason: String?, message: String, sharedApp: Bool) -> YouTubeProblem {
        switch reason ?? "" {
        case "quotaExceeded", "dailyLimitExceeded":
            return problem(.quotaUsedUp, sharedApp: sharedApp)
        case "uploadLimitExceeded":
            return problem(.accountUploadLimit, sharedApp: sharedApp)
        case "insufficientPermissions", "ACCESS_TOKEN_SCOPE_INSUFFICIENT":
            return problem(.needsPermission, sharedApp: sharedApp)
        case "youtubeSignupRequired":
            return problem(.noChannel, sharedApp: sharedApp)
        case "accessNotConfigured", "SERVICE_DISABLED":
            return problem(.apiNotEnabled, sharedApp: sharedApp)
        default:
            break
        }
        if status == 401 { return problem(.signInEnded, sharedApp: sharedApp) }
        if status >= 500 || reason == "backendError" { return problem(.connection, sharedApp: sharedApp) }
        var p = problem(.other, sharedApp: sharedApp)
        let words = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { p.detail = words }
        return p
    }

    static func problem(_ kind: YouTubeProblem.Kind, sharedApp: Bool) -> YouTubeProblem {
        switch kind {
        case .quotaUsedUp:
            return YouTubeProblem(
                kind: kind,
                title: "YouTube\u{2019}s daily upload limit for \(sharedApp ? "Greenroom" : "your Google app") is used up",
                detail: "Try again tomorrow, or use Upload in YouTube Studio.",
                actions: [.openStudio])
        case .accountUploadLimit:
            return YouTubeProblem(
                kind: kind, title: "This YouTube account has reached its upload limit for now",
                detail: "YouTube limits how many videos one account can upload in a day. Try again later, or upload in YouTube Studio.",
                actions: [.openStudio])
        case .signInEnded:
            return YouTubeProblem(
                kind: kind, title: "Your Google sign-in has ended",
                detail: "It was signed out or access was removed. Sign in again, then upload.",
                actions: [.signIn, .openStudio])
        case .notSignedIn:
            return YouTubeProblem(
                kind: kind, title: "Not signed in to YouTube",
                detail: "Sign in with Google to upload from Greenroom, or upload in YouTube Studio.",
                actions: [.signIn, .openStudio])
        case .needsPermission:
            return YouTubeProblem(
                kind: kind, title: "Google needs a new permission",
                detail: "Sign in again and allow Greenroom to manage your YouTube videos.",
                actions: [.signIn])
        case .noChannel:
            return YouTubeProblem(
                kind: kind, title: "This Google account has no YouTube channel yet",
                detail: "Create a channel on YouTube, or sign in with the account that has one.",
                actions: [.createChannel, .signInAnother])
        case .apiNotEnabled:
            return YouTubeProblem(
                kind: kind, title: "YouTube is turned off for your Google app",
                detail: "Turn on YouTube Data API v3 for your Google app in Google Cloud, then try again.",
                actions: [.openCloudConsole, .tryAgain])
        case .connection:
            return YouTubeProblem(
                kind: kind, title: "The upload couldn\u{2019}t reach YouTube",
                detail: "The connection kept dropping. Check the internet connection and try again.",
                actions: [.tryAgain, .openStudio])
        case .unreadable:
            return YouTubeProblem(
                kind: kind, title: "The recording couldn\u{2019}t be read",
                detail: "It may have been moved or deleted. Check Sessions.",
                actions: [.openStudio])
        case .other:
            return YouTubeProblem(
                kind: kind, title: "YouTube didn\u{2019}t take the upload",
                detail: "Try again, or upload in YouTube Studio.",
                actions: [.tryAgain, .openStudio])
        }
    }
}
