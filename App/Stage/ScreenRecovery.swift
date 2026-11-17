//
//  ScreenRecovery.swift
//  Greenroom
//
//  What to do when the screen capture can't start or is ended by macOS (the
//  display asleep, the Mac locked, code -3815). Pure: no clock, no logging, no
//  ScreenCaptureKit. The compositor feeds it what happened and does what it says.
//
//  One log line when the capture is first lost, one when it is back, nothing
//  between: a night of sleep is a counter, not 600 lines.
//
import Foundation

struct ScreenRecovery: Equatable {

    /// How long to wait before asking again.
    static let retryInterval: TimeInterval = 5

    struct Decision: Equatable {
        /// Ask again after this many seconds; nil means stop asking.
        var retryIn: TimeInterval?
        /// A line for the session log, or nil to stay quiet.
        var logLine: String?
    }

    /// Failures in the current outage; 0 when the capture is up.
    private(set) var failures = 0

    /// True from the first failure until the capture is back.
    var inOutage: Bool { failures > 0 }

    /// The capture failed to start, or macOS ended it.
    /// - `permission`: Screen Recording is off or declined. Waiting won't fix it.
    /// - `choiceStands`: the person's screen choice is still the one being served.
    mutating func failed(_ reason: String, permission: Bool, choiceStands: Bool) -> Decision {
        guard choiceStands, !permission else {
            // Someone else's problem now (a new choice, or a permission the
            // person must grant): no retry, and the next outage starts afresh.
            failures = 0
            return Decision(retryIn: nil, logLine: nil)
        }
        failures += 1
        let first = failures == 1
        return Decision(retryIn: Self.retryInterval,
                        logLine: first ? "Screen capture lost: \(reason). Trying again every \(Int(Self.retryInterval)) s until it is back." : nil)
    }

    /// The capture is delivering frames. One line, and only if it had been lost.
    mutating func recovered() -> String? {
        guard failures > 0 else { return nil }
        let n = failures
        failures = 0
        return "Screen capture back (after \(n) attempt\(n == 1 ? "" : "s"))."
    }

    /// The choice changed or the picture was stopped: forget the outage.
    mutating func reset() { failures = 0 }
}
