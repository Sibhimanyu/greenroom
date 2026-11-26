//
//  ZoomSetupChecker.swift
//  Greenroom
//
//  "Check Zoom setup": tries both of your own Zoom apps (the Meeting SDK key
//  and secret, then the Server-to-Server app, its scopes, the meeting list and
//  the host key) and fills one ZoomCheckLine per check. Nothing is created or
//  ended. One checker, owned by the coordinator, so the setup guide and
//  Settings -> Zoom run and show the same thing (it lived inside the setup
//  guide's view until Settings needed it too, owner 2026-11-26).
//
import Foundation

@MainActor
final class ZoomSetupChecker: ObservableObject {
    @Published private(set) var lines: [ZoomCheckLine] = []
    @Published private(set) var isRunning = false
    @Published var showing = false

    static let footnote = "Scope checks read Zoom\u{2019}s granted permissions. Creating, joining and ending a real meeting are still tested when you start a meeting."

    /// The five values the check reads: SDK ID, SDK secret, S2S account, S2S ID, S2S secret.
    typealias Credentials = [String]

    enum Check: String, CaseIterable {
        case sdk, account, create, list, details, update, delete, host, end, meetings, hostToken
        var title: String {
            switch self {
            case .sdk: "Meeting and chat credentials"
            case .account: "Hosting credentials and app activation"
            case .create: "Permission to create meetings"
            case .list: "Permission to list meetings"
            case .details: "Permission to read meeting details"
            case .update: "Permission to edit scheduled meetings"
            case .delete: "Permission to delete scheduled meetings"
            case .host: "Permission to get the hosting token"
            case .end: "Permission to end meetings"
            case .meetings: "Scheduled meetings API"
            case .hostToken: "Hosting token API"
            }
        }
    }

    /// The keys changed: old results no longer describe them.
    func credentialsChanged() {
        if !isRunning { lines = [] }
    }

    /// `current` is read again at the end: edits made while the check ran invalidate it.
    func run(client: ZoomMeetingSDKClient, current: @escaping () -> Credentials) {
        guard !isRunning else { return }
        isRunning = true
        lines = Check.allCases.map { ZoomCheckLine(id: $0.rawValue, title: $0.title) }
        let credentials = current()
        let (sdkID, sdkSecret, account, clientID, secret) = (credentials[0], credentials[1], credentials[2], credentials[3], credentials[4])
        ids = ZoomCheckActionContext(sdkClientID: sdkID, s2sClientID: clientID)
        Task { @MainActor in
            defer {
                isRunning = false
                if current() != credentials {
                    for check in Check.allCases {
                        update(check, .skipped, "Zoom details changed during the check. Check again to verify the new values.")
                    }
                }
            }
            if sdkID.isEmpty || sdkSecret.isEmpty {
                update(.sdk, .failed, "Add both General App values under Meeting and chat.", .badCredentials)
            } else {
                update(.sdk, .running, "Authenticating with the Zoom Meeting SDK\u{2026}")
                do {
                    try await client.ensureReady(clientID: sdkID, clientSecret: sdkSecret, forceAuthentication: true)
                    update(.sdk, .passed, "Zoom accepted the General App credentials.")
                } catch {
                    update(.sdk, .failed, "\(error.localizedDescription) Check the General App credentials and that Meeting SDK is enabled.",
                           Self.sdkProblem(error))
                }
            }
            guard !account.isEmpty && !clientID.isEmpty && !secret.isEmpty else {
                update(.account, .failed, "Add all three Server-to-Server app values under Create and host meetings.", .badCredentials)
                skipHosting("Add hosting credentials, then check again.")
                return
            }
            update(.account, .running, "Checking the Server-to-Server app with Zoom\u{2026}")
            do {
                let scopes = try await ZoomServerToServerClient.grantedScopes(accountID: account, clientID: clientID, clientSecret: secret)
                update(.account, .passed, "Zoom issued an access token. The hosting app is active.")
                for scope in ZoomScopes.all {
                    let granted = ZoomScopes.isGranted(scope, in: scopes)
                    guard let check = Check(rawValue: scope.key.rawValue) else { continue }
                    update(check, granted ? .passed : .failed,
                           granted ? "Granted by Zoom." : "Missing \(scope.name). Add it in the Server-to-Server app\u{2019}s Scopes page, save, and check again.",
                           granted ? .nothing : .missingScopes([scope.name]))
                }
            } catch {
                update(.account, .failed, "\(error.localizedDescription) Check the three hosting values and activate the app in Zoom.",
                       ZoomCheckActionRules.problem(error.localizedDescription, ZoomCheckActionRules.isNetwork(error)))
                skipHosting("Hosting authentication failed. Fix it, then check again.")
                return
            }
            update(.meetings, .running, "Loading scheduled meetings\u{2026}")
            do {
                let list = try await ZoomServerToServerClient.listScheduledMeetings(accountID: account, clientID: clientID, clientSecret: secret)
                if let warning = list.warning {
                    update(.meetings, .failed, warning)
                } else {
                    update(.meetings, .passed, "Zoom returned \(list.meetings.count) scheduled meeting(s).")
                }
            } catch { update(.meetings, .failed, error.localizedDescription, Self.callProblem(error)) }
            update(.hostToken, .running, "Requesting the hosting token\u{2026}")
            do {
                let token = try await ZoomServerToServerClient.fetchZAK(accountID: account, clientID: clientID, clientSecret: secret)
                update(.hostToken, token.isEmpty ? .failed : .passed,
                       token.isEmpty ? "Zoom returned an empty hosting token." : "Zoom returned a hosting token. No meeting was started.")
            } catch { update(.hostToken, .failed, error.localizedDescription, Self.callProblem(error)) }
        }
    }

    /// The client IDs the buttons' tooltips name the apps by.
    private var ids = ZoomCheckActionContext()

    private func update(_ check: Check, _ status: ZoomCheckStatus, _ detail: String,
                        _ problem: ZoomCheckProblem = .nothing) {
        guard let i = lines.firstIndex(where: { $0.id == check.rawValue }) else { return }
        lines[i].status = status
        lines[i].detail = detail
        lines[i].actions = ZoomCheckActionRules.buttons(.ownApps, check: check.rawValue, status: status,
                                                        problem: problem, ids: ids)
    }

    /// The Meeting SDK said no: offline or no answer is the network; else the keys.
    private static func sdkProblem(_ error: Error) -> ZoomCheckProblem {
        if ZoomCheckActionRules.isNetwork(error) { return .network }
        if case ZoomMeetingSDKError.timedOut = error { return .network }
        return .badCredentials
    }

    /// A REST call after the token: only an outage has a button (Check again);
    /// a missing scope already has its own line.
    private static func callProblem(_ error: Error) -> ZoomCheckProblem {
        switch ZoomCheckActionRules.problem(error.localizedDescription, ZoomCheckActionRules.isNetwork(error)) {
        case .network: return .network
        case .zoomDown: return .zoomDown
        default: return .other
        }
    }

    private func skipHosting(_ reason: String) {
        for check in Check.allCases where check != .sdk && check != .account {
            update(check, .skipped, reason)
        }
    }
}
