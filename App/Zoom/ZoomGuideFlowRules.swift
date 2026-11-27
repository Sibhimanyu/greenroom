//
//  ZoomGuideFlowRules.swift
//  Greenroom
//
//  The setup guide's Zoom step as a guided flow (owner, 2026-11-26): your
//  own Zoom apps are THE path, in three numbered parts (Meeting app, Hosting
//  app, Check), each with its own state. Only the current part is open; done
//  parts fold to one line. This file decides each part's state, which part is
//  open, the footer's plain note when Zoom isn't connected yet, and where
//  Settings' one button ("Set up…" / "Edit setup…") and the check's "Show
//  me where" land. Pure: Foundation only.
//
import Foundation

/// The numbered parts of the Zoom step, in order.
enum ZoomGuidePart: Int, CaseIterable, Equatable, Hashable {
    case meetingApp, hostingApp, check

    var number: Int { rawValue + 1 }

    var title: String {
        switch self {
        case .meetingApp: return "Meeting app"
        case .hostingApp: return "Hosting app"
        case .check: return "Check"
        }
    }

    /// Zoom's name for it, under the title.
    var subtitle: String {
        switch self {
        case .meetingApp: return "A General App with Meeting SDK turned on"
        case .hostingApp: return "A Server-to-Server OAuth app"
        case .check: return "Make sure both apps work"
        }
    }
}

enum ZoomGuidePartState: Equatable { case notStarted, inProgress, done }

/// The last "Check Zoom setup", as the flow sees it.
enum ZoomGuideCheckState: Equatable { case notRun, running, passed, failed }

struct ZoomGuideFlowFacts: Equatable {
    /// Meeting SDK fields filled in: Client ID, Client Secret (0...2).
    var sdkFilled: Int
    /// Server-to-Server fields filled in: Account ID, Client ID, Client Secret (0...3).
    var s2sFilled: Int
    var check: ZoomGuideCheckState
    /// The last check found something to fix in the Meeting SDK app (its keys).
    var meetingAppNeedsFix = false
    /// The last check found something to fix in the Server-to-Server app (keys, scopes, activation).
    var hostingAppNeedsFix = false

    var anythingFilled: Bool { sdkFilled > 0 || s2sFilled > 0 }
}

struct ZoomGuideFlow: Equatable {
    var meetingApp: ZoomGuidePartState
    var hostingApp: ZoomGuidePartState
    var check: ZoomGuidePartState
    /// The current part, open; nil when everything is done and checked.
    var open: ZoomGuidePart?
    /// The footer's line beside Next when Zoom isn't connected yet; nil when the check passed.
    var footerNote: String?

    func state(_ part: ZoomGuidePart) -> ZoomGuidePartState {
        switch part {
        case .meetingApp: return meetingApp
        case .hostingApp: return hostingApp
        case .check: return check
        }
    }
}

/// Settings -> Zoom's one button into the guide.
struct ZoomSetupEntry: Equatable {
    var title: String
    var spot: ZoomGuideSpot
}

enum ZoomGuideFlowRules {
    static func flow(_ f: ZoomGuideFlowFacts) -> ZoomGuideFlow {
        let meeting = appState(filled: f.sdkFilled, of: 2, needsFix: f.meetingAppNeedsFix)
        let hosting = appState(filled: f.s2sFilled, of: 3, needsFix: f.hostingAppNeedsFix)
        let check: ZoomGuidePartState
        switch f.check {
        case .notRun: check = .notStarted
        case .running, .failed: check = .inProgress
        case .passed: check = .done
        }
        let open: ZoomGuidePart?
        if meeting != .done { open = .meetingApp }
        else if hosting != .done { open = .hostingApp }
        else if check != .done { open = .check }
        else { open = nil }
        let note: String?
        if f.check == .passed { note = nil }
        else if meeting == .done && hosting == .done && f.check == .notRun { note = notCheckedNote }
        else { note = notConnectedNote }
        return ZoomGuideFlow(meetingApp: meeting, hostingApp: hosting, check: check, open: open, footerNote: note)
    }

    /// The small status beside a part's title.
    static func label(_ part: ZoomGuidePart, _ f: ZoomGuideFlowFacts) -> String {
        let state = flow(f).state(part)
        switch part {
        case .meetingApp, .hostingApp:
            let fix = part == .meetingApp ? f.meetingAppNeedsFix : f.hostingAppNeedsFix
            switch state {
            case .notStarted: return "Not started"
            case .inProgress: return fix ? "Needs a fix" : "In progress"
            case .done: return "Done"
            }
        case .check:
            switch f.check {
            case .notRun: return "Not run yet"
            case .running: return "Checking\u{2026}"
            case .failed: return "Needs a fix"
            case .passed: return "Passed"
            }
        }
    }

    /// What Settings' button says; it opens the guide's Zoom step at its top.
    static func setupEntry(_ f: ZoomGuideFlowFacts) -> ZoomSetupEntry {
        let flow = flow(f)
        let title: String
        if !f.anythingFilled { title = "Set up Zoom\u{2026}" }
        else if flow.meetingApp != .done || flow.hostingApp != .done { title = "Continue setup\u{2026}" }
        else { title = "Edit setup\u{2026}" }
        // Always the step's top: that is where the one button is (the keys are a deep link of their own).
        return ZoomSetupEntry(title: title, spot: .zoomStep)
    }

    /// The part a deep link opens; nil for the step's top (the flow's own open part).
    static func part(for spot: ZoomGuideSpot) -> ZoomGuidePart? {
        switch spot {
        case .zoomStep: return nil
        case .sdkCredentials: return .meetingApp
        case .s2sCredentials, .s2sScopes, .s2sActivation: return .hostingApp
        }
    }

    /// The facts from the fields and the last check's lines. A failed line
    /// whose fix is in one app (its keys, scopes or activation) marks that
    /// app; a failure with nothing to fix in either (offline, Zoom down) marks neither.
    static func facts(sdkFields: [String], s2sFields: [String], lines: [ZoomCheckLine], running: Bool) -> ZoomGuideFlowFacts {
        func filled(_ fields: [String]) -> Int {
            fields.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        }
        let failed = lines.filter { $0.status == .failed }
        func fixesIn(_ app: ZoomOwnApp) -> Bool {
            failed.contains { line in
                line.actions.contains { button in
                    switch button.action {
                    case .openAppCredentials(let a), .openApp(let a): return a == app
                    case .copyScope, .openScopesPage: return app == .s2s
                    default: return false
                    }
                }
            }
        }
        let check: ZoomGuideCheckState = running ? .running
            : lines.isEmpty ? .notRun
            : failed.isEmpty ? .passed : .failed
        return ZoomGuideFlowFacts(sdkFilled: filled(sdkFields), s2sFilled: filled(s2sFields), check: check,
                                  meetingAppNeedsFix: fixesIn(.sdk) && filled(sdkFields) > 0, hostingAppNeedsFix: fixesIn(.s2s) && filled(s2sFields) > 0)
    }

    static let notConnectedNote = "Zoom isn\u{2019}t connected yet; you can finish this later in Settings \u{2192} Zoom."
    static let notCheckedNote = "Zoom is set up. Run Check Zoom setup to make sure it works."

    private static func appState(filled: Int, of total: Int, needsFix: Bool) -> ZoomGuidePartState {
        if needsFix { return .inProgress }
        if filled <= 0 { return .notStarted }
        return filled >= total ? .done : .inProgress
    }
}

/// What the guide needs to know about the Zoom window, as plain values (the render feeds samples).
struct ZoomGuideAssistState: Equatable {
    var page: ZoomMarketplacePage?
    var ids = ZoomAppIDs()
    /// Where setup stands now (the step `ZoomSetupFlow` returned for the page last read); nil before the window has looked.
    var step: SetupStep?
    /// Parts whose keys were just removed by "Use a different app" ("Keys removed", with Undo).
    var removed: Set<ZoomGuidePart> = []
}

/// The Connect Zoom step's words and small decisions (the steps themselves come from `ZoomSetupFlow`).
enum ZoomConnect {
    static let intro = "Greenroom needs two small apps in your Zoom account. Set up for me builds both and copies the keys. Or follow the steps yourself; Greenroom shows each click."
    static let manualTitle = "Enter the keys yourself"

    /// The first unfinished part (Meeting app first); nil once both are done.
    static func nextPart(_ f: ZoomGuideFlowFacts) -> ZoomGuidePart? {
        let flow = ZoomGuideFlowRules.flow(f)
        if flow.meetingApp != .done { return .meetingApp }
        if flow.hostingApp != .done { return .hostingApp }
        return nil
    }

    /// Where "Guide me instead" opens the window: Created apps, or the remembered app's next page.
    static func entryPage(_ part: ZoomGuidePart, ids: ZoomAppIDs, filled: Int) -> ZoomMarketplacePage {
        switch part {
        case .meetingApp:
            guard let id = ids.meeting else { return .createdApps }
            return .general(id, filled > 0 ? .information : .embed)
        case .hostingApp:
            guard let id = ids.hosting else { return .createdApps }
            return .s2s(id, filled > 0 ? .credentials : .scopes)
        case .check:
            return .createdApps
        }
    }

    static func showsCheckRow(_ f: ZoomGuideFlowFacts) -> Bool {
        let flow = ZoomGuideFlowRules.flow(f)
        return (flow.meetingApp == .done && flow.hostingApp == .done) || f.check != .notRun
    }

    /// A deep link to the keys, scopes or activation unfolds the manual route.
    static func opensManual(_ spot: ZoomGuideSpot) -> Bool { spot != .zoomStep }

    /// The "..." menu's shortcuts on a part's line: only the pages whose app ID is known.
    static func shortcuts(_ part: ZoomGuidePart, ids: ZoomAppIDs) -> [(title: String, page: ZoomMarketplacePage)] {
        switch part {
        case .meetingApp:
            guard let id = ids.meeting else { return [] }
            return [("Open Embed", .general(id, .embed)), ("Open Basic information", .general(id, .information))]
        case .hostingApp:
            guard let id = ids.hosting else { return [] }
            return [("Open Scopes", .s2s(id, .scopes)), ("Open Activation", .s2s(id, .activation)), ("Open App Credentials", .s2s(id, .credentials))]
        case .check:
            return []
        }
    }
}
