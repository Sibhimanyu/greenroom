//
//  ZoomSignInAvailability.swift
//  Greenroom
//
//  The one switch for Sign in with Zoom (owner, 2026-11-26). Until Zoom
//  approves Greenroom's Zoom app, the sign-in can only start meetings on the
//  account that owns the app (error 63 on every other account), so it shows
//  as Coming soon and everyone uses their own Zoom apps. Every surface reads
//  `isComingSoon` through `ZoomRouteFacts.signInComingSoon`: the route,
//  Settings -> Zoom, Home, the menu bar and the setup guide. All the sign-in
//  code stays; nothing is signed out and no token is deleted.
//
//  DEBUG builds only: Settings -> Debug can turn the sign-in back on for
//  testing (`debugSignInOnKey`). The key and its read exist only under
//  #if DEBUG, so a Release build always uses `comingSoon`. Pure: Foundation only.
//
import Foundation

enum ZoomSignInAvailability {
    /// Flip to false when Zoom approves the app.
    static let comingSoon = true

    /// What a build uses: the switch, unless a DEBUG build turned the sign-in back on for testing.
    static func resolve(shipped: Bool, debugBuild: Bool, debugSignInOn: Bool) -> Bool {
        guard debugBuild else { return shipped }
        return shipped && !debugSignInOn
    }

    /// True in a DEBUG build (the test target is one).
    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    #if DEBUG
    /// Settings -> Debug's "Sign in with Zoom on for testing". Never in a Release build.
    static let debugSignInOnKey = "debug.zoomSignInOnForTesting"
    #endif

    /// The answer for this build, right now.
    static var isComingSoon: Bool {
        #if DEBUG
        return resolve(shipped: comingSoon, debugBuild: true,
                       debugSignInOn: UserDefaults.standard.bool(forKey: debugSignInOnKey))
        #else
        return comingSoon
        #endif
    }

    /// The small label beside "Sign in with Zoom".
    static let label = "Coming soon"
    /// The disabled option's tooltip.
    static let tooltip = "Coming once Zoom approves Greenroom\u{2019}s Zoom app. Until then, set up your own Zoom apps; it takes about 10 minutes."
}
