//
//  ZoomMarketplaceGuide.swift
//  Greenroom
//
//  The short "how do I get these keys" steps in the setup guide's manual route
//  (`ZoomGuideStep`); the longer "Show me each click" text sits under them. Pure Foundation. The menu names match
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
}
