//
//  ZoomSignInStateRules.swift
//  Greenroom
//
//  Whether the Zoom window is signed in to Marketplace, so "Sign out of Zoom"
//  is offered only when it is (owner bug, 2026-11-27: it showed while
//  Marketplace itself said "Sign In"). Facts: a sign-in page is signed out; a
//  read-only look at Marketplace's header after each page load (a "Sign In"
//  link: signed out; an account menu: signed in); Sign out of Zoom: signed out
//  at once; before the first report: unknown. Pure: Foundation only.
//
import Foundation

enum ZoomSignInState: Equatable { case unknown, signedIn, signedOut }

/// What `ZoomSignInHeaderScript` saw in Marketplace's header.
enum ZoomHeaderReport: String, Equatable { case signInLink, account, neither }

enum ZoomSignInStateRules {
    static let afterSignOut = ZoomSignInState.signedOut

    static func state(page: ZoomMarketplacePage?, header: ZoomHeaderReport?, current: ZoomSignInState) -> ZoomSignInState {
        if page == .signIn { return .signedOut }
        switch header {
        case .signInLink: return .signedOut
        case .account: return .signedIn
        case .neither, nil: return current
        }
    }

    static func offersSignOut(_ state: ZoomSignInState) -> Bool { state == .signedIn }
}
