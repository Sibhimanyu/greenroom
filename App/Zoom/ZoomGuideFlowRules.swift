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

    /// Where Settings' button opens the guide, and what it says: the first
    /// part that isn't done, or the step's top when both apps are.
    static func setupEntry(_ f: ZoomGuideFlowFacts) -> ZoomSetupEntry {
        let flow = flow(f)
        let spot: ZoomGuideSpot
        if flow.meetingApp != .done { spot = .sdkCredentials }
        else if flow.hostingApp != .done { spot = .s2sCredentials }
        else { spot = .zoomStep }
        return ZoomSetupEntry(title: f.anythingFilled ? "Edit setup\u{2026}" : "Set up\u{2026}", spot: spot)
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
                                  meetingAppNeedsFix: fixesIn(.sdk), hostingAppNeedsFix: fixesIn(.s2s))
    }

    static let notConnectedNote = "Zoom isn\u{2019}t connected yet; you can finish this later in Settings \u{2192} Zoom."
    static let notCheckedNote = "Zoom is set up. Run Check Zoom setup to make sure it works."

    private static func appState(filled: Int, of total: Int, needsFix: Bool) -> ZoomGuidePartState {
        if needsFix { return .inProgress }
        if filled <= 0 { return .notStarted }
        return filled >= total ? .done : .inProgress
    }
}
