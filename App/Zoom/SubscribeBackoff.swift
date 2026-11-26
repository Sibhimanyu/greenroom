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
    /// Subscribed by setting `userid` (no explicit ask), and what the element
    /// showed at that moment. See VideoArrival.
    var subscribedByUserID = false
    var sawVideo = false
    /// VideoArrival asked for this element to be replaced; the owner's next
    /// pass retires it and makes a fresh one.
    var freshPending = false

    /// Video is showing: whatever refused it, it got there. Not a fault.
    mutating func recoveredByVideo() {
        subscribed = true
        refusedUntil = nil
    }

    /// Ask again on this same element (its one patient retry), repeating the
    /// request that was refused. After an explicit subscribe the resolution in
    /// force stays and only the subscribe goes in again. On an element
    /// subscribed by `userid` the only request made was setResolution, and that
    /// is what Zoom refused (2026-11-26 02:14Z), so it is asked again.
    mutating func readyToRetry() {
        retried = true
        subscribed = false
        refusedUntil = nil
        if subscribedByUserID {
            resolutionSet = false
            resolutionTries = 0
        }
    }

    /// The subscribe on screen found the element already subscribed by
    /// `userid`, showing `kind`.
    mutating func noteSubscribedByUserID(showing kind: RenderedKind) {
        subscribedByUserID = true
        if kind == .video { sawVideo = true }
    }

    /// The SDK reported a new data type for this element. Returns what the
    /// owner should do; `.freshElement` also sets `freshPending`.
    mutating func noteDataType(_ kind: RenderedKind) -> VideoArrival.Action {
        let action = VideoArrival.decide(kind, watch: self)
        if kind == .video { sawVideo = true }
        if action == .freshElement { freshPending = true }
        return action
    }

    /// One subscribe produces two or three refusals at the same instant
    /// (the log, every time). They are one event, not three.
    func isRepeatRefusal(at now: Date) -> Bool {
        lastRefusalAt.map { now.timeIntervalSince($0) < 1 } ?? false
    }

    /// A pass works on a copy of the watch while it calls the SDK, so a Zoom callback
    /// (onRenderDataTypeChanged, a refusal) that fires inside the call writes the stored
    /// watch, never one held inout (an exclusivity crash, Release too). Back in the store:
    /// the pass's copy plus what the callback set meanwhile.
    /// The callback only ever sets `freshPending` and `sawVideo`, or records a refusal newer than the pass's own.
    static func merged(pass: ElementWatch, stored: ElementWatch) -> ElementWatch {
        var w = pass
        if stored.freshPending { w.freshPending = true }
        if stored.sawVideo { w.sawVideo = true }
        if let at = stored.lastRefusalAt, at > (w.lastRefusalAt ?? .distantPast) {
            w.subscribed = false
            w.refusedUntil = stored.refusedUntil
            w.lastRefusalAt = at
        }
        return w
    }
}

/// The rule the logs taught. On macOS, setting `userid` on a normal video
/// element already subscribes it. An explicit subscribeVideo(true) on top is a
/// second ask and is refused with code 7 TooFrequentCall: 88 of 88 remote-user
/// asks on 2026-11-23, each with getDataType() already Video or Avatar (the
/// 2026-11-16 17:05 retries on the same element were refused the same way).
/// So the caller subscribes explicitly only while the data type is None. A
/// second element asking for a remote user another element holds is refused
/// too (view windows on 2026-11-13). Recovery for an element still at None is
/// a FRESH element, never a second subscribe on the same one.
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
    /// The data type is no such signal either: it follows the person's camera.
    /// 2026-11-26 02:14-02:15Z, four Active speaker elements in a row reported
    /// Video after a code-7 refusal, were kept as "showing despite the
    /// refusal", and every one stayed a dark tile with only the name. The
    /// elements that drew (2026-11-25 20:20-20:22Z, the stage at 02:15:01Z)
    /// were never refused.
    ///
    /// Code 7 means "slow down": the refusal is waited out (`refusalGrace`)
    /// before anything is done. An avatar (`showing == .avatar`: the camera is
    /// off, a fresh element would draw the same) forgets the refusal. Video or
    /// None gets one patient retry on the same element (`readyToRetry` repeats
    /// the refused request), and only then a fresh one.
    static func decide(watch: ElementWatch, now: Date, rebuilds: Int, showing: RenderedKind = .none) -> Action {
        guard let until = watch.refusedUntil else { return .fine }
        if showing == .avatar { return .recovered }
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

/// What an element draws, as a plain value (the SDK's VideoRenderDataType).
enum RenderedKind: Equatable {
    case none, video, avatar
}

/// The rule from 2026-11-25 20:18Z. A remote person admitted from the waiting
/// room was put on the stage 3 s later, before their camera's stream had
/// started: setting `userid` subscribed the element while the SDK drew an
/// avatar (dataType 2, and setResolution refused, code 1). A second later the
/// data type turned to video (1) with four sublayers, and the tile stayed a
/// blank dark grey for minutes. Elements made while the video was already
/// flowing (20:20:39 in a view window, 20:21:12 on the stage) drew at once.
/// So the first video on an element that was subscribed by userid while it
/// showed no video gets ONE fresh element, made while the video flows. Not a
/// second subscribe on the same element: that is refused with code 7.
/// An element that has drawn video before (a camera turned off and on) is
/// kept, and an explicit subscribe (asked at None, resolution first) is
/// never judged here.
enum VideoArrival {
    enum Action: Equatable {
        case keep
        /// Retire this element and make a fresh one for the same person.
        case freshElement
    }

    static func decide(_ kind: RenderedKind, watch: ElementWatch) -> Action {
        guard kind == .video, watch.subscribedByUserID, !watch.sawVideo, !watch.freshPending else { return .keep }
        return .freshElement
    }
}
