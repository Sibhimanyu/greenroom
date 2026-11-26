//
//  ZoomSetupCheckRules.swift
//  Greenroom
//
//  The shared Zoom checker's model (one line per step: pass, warn, fail, at
//  Start, skipped) and its summary, used by both checks: "Check Zoom setup"
//  for your own Zoom apps (OnboardingView) and "Check sign-in" for Sign in
//  with Zoom (ZoomSignInChecker). Both draw through ZoomCheckPanel.
//
//  The sign-in check's steps run in the order Start needs them, and every
//  outcome's words live here so a table test pins them. Pure: Foundation only.
//
import Foundation

enum ZoomCheckStatus: Equatable {
    case waiting, running, passed, warned, failed
    /// Can't be tried without doing it for real; Start does it.
    case atStart
    /// Not tried because an earlier step failed.
    case skipped
}

struct ZoomCheckLine: Identifiable, Equatable {
    var id: String
    var title: String
    var status: ZoomCheckStatus = .waiting
    var detail: String = "Waiting to check"

    var ok: Bool { status == .passed }
}

enum ZoomCheckSummary {
    /// Lines left to Start are not counted: they were not checked here.
    static func count(_ lines: [ZoomCheckLine]) -> String {
        let counted = lines.filter { $0.status != .atStart }
        return "\(counted.filter(\.ok).count) of \(counted.count) checks passed"
    }

    static func headline(_ lines: [ZoomCheckLine], subject: String, running: Bool) -> String {
        if running { return "Checking your \(subject)" }
        let fine = lines.allSatisfy { $0.status == .passed || $0.status == .atStart }
        return fine ? "\(subject) checks passed" : "\(subject) needs attention"
    }

    /// The quiet word at the end of a line.
    static func trailing(_ status: ZoomCheckStatus) -> String? {
        switch status {
        case .passed: return "Passed"
        case .warned: return "Check"
        case .atStart: return "At Start"
        default: return nil
        }
    }
}

// MARK: - The sign-in check

enum ZoomSignInCheckStep: String, CaseIterable {
    case token, profile, scopes, zak, signature, create, account

    var title: String {
        switch self {
        case .token: return "Zoom sign-in is still valid"
        case .profile: return "Your Zoom account answers"
        case .scopes: return "Permissions Greenroom needs"
        case .zak: return "Host key for your meetings"
        case .signature: return "Greenroom\u{2019}s signing service"
        case .create: return "Creating a meeting on your account"
        case .account: return "Starting meetings on this account"
        }
    }
}

enum ZoomSignInCheckFact: Equatable {
    /// Worked; the value is shown where the words use one (name, key tail).
    case ok(String)
    case failed(String)
    case missingScopes([String])
    /// Zoom did not say (no granted-scope list stored).
    case unknown
    case atStart
    case skipped
    // The account step (error 63).
    case sameAsApp
    case refused(account: String)
    case otherThanApp(account: String)
    case ownerUnknown(account: String)
}

enum ZoomSignInCheckRules {
    static func line(_ step: ZoomSignInCheckStep, _ fact: ZoomSignInCheckFact) -> ZoomCheckLine {
        let (status, detail) = words(step, fact)
        return ZoomCheckLine(id: step.rawValue, title: step.title, status: status, detail: detail)
    }

    private static let ownAppsAdvice = "Settings \u{2192} Zoom \u{2192} Your own Zoom apps."
    private static let onlyItsAccount = "Greenroom\u{2019}s Zoom app can only start meetings on the account that made it, and Zoom has not opened it to other accounts yet. Start will fail until then. Use your own Zoom apps instead: "

    private static func words(_ step: ZoomSignInCheckStep, _ fact: ZoomSignInCheckFact) -> (ZoomCheckStatus, String) {
        switch (step, fact) {
        case (_, .skipped): return (.skipped, "Not checked: an earlier step failed. Fix it, then check again.")
        case (_, .atStart): return (.atStart, "Checked at Start: Zoom has no dry run for creating a meeting, so this check doesn\u{2019}t make one.")
        case (.token, .ok): return (.passed, "Zoom renewed the sign-in token.")
        case (.token, .failed(let why)): return (.failed, "\(sentence(why)) Sign out, then sign in with Zoom again.")
        case (.profile, .ok(let who)): return (.passed, "Signed in as \(who).")
        case (.profile, .failed(let why)): return (.failed, "Zoom didn\u{2019}t return your account: \(why)")
        case (.scopes, .ok): return (.passed, "Zoom granted every permission Greenroom asks for.")
        case (.scopes, .missingScopes(let names)):
            return (.failed, "Missing \(names.joined(separator: ", ")). In Settings \u{2192} Zoom, sign in again and approve it.")
        case (.scopes, .unknown): return (.warned, "Zoom didn\u{2019}t say which permissions it granted. Start will tell.")
        case (.zak, .ok): return (.passed, "Zoom returned a host key. No meeting was started.")
        case (.zak, .failed(let why)): return (.failed, "Zoom didn\u{2019}t return a host key: \(why)")
        case (.signature, .ok(let key)):
            return (.passed, "The signing service returned a Meeting SDK key for Greenroom\u{2019}s Zoom app (\(key), production).")
        case (.signature, .failed(let why)): return (.failed, "The signing service didn\u{2019}t sign: \(why)")
        case (.account, .sameAsApp): return (.passed, "This is the account that owns Greenroom\u{2019}s Zoom app, so Start can host here.")
        case (.account, .refused(let account)):
            return (.failed, "Zoom refused a Start with this account (\(account)). " + onlyItsAccount + ownAppsAdvice)
        case (.account, .otherThanApp(let account)):
            return (.failed, "This account (\(account)) is not the one that owns Greenroom\u{2019}s Zoom app. " + onlyItsAccount + ownAppsAdvice)
        case (.account, .ownerUnknown(let account)):
            return (.warned, "Greenroom can\u{2019}t tell from here whether this account (\(account)) owns Greenroom\u{2019}s Zoom app. If it doesn\u{2019}t, Start will fail until Zoom opens the app to other accounts. To be sure, use your own Zoom apps: " + ownAppsAdvice)
        case (_, .failed(let why)): return (.failed, why)
        case (_, .ok): return (.passed, "Passed.")
        default: return (.warned, "Greenroom couldn\u{2019}t check this.")
        }
    }

    /// The account step. A remembered refusal is proof; else the owner's
    /// account ID, when it is known (`ZoomOAuth.appOwnerAccountID`); else unknown.
    static func accountFact(accountID: String, name: String, ownerAccountID: String,
                            refused: Set<String>) -> ZoomSignInCheckFact {
        if !accountID.isEmpty, refused.contains(accountID) { return .refused(account: name) }
        let owner = ownerAccountID.trimmingCharacters(in: .whitespaces)
        if owner.isEmpty || accountID.isEmpty { return .ownerUnknown(account: name) }
        return owner == accountID ? .sameAsApp : .otherThanApp(account: name)
    }

    /// Without a working token or account nothing after it can be tried.
    static func stopsTheRest(_ step: ZoomSignInCheckStep) -> Bool { step == .token || step == .profile }

    /// The `appKey` claim of a Meeting SDK JWT (read, not verified: Zoom verifies it).
    static func appKey(inJWT jwt: String) -> String? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let key = json["appKey"] as? String, !key.isEmpty else { return nil }
        return key
    }

    private static func sentence(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasSuffix(".") ? t : t + "."
    }
}
