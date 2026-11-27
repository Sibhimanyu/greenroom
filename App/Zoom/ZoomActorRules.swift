//
//  ZoomActorRules.swift
//  Greenroom
//
//  The deny-list (docs/specs/zoom-setup-flow.md, "ZoomActor"): words that Greenroom never presses, checked
//  by the page adapter on the element's own text at the moment of the press, and always winning over any
//  plan. (What a plan MAY name is `ZoomActor.mayPress` / `mayType`.) Pure: Foundation only.
//
import Foundation

enum ZoomActorRules {
    /// Never pressed, even when a plan names the control.
    static let denyPattern = "(regenerate|delete|remove|deactivate|disable|submit|publish|agree|accept|terms|sign out|log out|uninstall)"

    static func isDenied(_ text: String) -> Bool {
        text.range(of: denyPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
