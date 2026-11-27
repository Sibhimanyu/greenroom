//
//  ZoomMarketplaceGuide.swift
//  Greenroom
//
//  The short "how do I get these keys" steps at the top of the setup guide's
//  Meeting app and Hosting app parts (`ZoomGuideStep`); the longer "Show me
//  each click" text sits under them. Pure Foundation. The menu names match
//  that longer text; change both together.
//
import Foundation

enum ZoomMarketplaceGuide {
    /// Where the setup guide already sends people to build an app.
    static let builderURL = URL(string: "https://marketplace.zoom.us/user/build")!
    static let linkTitle = "Open Zoom App Marketplace"
    static let detailTitle = "Show me each click"

    static let sdkSteps = [
        "Choose Build App \u{2192} General app.",
        "Under Embed, turn on Meeting SDK.",
        "Copy the Client ID and Client Secret from Basic information.",
    ]

    static let s2sSteps = [
        "Choose Build App \u{2192} Server to server OAuth app.",
        "Add the scopes. Use Copy scopes below.",
        "Activate the app.",
        "Copy the Account ID, Client ID and Client Secret from App Credentials.",
    ]

    /// The steps with their buttons (R4): before an app ID is known only step 1 has one, "Create the app"
    /// (or "Find my app" when the part's keys are already filled in, R12).
    static func rows(part: ZoomGuidePart, ids: ZoomAppIDs, keysFilled: Bool = false) -> [ZoomGuideRow] {
        let steps: [String]
        let links: [(String, (String) -> ZoomMarketplacePage)?]
        let id: String?
        switch part {
        case .meetingApp:
            steps = sdkSteps; id = ids.meeting
            links = [nil, ("Open Embed", { .general($0, .embed) }), ("Open Basic information", { .general($0, .information) })]
        case .hostingApp:
            steps = s2sSteps; id = ids.hosting
            links = [nil, ("Open Scopes", { .s2s($0, .scopes) }), ("Open Activation", { .s2s($0, .activation) }),
                     ("Open App Credentials", { .s2s($0, .credentials) })]
        case .check:
            return []
        }
        return steps.enumerated().map { i, text in
            guard let id else {
                return ZoomGuideRow(text: text, link: i == 0 ? ZoomGuideRowLink(title: keysFilled ? ZoomStartOverRules.findMyAppTitle : "Create the app", page: .createdApps) : nil)
            }
            return ZoomGuideRow(text: text, link: links[i].map { ZoomGuideRowLink(title: $0.0, page: $0.1(id)) })
        }
    }
}

struct ZoomGuideRowLink: Equatable { let title: String; let page: ZoomMarketplacePage }
struct ZoomGuideRow: Equatable { let text: String; let link: ZoomGuideRowLink? }
