//
//  MeetingShrinkRules.swift
//  Greenroom
//
//  The pure decisions behind "shrink the meeting window to the Mini":
//  what the yellow traffic light and the minimise shortcut do, and when the
//  one-time tip under the top bar's "Mini" button is shown. Foundation
//  only, so the test target compiles this file as it is.
//
import Foundation

/// What the meeting window's minimise button (and Command-M) does.
enum MeetingMinimize {
    enum Outcome: Equatable {
        /// Run the shrink-to-control-bar morph; the window is not sent to the Dock.
        case shrinkToControlBar
        /// An ordinary minimise.
        case minimize
    }

    /// While a meeting is live and this is the full meeting window (the morph has
    /// a window to hide and a bar to land on), minimise shrinks. Otherwise it
    /// behaves as any window's does: a meeting that has ended must not leave a
    /// window that cannot go to the Dock.
    static func outcome(meetingLive: Bool, canShrink: Bool) -> Outcome {
        meetingLive && canShrink ? .shrinkToControlBar : .minimize
    }
}

/// The first-time callout under the top bar's "Mini" button. Remembered
/// per Mac, in UserDefaults: it is gone for good once the teacher shrinks the
/// meeting once (by any route) or closes the tip.
enum MeetingShrinkTip {
    static let defaultsKey = "meetingShrinkTip.done"

    static func isDone(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: defaultsKey) }

    /// Whether to show the tip: the window has a Mini button and it has
    /// not been shrunk or dismissed before on this Mac.
    static func shouldShow(canShrink: Bool, defaults: UserDefaults = .standard) -> Bool {
        canShrink && !isDone(defaults)
    }

    /// The teacher shrank the meeting, or closed the tip.
    static func markDone(_ defaults: UserDefaults = .standard) { defaults.set(true, forKey: defaultsKey) }

    #if DEBUG
    /// DEBUG only: shows the tip again. Also reachable as the DebugTour command
    /// `resetMeetingTip`, or `defaults delete <bundle id> meetingShrinkTip.done`.
    static func reset(_ defaults: UserDefaults = .standard) { defaults.removeObject(forKey: defaultsKey) }
    #endif

    /// The tip's words; `shortcut` is the bound combination's glyphs, empty if cleared.
    static func message(shortcut: String) -> String {
        let base = "Shrink to the Mini window to get back to your slides."
        return shortcut.isEmpty ? base : base + " " + shortcut
    }
}
