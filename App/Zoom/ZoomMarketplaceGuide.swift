//
//  ZoomMarketplaceGuide.swift
//  Greenroom
//
//  The short "how do I get these keys" text under each block of Settings ->
//  Zoom -> "Use your own Zoom apps". Pure Foundation. The menu names match the
//  setup guide's Zoom step (OnboardingView.manualZoomSetup); change both
//  together.
//
import Foundation

enum ZoomMarketplaceGuide {
    /// Where the setup guide already sends people to build an app.
    static let builderURL = URL(string: "https://marketplace.zoom.us/user/build")!
    static let linkTitle = "Open Zoom App Marketplace"
    static let guideButtonTitle = "Show the step-by-step guide"

    static let sdkSteps = [
        "Choose Build App \u{2192} General App.",
        "Under Features \u{2192} Embed, turn on Meeting SDK.",
        "Copy the Client ID and Client Secret from Basic Information.",
        "Paste them here.",
    ]

    static let s2sSteps = [
        "Choose Build App \u{2192} Server-to-Server OAuth.",
        "Add the scopes. Use Copy scopes below.",
        "Activate the app.",
        "Copy the Account ID, Client ID and Client Secret from App Credentials, and paste them here.",
    ]
}
