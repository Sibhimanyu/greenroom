//
//  ZoomSignInChecker.swift
//  Greenroom
//
//  "Check sign-in": tries what Start will need from Sign in with Zoom, in
//  Start's order, and fills one ZoomCheckLine per step (words in
//  ZoomSetupCheckRules). Nothing is created or started: the host key and the
//  SDK key are fetched and dropped; creating a meeting is left to Start
//  because Zoom has no dry run for it.
//
import Foundation

@MainActor
final class ZoomSignInChecker: ObservableObject {
    @Published private(set) var lines: [ZoomCheckLine] = []
    @Published private(set) var isRunning = false
    @Published var showing = false

    func run(user: ZoomUserAuth, endpoint: String, refused: Set<String>) {
        guard !isRunning else { return }
        isRunning = true
        lines = ZoomSignInCheckStep.allCases.map { ZoomCheckLine(id: $0.rawValue, title: $0.title) }
        Task { @MainActor in
            defer { isRunning = false }
            for step in ZoomSignInCheckStep.allCases {
                set(step, ZoomCheckLine(id: step.rawValue, title: step.title, status: .running, detail: "Checking\u{2026}"))
                let (fact, error) = await check(step, user: user, endpoint: endpoint, refused: refused)
                set(step, ZoomSignInCheckRules.line(step, fact, error: error))
                if case .failed = fact, ZoomSignInCheckRules.stopsTheRest(step) {
                    for later in ZoomSignInCheckStep.allCases.drop(while: { $0 != step }).dropFirst() {
                        set(later, ZoomSignInCheckRules.line(later, .skipped))
                    }
                    return
                }
            }
        }
    }

    private func set(_ step: ZoomSignInCheckStep, _ line: ZoomCheckLine) {
        guard let i = lines.firstIndex(where: { $0.id == step.rawValue }) else { return }
        lines[i] = line
    }

    private func check(_ step: ZoomSignInCheckStep, user: ZoomUserAuth, endpoint: String,
                       refused: Set<String>) async -> (ZoomSignInCheckFact, Error?) {
        do {
            return (try await fact(step, user: user, endpoint: endpoint, refused: refused), nil)
        } catch {
            return (.failed(error.localizedDescription), error)
        }
    }

    private func fact(_ step: ZoomSignInCheckStep, user: ZoomUserAuth, endpoint: String,
                      refused: Set<String>) async throws -> ZoomSignInCheckFact {
        switch step {
        case .token:
            try await user.renewTokenNow()
            return .ok("")
        case .profile:
            let p = try await user.loadProfile()
            return .ok(ZoomSignInInfoLine.make(name: p.name, email: p.email))
        case .scopes:
            switch ZoomScopeCheck.check(required: ZoomOAuth.requiredScopes, granted: user.grantedScopes) {
            case .ok: return .ok("")
            case .unknown: return .unknown
            case .needsMore(let gap): return .missingScopes(gap)
            }
        case .zak:
            let zak = try await user.zak()
            return zak.isEmpty ? .failed("Zoom returned an empty host key.") : .ok("")
        case .signature:
            let jwt = try await user.sdkSignature(endpoint: endpoint)
            guard let key = ZoomSignInCheckRules.appKey(inJWT: jwt) else {
                return .failed("the answer wasn\u{2019}t a Meeting SDK key")
            }
            return .ok(ZoomRouteWords.clientIDTail(key))
        case .create:
            return .atStart
        case .account:
            let p = user.profile
            let name = (p?.name ?? "").isEmpty ? (p?.email ?? "") : (p?.name ?? "")
            return ZoomSignInCheckRules.accountFact(accountID: p?.accountID ?? "", name: name,
                                                    ownerAccountID: ZoomOAuth.appOwnerAccountID, refused: refused)
        }
    }
}

/// "Name · email", or whichever half exists (the same as ZoomSignInInfo.line).
enum ZoomSignInInfoLine {
    static func make(name: String, email: String) -> String {
        [name, email].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }
}
