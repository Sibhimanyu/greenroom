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

/// One place, app-wide, that spaces SDK subscription calls (setResolution,
/// subscribeVideo) so the stage, the view windows and the gallery tiles cannot
/// burst together: Zoom refuses a burst with code 7 TooFrequentCall, and the
/// 2026-11-23 log shows our own setResolution + retry + subscribe tripping it.
/// The SDK documents no number; half a second is what the tiles already used.
struct SubscribeThrottle {
    static let spacing: TimeInterval = 0.5
    private var nextAt = Date.distantPast

    /// True once per `spacing`, across every caller sharing this value.
    mutating func claim(at now: Date) -> Bool {
        guard now >= nextAt else { return false }
        nextAt = now.addingTimeInterval(Self.spacing)
        return true
    }
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
    /// A fresh element waits this long before asking, so it never follows the
    /// unsubscribe of the one it replaced in the same breath.
    var notBefore = Date.distantPast
    var lastSublayers = -2
    /// setResolution has gone in (accepted, or refused twice). It is its own
    /// paced step, ahead of the subscribe, never in the same breath.
    var resolutionSet = false
    var resolutionTries = 0
    var resolutionCode = 0
    /// The one retry of the subscribe on the SAME element has been used.
    var retried = false

    /// Video is showing: whatever refused it, it got there. Not a fault.
    mutating func recoveredByVideo() {
        subscribed = true
        refusedUntil = nil
    }

    /// Ask again on this same element (its one patient retry). The resolution
    /// already in force stays; only the subscribe goes in again.
    mutating func readyToRetry() {
        retried = true
        subscribed = false
        refusedUntil = nil
    }

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
        /// Not refused.
        case fine
        /// A problem, but its time has not come.
        case wait
        /// Refused, but the element is showing video: forget the refusal.
        case recovered
        /// Waited out with no video: ask once more on the SAME element.
        case retry
        /// Retire this element and make a fresh one (no video after the wait and the retry).
        case rebuild
        /// Fresh elements have not helped; stop and say so.
        case giveUp
    }

    /// Fresh elements per run. A camera toggle or a new person starts a new run.
    static let maxRebuilds = 3
    /// Between retiring an element and its replacement asking.
    static let freshDelay: TimeInterval = 1.5

    /// Only a refusal retires an element. There is no reliable "drawing"
    /// signal to judge by: the view's layer tree grows to four sublayers
    /// before any subscribe (2026-11-16 17:27:55), so it is logged, never used.
    ///
    /// Code 7 means "slow down", not "broken": the 2026-11-23 06:19 log shows
    /// video rendering one second after a code-7 refusal, and the old rule
    /// retired that working feed, blanking it and starting the next burst. An
    /// element whose render type is video is NEVER retired. One that is not
    /// gets one patient retry on the same element, and only then a fresh one.
    static func decide(watch: ElementWatch, now: Date, rebuilds: Int, rendering: Bool = false) -> Action {
        guard let until = watch.refusedUntil else { return .fine }
        if rendering { return .recovered }
        guard now >= until else { return .wait }
        if !watch.retried { return .retry }
        return rebuilds >= maxRebuilds ? .giveUp : .rebuild
    }

    /// A refusal is waited out at least this long before anything is done
    /// about it: the SDK often delivers the video anyway.
    static let refusalGrace: TimeInterval = 8

    static func refusalWait(_ backoffDelay: TimeInterval) -> TimeInterval { max(backoffDelay, refusalGrace) }

    /// Whether the element may make its one subscribe now.
    static func mayAsk(watch: ElementWatch, gaveUp: Bool, now: Date) -> Bool {
        !watch.subscribed && watch.refusedUntil == nil && !gaveUp && now >= watch.notBefore
    }
}
