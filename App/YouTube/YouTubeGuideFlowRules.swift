//
//  YouTubeGuideFlowRules.swift
//  Greenroom
//
//  The setup guide's YouTube step as a guided step (owner, 2026-11-26), in
//  the Zoom step's language: two cards, one open at a time. "Your YouTube
//  account" (the same choice as Settings, then Sign in, or your own app's
//  fields) and "After each recording" (Ask / Upload automatically / Do
//  nothing, with the Made for Kids answer when Upload automatically needs
//  it). This file decides each card's state and header label, which card is
//  open, each mode's one line, and where a deep link lands. Pure: Foundation only.
//
import Foundation

/// The step's cards, in order.
enum YouTubeGuideCard: Int, CaseIterable, Equatable, Hashable {
    case account, afterRecording

    var number: Int { rawValue + 1 }

    var title: String {
        switch self {
        case .account: return "Your YouTube account"
        case .afterRecording: return "After each recording"
        }
    }
}

enum YouTubeGuideCardState: Equatable {
    case notStarted, inProgress, done
    /// Upload automatically without the Made for Kids answer.
    case needsAnswer
}

struct YouTubeGuideFlow: Equatable {
    var account: YouTubeGuideCardState
    var afterRecording: YouTubeGuideCardState
    /// The card to open; nil when both are done.
    var open: YouTubeGuideCard?
    var accountLabel: String
    var afterLabel: String
    /// Upload automatically is picked: the Made for Kids answer and the §9.1 line show.
    var showsMadeForKids: Bool
    var showsCertify: Bool

    func state(_ card: YouTubeGuideCard) -> YouTubeGuideCardState {
        card == .account ? account : afterRecording
    }

    func label(_ card: YouTubeGuideCard) -> String {
        card == .account ? accountLabel : afterLabel
    }
}

enum YouTubeGuideFlowRules {
    static func flow(account: YouTubeAccountChoice, mode: YouTubeUploadMode, madeForKids: Bool?) -> YouTubeGuideFlow {
        let accountState: YouTubeGuideCardState
        if account.readyToUpload { accountState = .done }
        else if account.waiting || account.setupTone == .problem || (account.buttons.contains(.signOut) && !account.signedInHere) {
            accountState = .inProgress
        } else { accountState = .notStarted }

        let needsAnswer = mode == .automatic && madeForKids == nil
        let after: YouTubeGuideCardState = needsAnswer ? .needsAnswer : .done

        let open: YouTubeGuideCard?
        if accountState != .done { open = .account }
        else if after != .done { open = .afterRecording }
        else { open = nil }

        return YouTubeGuideFlow(account: accountState, afterRecording: after, open: open,
                                accountLabel: account.account,
                                afterLabel: needsAnswer ? "Needs the Made for Kids answer" : mode.label,
                                showsMadeForKids: mode == .automatic, showsCertify: mode == .automatic)
    }

    /// The one plain line under the choice.
    static func modeLine(_ mode: YouTubeUploadMode) -> String {
        switch mode {
        case .off: return "Do nothing: no recordings leave this Mac."
        case .ask: return "Ask: after each recording, choose Upload or Not now. Recordings stay in Documents/Greenroom either way."
        case .automatic: return "Upload automatically: each recording goes to your channel as soon as it ends. A copy stays in Documents/Greenroom."
        }
    }

    /// The card a deep link opens; nil for the step's top (the flow's own open card).
    static func card(for spot: YouTubeGuideSpot) -> YouTubeGuideCard? {
        switch spot {
        case .step: return nil
        case .ownApp: return .account
        }
    }

    static let title = "Share recordings on YouTube"
    static let subtitle = "Optional, and you can do it later. Uploads are Unlisted unless you choose otherwise."
    static let footnote = "No sign-in? Every upload sheet also has Upload in YouTube Studio."
}
