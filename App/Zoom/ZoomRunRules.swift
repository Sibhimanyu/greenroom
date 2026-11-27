//
//  ZoomRunRules.swift
//  Greenroom
//
//  The Zoom window's run as a feedback loop (spec R18). Keys in are not "done":
//  an app is set up only when its keys are complete AND the latest Check Zoom
//  setup passed for that app. A failed check line becomes the current step (a
//  missing scope: Scopes; a refused token: Activation; Meeting SDK off: Embed;
//  missing keys: the credentials page), and the window re-checks after each
//  completed step until the app passes. Zoom's own tab order, App Credentials,
//  Information, Feature, Scopes, Activation, decides what "Continue" opens.
//  Pure: Foundation only.
//

import Foundation

/// What the latest check says to fix in one app, in the places Zoom keeps them.
enum ZoomFix: Equatable {
    case keys
    case scopes(missing: Int)
    case activation
    case embed
}

enum ZoomRunRules {
    /// The check lines that belong to one app: the Meeting SDK line, or every other (hosting) line.
    private static func lines(of app: ZoomOwnApp, _ all: [ZoomCheckLine]) -> [ZoomCheckLine] {
        app == .sdk ? all.filter { $0.id == "sdk" } : all.filter { $0.id != "sdk" }
    }

    private static func keyLine(_ app: ZoomOwnApp) -> String { app == .sdk ? "sdk" : "account" }

    /// Set up: complete keys, no check running, the app's key line passed and none of its lines failed.
    static func passed(_ app: ZoomOwnApp, lines all: [ZoomCheckLine], running: Bool, keysComplete: Bool) -> Bool {
        guard keysComplete, !running, !all.isEmpty else { return false }
        let mine = lines(of: app, all)
        guard mine.first(where: { $0.id == keyLine(app) })?.status == .passed else { return false }
        return !mine.contains { $0.status == .failed }
    }

    /// The first thing to fix in this app, from the failed lines; nil when nothing failed (or nothing ran).
    static func fix(_ app: ZoomOwnApp, lines all: [ZoomCheckLine], keysComplete: Bool) -> ZoomFix? {
        let mine = lines(of: app, all)
        let failedKeyLine = mine.first { $0.id == keyLine(app) && $0.status == .failed }
        if let failedKeyLine {
            // "Add both ... / Add all three ..." says the keys are missing; any other failure after keys are in is the app itself.
            if !keysComplete || failedKeyLine.detail.hasPrefix("Add ") { return .keys }
            return app == .sdk ? .embed : .activation
        }
        if app == .s2s {
            var names = Set<String>()
            for line in mine where line.status == .failed {
                for button in line.actions { if case .copyScope(let name) = button.action { names.insert(name) } }
            }
            if !names.isEmpty { return .scopes(missing: names.count) }
        }
        return nil
    }

    static func title(_ fix: ZoomFix) -> String {
        switch fix {
        case .keys: return "Copy its keys"
        case .scopes(let n): return n == 0 ? "Add the permissions" : n == 1 ? "Add 1 missing permission" : "Add \(n) missing permissions"
        case .activation: return "Turn it on"
        case .embed: return "Turn on Meeting SDK"
        }
    }

    /// The step number (of `ZoomRun`) a fix lives at.
    static func step(_ fix: ZoomFix, app: ZoomOwnApp) -> Int {
        switch (fix, app) {
        case (.keys, .sdk): return 2
        case (.embed, _): return 3
        case (.keys, .s2s): return 5
        case (.scopes, _): return 7
        case (.activation, _): return 8
        }
    }

    static func page(_ fix: ZoomFix, app: ZoomOwnApp, id: String) -> ZoomMarketplacePage {
        switch (fix, app) {
        case (.keys, .sdk): return .general(id, .information)
        case (.embed, _): return .general(id, .embed)
        case (.keys, .s2s): return .s2s(id, .credentials)
        case (.scopes, _): return .s2s(id, .scopes)
        case (.activation, _): return .s2s(id, .activation)
        }
    }

    /// Zoom's own tab order; what "Continue" opens after a page. nil at the end of a wizard.
    static func nextTab(after page: ZoomMarketplacePage) -> ZoomMarketplacePage? {
        switch page {
        case .s2s(let id, .credentials): return .s2s(id, .information)
        case .s2s(let id, .information): return .s2s(id, .feature)
        case .s2s(let id, .feature): return .s2s(id, .scopes)
        case .s2s(let id, .scopes): return .s2s(id, .activation)
        case .general(let id, .information): return .general(id, .embed)
        default: return nil
        }
    }

    /// Pages whose Continue needs nothing from the person first: the key pages once keys are in (the caller checks that),
    /// Information and Feature. Scopes and Activation wait for the check; Embed has no next tab.
    static func continuesWithoutWork(_ page: ZoomMarketplacePage) -> Bool {
        switch page {
        case .s2s(_, .credentials), .s2s(_, .information), .s2s(_, .feature), .general(_, .information): return true
        default: return false
        }
    }

    /// The check starts by itself when a part's keys become complete (not while one runs or a session is live).
    static func shouldCheckAfterKeys(completeBefore: Bool, completeAfter: Bool, inSession: Bool, running: Bool) -> Bool {
        completeAfter && !completeBefore && !inSession && !running
    }

    /// After a completed step, or a page change away from a fixed place: check again while something is failing.
    static func shouldRecheck(hasFix: Bool, running: Bool, inSession: Bool) -> Bool {
        hasFix && !running && !inSession
    }
}
