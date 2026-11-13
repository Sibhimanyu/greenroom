//
//  LiveExitRules.swift
//  Greenroom
//
//  The pure decisions behind "never leave a live class with no way back":
//  what closing the meeting window and quitting the app offer while a session
//  is live, and where a Dock click, "Show Greenroom" or the menu bar's live
//  header takes you. Foundation only, so the test target compiles this file as
//  it is. The coordinator and the app delegate draw the prompts and act.
//
//  Zoom's own behaviour is the model: closing the meeting window asks
//  "End Meeting for All" / "Leave Meeting" before anything ends, and the
//  default answer is the one that loses nothing.
//
import Foundation

/// What is running, as plain values.
struct LiveExitState: Equatable {
    enum Kind: Equatable {
        /// Nothing live: closing and quitting need no question.
        case idle
        /// A Zoom meeting Greenroom created (the user is the host).
        case host
        /// A Zoom meeting Greenroom joined.
        case participant
        /// The Record view: no meeting, a camera and perhaps a tape.
        case recordOnly
    }
    var kind: Kind = .idle
    var isRecording = false
    /// The meeting window can be shrunk to the control bar (a custom-UI meeting
    /// with its window open).
    var canShrink = false

    var isLive: Bool { kind != .idle }
}

/// One button in a close or quit prompt.
enum LiveExitChoice: Equatable {
    case endMeetingForAll, leaveMeeting, shrinkToControlBar
    case endMeetingAndQuit, leaveAndQuit, stopRecordingAndQuit, quit
    case cancel

    var title: String {
        switch self {
        case .endMeetingForAll: return "End Meeting for All"
        case .leaveMeeting: return "Leave Meeting"
        case .shrinkToControlBar: return "Shrink to Control Bar"
        case .endMeetingAndQuit: return "End Meeting & Quit"
        case .leaveAndQuit: return "Leave & Quit"
        case .stopRecordingAndQuit: return "Stop Recording & Quit"
        case .quit: return "Quit Greenroom"
        case .cancel: return "Cancel"
        }
    }

    /// Ends something for somebody else (or stops a tape): drawn destructive.
    var isDestructive: Bool {
        switch self {
        case .endMeetingForAll, .leaveMeeting, .endMeetingAndQuit, .leaveAndQuit, .stopRecordingAndQuit: return true
        case .shrinkToControlBar, .quit, .cancel: return false
        }
    }
}

struct LiveExitPrompt: Equatable {
    var title: String
    var message: String
    /// In button order, first to last. Cancel is always last and is the default
    /// (Return and Escape): a teacher who hit the key by accident is the person
    /// about to hit Return by reflex, and that answer must lose nothing.
    var choices: [LiveExitChoice]
}

enum LiveExit {

    private static let recordingNote = "Recording will stop and be saved."

    /// The sheet shown when the meeting window's close button (or Command-W) is
    /// used. Nil when nothing is live: the window just closes.
    static func closePrompt(_ s: LiveExitState) -> LiveExitPrompt? {
        guard s.isLive else { return nil }
        switch s.kind {
        case .host:
            return LiveExitPrompt(
                title: "End the meeting for everyone?",
                message: join("Closing the window does not end the meeting. Shrink it to the control bar to keep going, or end it for all.",
                              s.isRecording ? recordingNote : nil),
                choices: withShrink([.endMeetingForAll], s) + [.cancel])
        case .participant:
            return LiveExitPrompt(
                title: "Leave the meeting?",
                message: join("Closing the window does not leave the meeting. Shrink it to the control bar to keep going, or leave.",
                              s.isRecording ? recordingNote : nil),
                choices: withShrink([.leaveMeeting], s) + [.cancel])
        case .recordOnly, .idle:
            // The Record studio is not a meeting window; it has no close prompt here.
            return nil
        }
    }

    /// The prompt for a quit (Command-Q, the app menu, the menu bar, the Dock).
    /// Nil when nothing is live, or when the system is ending the session
    /// (logout, shutdown, restart): that one must finish cleanly, never wait on
    /// a question nobody is there to answer.
    static func quitPrompt(_ s: LiveExitState, systemEnding: Bool = false) -> LiveExitPrompt? {
        guard s.isLive, !systemEnding else { return nil }
        switch s.kind {
        case .host:
            return LiveExitPrompt(
                title: "Quit Greenroom and end the meeting?",
                message: join("The meeting ends for everyone and your students are dropped from the call.",
                              s.isRecording ? recordingNote : nil),
                choices: [.endMeetingAndQuit, .cancel])
        case .participant:
            return LiveExitPrompt(
                title: "Quit Greenroom and leave the meeting?",
                message: join("You leave the meeting.", s.isRecording ? recordingNote : nil),
                choices: [.leaveAndQuit, .cancel])
        case .recordOnly:
            return LiveExitPrompt(
                title: s.isRecording ? "Quit Greenroom and stop recording?" : "Quit Greenroom?",
                message: s.isRecording ? "The recording is finished and saved first." : "The Record view closes.",
                choices: [s.isRecording ? .stopRecordingAndQuit : .quit, .cancel])
        case .idle:
            return nil
        }
    }

    private static func withShrink(_ first: [LiveExitChoice], _ s: LiveExitState) -> [LiveExitChoice] {
        s.canShrink ? first + [.shrinkToControlBar] : first
    }

    private static func join(_ a: String, _ b: String?) -> String {
        b.map { a + " " + $0 } ?? a
    }

    // MARK: System end

    /// The Apple event quit reasons ('why?' attribute of the quit event). Logout,
    /// shutdown and restart are system-driven: Greenroom ends cleanly and saves.
    static func isSystemEnd(quitReason: UInt32?) -> Bool {
        guard let quitReason else { return false }
        return [fourCC("quia"),   // kAEQuitAll: the system is quitting everything
                fourCC("rlgo"),   // kAEReallyLogOut
                fourCC("logo"),   // kAEShowRestartDialog / logout dialogs
                fourCC("shut"),   // kAEShutDown
                fourCC("rest"),   // kAERestart
                fourCC("rsdn"),   // kAEReallyShutDown
                fourCC("rrst")].contains(quitReason) // kAEReallyRestart
    }

    private static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    // MARK: Getting back

    /// What a Dock click, "Show Greenroom" or the menu bar's live header brings
    /// forward.
    enum ReopenTarget: Equatable {
        /// Greenroom's own meeting window (opened if it was closed).
        case meetingWindow
        /// The floating control bar, shrunk or the only surface left.
        case controlBar
        /// The main window, showing the live state.
        case mainWindow
    }

    struct ReopenState: Equatable {
        var isLive = false
        /// A custom-UI meeting: there is a meeting window and a control bar.
        var hasMeetingSurfaces = false
        /// The meeting window is hidden, shrunk to the bar or minimised.
        var meetingShrunk = false
    }

    static func reopenTarget(_ s: ReopenState) -> ReopenTarget {
        guard s.isLive, s.hasMeetingSurfaces else { return .mainWindow }
        return s.meetingShrunk ? .controlBar : .meetingWindow
    }

    /// Whether the app delegate has handled a reopen itself (so SwiftUI must not
    /// also open the main window on top of the meeting).
    static func reopenHandledByMeeting(_ s: ReopenState) -> Bool {
        s.isLive && s.hasMeetingSurfaces
    }
}
