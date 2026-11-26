//
//  StartChoreography.swift
//  Greenroom
//
//  Starting a meeting is one smooth movement (owner, 2026-11-20): Home steps
//  aside at the click, the island (the notch status surface) is the only
//  status surface while the meeting comes up, with its step, progress and
//  Cancel, and the floating Control bar first appears when the meeting is
//  live (or the Meeting window takes over). These are the
//  decisions behind it, with no AppKit, so the test target compiles this file
//  as it is. The coordinator and the bar turn them into windows.
//
import CoreGraphics
import Foundation

enum StartChoreography {

    /// Where a start is. `failed` covers a failure and a cancel: both put Home back.
    enum Phase: Equatable { case idle, starting, live, failed }

    /// Which surface shows in a phase.
    struct Surfaces: Equatable {
        var home: Bool
        /// The floating Control bar. Never while starting: it is the live surface.
        var bar: Bool
        /// The notch island's start status (steps, Cancel, or a failure).
        var island: Bool
    }

    /// One surface says what is happening, never two. Starting: the island
    /// alone. Live: the bar alone (the island folds without a "Live" beat).
    /// A failure: the island keeps the message with Try again and Close, and
    /// Home is back.
    static func surfaces(_ phase: Phase) -> Surfaces {
        switch phase {
        case .idle: return Surfaces(home: true, bar: false, island: false)
        case .starting: return Surfaces(home: false, bar: false, island: true)
        case .live: return Surfaces(home: false, bar: true, island: false)
        case .failed: return Surfaces(home: true, bar: false, island: true)
        }
    }

    /// The island offers Cancel while a meeting starts: the one way out of a
    /// start in flight (the bar is not there yet). A Record start has its own
    /// countdown Cancel and no meeting to abandon, so it shows none.
    static func islandShowsCancel(_ phase: Phase, recordStart: Bool) -> Bool {
        phase == .starting && !recordStart
    }

    /// The words in the bar while it starts (dormant: the bar no longer shows
    /// a Starting state; the island says the step). Plain, no step names.
    enum BarStage: Equatable { case starting, joining }

    static func barText(_ stage: BarStage) -> String {
        switch stage {
        case .starting: return "Starting\u{2026}"
        case .joining: return "Joining\u{2026}"
        }
    }

    /// Waiting for the screens to be quiet guards opening apps and placing
    /// windows against a changing arrangement. A start that does neither has
    /// nothing to protect, so it does not wait (up to 6 s before).
    static func needsDisplayQuiet(opensApps: Bool, arranges: Bool) -> Bool {
        opensApps || arranges
    }

    // MARK: How a meeting start ends

    /// What the start knows when its steps clear.
    enum Ending: Equatable {
        /// The start ran to its end. `inMeeting`: Zoom's own status is InMeeting right
        /// now (the meeting did not end, or fail, while the last steps ran).
        case live(inMeeting: Bool)
        /// A step failed, with the words to show.
        case failed(String)
        /// Cancel, or End while it was starting.
        case cancelled
    }

    /// What the island does once the start's steps clear.
    enum IslandEnd: Equatable {
        /// The Live beat, then fold.
        case live
        /// The failed step in red with this reason, Try again and Close.
        case failed(String)
        /// Fold with no beat.
        case fold
    }

    static func islandEnd(_ ending: Ending) -> IslandEnd {
        switch ending {
        case .live(let inMeeting): return inMeeting ? .live : .failed(meetingEndedWhileStarting)
        case .failed(let reason): return .failed(reason)
        case .cancelled: return .fold
        }
    }

    /// What a start that did not go live takes down.
    struct Teardown: Equatable {
        /// Greenroom's Meeting window, wherever it opened.
        var closesMeetingWindow: Bool
        /// The one-second loop that draws (and would reopen) the Meeting window.
        var stopsFollowLoop: Bool
        /// The island keeps the failure on screen for the person to read.
        var keepsIslandFailure: Bool
    }

    static func teardown(_ ending: Ending) -> Teardown {
        switch ending {
        // The Meeting window has no readiness card (2026-11-24): the island carries the
        // failure, so nothing is left up to show it. A window left open on a second
        // display, with its loop still drawing it, was the first-run bug of 2026-11-26.
        case .failed: return Teardown(closesMeetingWindow: true, stopsFollowLoop: true, keepsIslandFailure: true)
        case .cancelled, .live: return Teardown(closesMeetingWindow: true, stopsFollowLoop: true, keepsIslandFailure: false)
        }
    }

    /// Whether the Meeting window may open before the meeting is live. Never: while
    /// starting the island is the one surface (`surfaces(.starting)`), and a window
    /// opened early is one a failure has to find again. `layoutFillsADisplay` (the
    /// layout's Meeting fills a connected display) used to open it at the click.
    static func opensMeetingWindowWhileStarting(layoutFillsADisplay: Bool) -> Bool {
        false
    }

    /// The island carries the start's reading (its steps, or its failure).
    /// `meetingWindowOpen`: Greenroom's Meeting window is on screen;
    /// `layoutHasMeetingDisplay`: the layout fills a connected display with the Meeting.
    /// Always, for a meeting start: the Meeting window lost its readiness card on
    /// 2026-11-24, so when the island stepped aside for it (an arranged layout with a
    /// Meeting display, or the window open) the failure was shown nowhere.
    static func islandCarriesReading(failed: Bool, arranged: Bool, layoutHasMeetingDisplay: Bool,
                                     meetingWindowOpen: Bool) -> Bool {
        true
    }

    /// Zoom said the meeting is over.
    enum MeetingEndedAction: Equatable {
        /// The start in flight reports it as its failure, in words.
        case startReportsIt
        /// A live meeting ended: wind the session down.
        case endSession
    }

    static func meetingEnded(startInFlight: Bool) -> MeetingEndedAction {
        startInFlight ? .startReportsIt : .endSession
    }

    /// The failure when a start reached its end but Zoom no longer has the meeting.
    static let meetingEndedWhileStarting = "Zoom ended the meeting just as it started. Nothing was left running. Press Try again."

    /// The Picture step fails, in words, when what it needs is not there.
    /// `wantsScreen`: the share captures the screen; `screenRecordingGranted`: macOS says yes.
    static func screenRecordingFailure(wantsScreen: Bool, screenRecordingGranted: Bool) -> String? {
        guard wantsScreen, !screenRecordingGranted else { return nil }
        return "Greenroom can\u{2019}t share your screen yet: Screen Recording is off. Turn Greenroom on in System Settings \u{2192} Privacy & Security \u{2192} Screen Recording, then press Try again. If it still says this, quit and reopen Greenroom first. To start with your camera only, set What\u{2019}s shared to Nothing or Whiteboard."
    }

    /// No composited frame at all came within the wait: the meeting would get nothing.
    static func pictureFailure(gotFrame: Bool, waitedSeconds: Int) -> String? {
        guard !gotFrame else { return nil }
        return "Greenroom\u{2019}s picture did not come up in \(waitedSeconds) seconds, so the meeting would have had no video. Check that Greenroom may use the camera (System Settings \u{2192} Privacy & Security \u{2192} Camera), then press Try again."
    }

    // MARK: Steps done only on proof

    /// Where a step stands against its proof.
    enum StepCheck: Equatable {
        case done
        /// Not yet; look again.
        case waiting
        /// The proof did not come: the step goes red with these words.
        case failed(String)
    }

    /// How long the Recording step waits for the first frame in the file.
    static let recordingProofSeconds: TimeInterval = 5

    /// The Recording step. `rolling`: the take began; `firstFrameWritten`: the
    /// encoder took a frame (the recorder's clock started); `waited`: seconds since
    /// the take was asked for.
    static func recordingStep(rolling: Bool, firstFrameWritten: Bool, waited: TimeInterval) -> StepCheck {
        if rolling && firstFrameWritten { return .done }
        guard waited >= recordingProofSeconds else { return .waiting }
        return .failed(rolling
            ? "The recording did not start: no picture reached the file in \(Int(recordingProofSeconds)) seconds. The meeting is live; press Record to try again."
            : "The recording did not start. The meeting is live; press Record to try again.")
    }

    // MARK: Geometry

    /// How long Home takes to step aside, and to come back.
    static let homeSeconds: TimeInterval = 0.25
    /// The bar while it starts: grip, spinner, words, Cancel.
    static let startingBarWidth: CGFloat = 228

    /// Where Home ends up as it hides: smaller, and part of the way to the bar,
    /// so it reads as the bar coming out of the window.
    static func homeExitFrame(home: CGRect, bar: CGRect) -> CGRect {
        let scale: CGFloat = 0.5
        let size = CGSize(width: (home.width * scale).rounded(), height: (home.height * scale).rounded())
        let travel: CGFloat = 0.6
        let centre = CGPoint(x: home.midX + (bar.midX - home.midX) * travel,
                             y: home.midY + (bar.midY - home.midY) * travel)
        return CGRect(x: (centre.x - size.width / 2).rounded(), y: (centre.y - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }
}
