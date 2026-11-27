//
//  ZoomCheckActionRules.swift
//  Greenroom
//
//  What a failing or warning Zoom check line offers to click (owner,
//  2026-11-26: "when I get errors like this I should get immediate
//  call-to-action buttons"), for both checks: "Check Zoom setup" (your own
//  Zoom apps) and "Check sign-in". The checkers sort each outcome into a
//  `ZoomCheckProblem`; this file turns check × outcome into buttons, so the
//  view only draws them. Pure: Foundation only.
//
import Foundation

/// Which checker a line came from (their check IDs overlap: create, account).
enum ZoomCheckKind: Equatable { case ownApps, signIn }

/// One of your own two Zoom apps.
enum ZoomOwnApp: Equatable, Hashable { case sdk, s2s }

/// A place in the setup guide's Zoom step. `zoomStep` is the step's top.
enum ZoomGuideSpot: String, Equatable, Hashable {
    case zoomStep, sdkCredentials, s2sCredentials, s2sScopes, s2sActivation
}

/// What went wrong on a line, in the kinds the buttons follow from.
enum ZoomCheckProblem: Equatable {
    case nothing
    case missingScopes([String])
    case badCredentials
    case notActivated
    case signIn
    case otherAccount
    case network
    case zoomDown
    case other
}

enum ZoomCheckAction: Equatable, Hashable {
    case copyScope(String)
    case openScopesPage
    case openAppCredentials(ZoomOwnApp)
    case openApp(ZoomOwnApp)
    case showGuide(ZoomGuideSpot)
    case signInAgain
    case useOwnApps
    case checkAgain

    var title: String {
        switch self {
        case .copyScope: return "Copy scope"
        case .openScopesPage: return "Open Scopes page"
        case .openAppCredentials: return "Open App Credentials"
        case .openApp: return "Open the app"
        case .showGuide: return "Show me where"
        case .signInAgain: return "Sign in again"
        case .useOwnApps: return "Use my own Zoom apps"
        case .checkAgain: return "Check again"
        }
    }

    /// The Marketplace page it opens: the exact page once the Zoom window has seen the app
    /// (its ID is in `ids`), else the list of your apps.
    func url(ids: ZoomCheckActionContext) -> URL? {
        let page: ZoomMarketplacePage?
        switch self {
        case .openScopesPage: page = ids.s2sAppID.isEmpty ? nil : .s2s(ids.s2sAppID, .scopes)
        case .openAppCredentials(.s2s): page = ids.s2sAppID.isEmpty ? nil : .s2s(ids.s2sAppID, .credentials)
        case .openApp(.s2s): page = ids.s2sAppID.isEmpty ? nil : .s2s(ids.s2sAppID, .activation)
        case .openAppCredentials(.sdk), .openApp(.sdk): page = ids.sdkAppID.isEmpty ? nil : .general(ids.sdkAppID, .information)
        default: return nil
        }
        return page.flatMap(ZoomMarketplacePages.url(for:)) ?? ZoomMarketplaceGuide.builderURL
    }

    /// Which part of the guide the Zoom window opens for (what its coach points at); nil when it opens nothing.
    var zoomPart: ZoomGuidePart? {
        switch self {
        case .openScopesPage, .openAppCredentials(.s2s), .openApp(.s2s): return .hostingApp
        case .openAppCredentials(.sdk), .openApp(.sdk): return .meetingApp
        default: return nil
        }
    }
}

struct ZoomCheckButton: Equatable, Hashable {
    let action: ZoomCheckAction
    var primary = false
}

/// The client IDs the tooltips name the apps by.
struct ZoomCheckActionContext: Equatable {
    var sdkClientID = ""
    var s2sClientID = ""
    /// The Marketplace app IDs the Zoom window has seen (empty until it has).
    var sdkAppID = ""
    var s2sAppID = ""
}

enum ZoomCheckActionRules {
    /// The buttons for one line, in order; the main fix (at most one) is primary.
    /// Lines that passed, were not tried, or are left to Start offer nothing.
    static func buttons(_ kind: ZoomCheckKind, check: String, status: ZoomCheckStatus,
                        problem: ZoomCheckProblem, ids: ZoomCheckActionContext) -> [ZoomCheckButton] {
        guard status == .failed || status == .warned else { return [] }
        let actions = self.actions(kind, check: check, problem: problem)
        // A warning is not broken yet: its buttons stay quiet.
        return actions.enumerated().map { i, action in
            ZoomCheckButton(action: action, primary: status == .failed && i == primaryIndex(actions))
        }
    }

    /// Copy scope sits before the page it is pasted into; the page is the fix.
    private static func primaryIndex(_ actions: [ZoomCheckAction]) -> Int? {
        if actions.first.map({ if case .copyScope = $0 { return true } else { return false } }) == true {
            return actions.count > 1 ? 1 : 0
        }
        return actions.isEmpty ? nil : 0
    }

    private static func actions(_ kind: ZoomCheckKind, check: String, problem: ZoomCheckProblem) -> [ZoomCheckAction] {
        if problem == .network || problem == .zoomDown { return [.checkAgain] }
        switch kind {
        case .ownApps:
            let app: ZoomOwnApp = check == "sdk" ? .sdk : .s2s
            switch problem {
            case .missingScopes(let names):
                // Show me where: the guide's scope list, which marks what the check found missing.
                return names.map { .copyScope($0) } + [.openScopesPage, .showGuide(.s2sScopes)]
            case .badCredentials:
                return [.openAppCredentials(app), .showGuide(app == .sdk ? .sdkCredentials : .s2sCredentials)]
            case .notActivated:
                return [.openApp(app), .showGuide(.s2sActivation)]
            default:
                return []
            }
        case .signIn:
            switch (check, problem) {
            case (_, .otherAccount): return [.useOwnApps]
            case ("signature", _): return [.checkAgain]
            case ("token", _), ("profile", _), ("scopes", _), ("zak", _): return [.signInAgain]
            default: return []
            }
        }
    }

    static func help(_ action: ZoomCheckAction, ids: ZoomCheckActionContext) -> String {
        let marketplace = "Opens your apps in the Zoom App Marketplace. Pick "
        func which(_ app: ZoomOwnApp) -> String {
            let id = (app == .sdk ? ids.sdkClientID : ids.s2sClientID).trimmingCharacters(in: .whitespaces)
            let type = app == .sdk ? "General App" : "Server-to-Server app"
            return id.isEmpty ? "your \(type)" : "the \(type) with client ID \(ZoomRouteWords.clientIDTail(id))"
        }
        // The Zoom window goes straight to the page once it knows the app.
        if action.zoomPart != nil, action.url(ids: ids) != ZoomMarketplaceGuide.builderURL {
            switch action {
            case .openScopesPage: return "Opens Scopes for your Server-to-Server app in the Zoom window."
            case .openApp(.s2s): return "Opens Activation for your Server-to-Server app in the Zoom window."
            case .openAppCredentials(.s2s): return "Opens App Credentials for your Server-to-Server app in the Zoom window."
            default: return "Opens Basic information for your General App in the Zoom window."
            }
        }
        switch action {
        case .copyScope(let name): return "Copies \(name)"
        case .openScopesPage: return marketplace + which(.s2s) + ", then Scopes \u{2192} Add Scopes."
        case .openAppCredentials(.sdk): return marketplace + which(.sdk) + ", then Basic Information \u{2192} App Credentials."
        case .openAppCredentials(.s2s): return marketplace + which(.s2s) + ", then App Credentials."
        case .openApp(let app): return marketplace + which(app) + ", then Activation \u{2192} Activate your app."
        case .showGuide: return "Opens the setup guide at this step."
        case .signInAgain: return "Signs in with Zoom again, so Zoom asks for what is missing."
        case .useOwnApps: return "Switches Settings \u{2192} Zoom to your own Zoom apps."
        case .checkAgain: return "Runs the checks again."
        }
    }

    /// A thrown error that means the Mac could not reach Zoom (offline, DNS, timeout).
    static func isNetwork(_ error: Error?) -> Bool {
        guard let error else { return false }
        return (error as NSError).domain == NSURLErrorDomain
    }

    /// Sorts an error's text into a problem. Zoom's token endpoint says
    /// `invalid_client` for wrong keys; an outage answers with an HTML page or a 5xx phrase.
    static func problem(_ error: String, _ isNetwork: Bool) -> ZoomCheckProblem {
        if isNetwork { return .network }
        let text = error.lowercased()
        let outage = ["<html", "bad gateway", "service unavailable", "gateway timeout", "internal server error"]
        if outage.contains(where: text.contains) { return .zoomDown }
        if text.contains("not activated") || text.contains("activate") { return .notActivated }
        return .badCredentials
    }
}

/// The bar over the lines when anything needs fixing: how many, and the fixes
/// that cover them all at once.
struct ZoomCheckFixBar: Equatable {
    let title: String
    /// Every missing Server-to-Server scope, in line order.
    let missingScopes: [String]
    /// One per line: Zoom's scope search takes one name at a time, so they
    /// are pasted one line at a time.
    var copyAllText: String { missingScopes.joined(separator: "\n") }
    var offersScopesPage: Bool { !missingScopes.isEmpty }
}

extension ZoomCheckSummary {
    static func fixBar(_ lines: [ZoomCheckLine], running: Bool) -> ZoomCheckFixBar? {
        guard !running else { return nil }
        let failed = lines.filter { $0.status == .failed }.count
        let warned = lines.filter { $0.status == .warned }.count
        let title: String
        if failed > 0 { title = failed == 1 ? "1 thing to fix" : "\(failed) things to fix" }
        else if warned > 0 { title = warned == 1 ? "1 thing to check" : "\(warned) things to check" }
        else { return nil }
        return ZoomCheckFixBar(title: title, missingScopes: missingScopes(lines))
    }

    /// The scopes the lines' Copy scope buttons carry, in order, once each.
    static func missingScopes(_ lines: [ZoomCheckLine]) -> [String] {
        var seen = Set<String>()
        return lines.flatMap(\.actions).compactMap { button -> String? in
            if case .copyScope(let name) = button.action, seen.insert(name).inserted { return name }
            return nil
        }
    }
}
