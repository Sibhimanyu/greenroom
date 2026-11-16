import Foundation

/// Pure timing for subscription requests, so it can be tested.
struct SubscribeBackoff {
    private(set) var attempts = 0
    private var lastFailure: Date?

    /// A run of refusals is one problem: 2, 4, 8, 16, 32s, then hold. A quiet
    /// minute starts again from 2s.
    mutating func failed(at now: Date) -> (attempts: Int, delay: TimeInterval) {
        let continuing = lastFailure.map { now.timeIntervalSince($0) < 60 } ?? false
        attempts = continuing ? attempts + 1 : 1
        lastFailure = now
        return (attempts, min(32, pow(2.0, Double(min(attempts, 5)))))
    }

    mutating func reset() { attempts = 0; lastFailure = nil }
}

/// What one render element has asked for and what it has shown, for the
/// recovery rule below. One per element: a fresh element starts a fresh watch.
struct ElementWatch {
    /// The element's one subscribeVideo(YES) was made and has not been refused.
    var subscribed = false
    var subscribedAt: Date?
    /// Refused: the element is retired for a fresh one at this time.
    var refusedUntil: Date?
    var lastRefusalAt: Date?
    /// The SDK said video (camera on) while this element held the subscription.
    var expectingVideoSince: Date?
    /// A fresh element waits this long before asking, so it never follows the
    /// unsubscribe of the one it replaced in the same breath.
    var notBefore = Date.distantPast
    var lastSublayers = -2
    var drawingSince: Date?

    /// One subscribe produces two or three refusals at the same instant
    /// (the log, every time). They are one event, not three.
    func isRepeatRefusal(at now: Date) -> Bool {
        lastRefusalAt.map { now.timeIntervalSince($0) < 1 } ?? false
    }
}

/// The rule the 2026-11-16 logs taught: a normal video element is subscribed
/// exactly ONCE. Asking an element that already holds a subscription again
/// (the camera-came-on re-ask, the on-screen re-ask, a retry on the same
/// element after a refusal) is refused with code 7 TooFrequentCall every
/// time, however far apart: 6 in a row from 2s to 32s apart at 17:05. So is a
/// second element asking for a remote user another element already holds
/// (every view-window subscription on 2026-11-13 and 08:12 today). Recovery is
/// therefore a FRESH element, never a second subscribe on the same one.
enum ElementRecovery {
    enum Action: Equatable {
        /// Drawing, or nothing to draw yet (camera off, not subscribed).
        case fine
        /// A problem, but its time has not come.
        case wait
        /// Retire this element and make a fresh one.
        case rebuild
        /// Fresh elements have not helped; stop and say so.
        case giveUp
    }

    /// How long the SDK may report video without anything drawing.
    static let grace: TimeInterval = 3
    /// Fresh elements per run. A camera toggle or a new person starts a new run.
    static let maxRebuilds = 3
    /// Between retiring an element and its replacement asking.
    static let freshDelay: TimeInterval = 1.5

    static func decide(drawing: Bool, watch: ElementWatch, now: Date, rebuilds: Int) -> Action {
        if drawing { return .fine }
        if let until = watch.refusedUntil {
            guard now >= until else { return .wait }
        } else if watch.subscribed, let since = watch.expectingVideoSince {
            guard now.timeIntervalSince(since) >= grace else { return .wait }
        } else {
            return .fine
        }
        return rebuilds >= maxRebuilds ? .giveUp : .rebuild
    }

    /// Whether the element may make its one subscribe now.
    static func mayAsk(watch: ElementWatch, gaveUp: Bool, now: Date) -> Bool {
        !watch.subscribed && watch.refusedUntil == nil && !gaveUp && now >= watch.notBefore
    }
}
