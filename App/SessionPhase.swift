import Foundation

/// What Greenroom is doing right now, as one value.
///
/// Two parts that move on their own clocks (GLOSSARY.md):
///
///  - the **session**: nothing / starting / live / stopping, each for a meeting
///    or for a Record-mode session;
///  - the **take**: the recording file: none / rolling / paused / saving.
///    Saving may outlive the session.
///
/// The coordinator reports what happened as an `Event`; nothing writes a part
/// directly. The eight values at the bottom equal the eight `Bool` flags the
/// coordinator used to set by hand, at every moment, quirks included:
///
///  - `isRunning` stays true through a Record countdown and take start, until
///    the start task ends (so a live meeting has `isRunning == false` once its
///    start task has finished, while `stageLive` is true);
///  - `isStopping && isRunning` while Stop waits for a start still in flight;
///  - `isSavingRecording` can outlive `isStopping`; `isRecording` can be true
///    while `isStopping`;
///  - `isRecordingPaused` stays true after a paused take ends, until the next
///    take begins (the old code never cleared it on stop).
///
/// Pure value type: no SwiftUI, Zoom, AppKit or async. Unit-tested directly.
struct SessionPhase: Equatable {

    enum Kind: Equatable { case meeting, record }

    /// The session part. `pictureUp` is "the picture is built": `stageLive` for
    /// a meeting, `recordOnlyActive` for a Record session. `startTaskRunning`
    /// is the start task still being alive (`isRunning`, and for Record
    /// `startingRecordOnly`). A kind is only held while one of the two is true.
    enum Session: Equatable {
        case idle
        /// The start task is running; the picture may already be up.
        case starting(Kind, pictureUp: Bool)
        /// The start task has finished and the picture is up.
        case live(Kind)
        /// Stop was asked for. Whatever was underneath is still there until the
        /// teardown says so (a start in flight, the picture).
        case stopping(Kind?, startTaskRunning: Bool, pictureUp: Bool)
    }

    /// The take part.
    enum Take: Equatable {
        case none
        case rolling
        case paused
        /// Stopped; the file is being closed. May outlive the session.
        case saving
    }

    /// What happened, in the words of the coordinator's own flow.
    enum Event: Equatable {
        // Meeting
        /// start() accepted the request: the start task is about to run.
        case meetingStartRequested
        /// runPipeline built the picture and it is going to the meeting.
        case meetingPictureUp
        /// The start task ended, whether it finished, failed or was cancelled.
        /// `startID` is the `startID` read right after the start was requested;
        /// an end that belongs to an older start is ignored.
        case meetingStartTaskFinished(startID: Int)
        // Record session
        /// Start Recording accepted: the start task is about to run.
        case recordStartRequested
        /// The Record picture is built.
        case recordPictureUp
        /// The Record picture was put away (abandoned start, or stop).
        case recordPictureDown
        /// The Record start task ended (finished, failed, cancelled).
        case recordStartTaskFinished(startID: Int)
        // Stopping (either kind)
        /// stop() / stopRecordingSession() began.
        case stopRequested
        /// A meeting's teardown completed: nothing is running any more.
        case meetingTornDown
        /// A Record session's stop completed (its picture went down earlier).
        case recordStopFinished
        // Take
        case takeBegan
        case takePaused
        case takeResumed
        /// The tape was stopped; the file is being closed.
        case takeFinishing
        /// Same, from a meeting's End Session (the file closes in the background).
        case takeFinishingAtMeetingEnd
        /// The file is closed (or closing failed).
        case takeSaved
        /// The recorder stopped on its own (disk full, writer failed).
        case recorderStoppedItself
        /// Quit stopped the tape and waited for it itself.
        case takeDroppedAtQuit
    }

    private(set) var session: Session = .idle
    private(set) var take: Take = .none
    /// The old paused flag was only cleared by resume and by a new take, never
    /// when a paused take ended. Kept so the derived value stays identical.
    private var pauseLeftover = false
    /// Counts start requests. A cancelled start task can end after Stop's
    /// teardown and after a newer start began; carrying this number back in the
    /// finish event lets that late end be told apart and ignored.
    private(set) var startID = 0

    init() {}

    // MARK: Events

    mutating func apply(_ event: Event) {
        switch event {
        case .takeBegan, .takePaused, .takeResumed, .takeFinishing, .takeFinishingAtMeetingEnd, .takeSaved,
             .recorderStoppedItself, .takeDroppedAtQuit:
            applyToTake(event)
        default:
            applyToSession(event)
        }
    }

    private mutating func applyToTake(_ event: Event) {
        switch event {
        case .takeBegan:
            take = .rolling
            pauseLeftover = false
        case .takePaused:
            if take == .rolling { take = .paused }
        case .takeResumed:
            if take == .paused { take = .rolling }
        case .takeFinishing, .takeFinishingAtMeetingEnd:
            guard take == .rolling || take == .paused else { return }
            if take == .paused { pauseLeftover = true }
            take = .saving
        case .takeSaved:
            if take == .saving { take = .none }
        case .recorderStoppedItself, .takeDroppedAtQuit:
            guard take == .rolling || take == .paused else { return }
            if take == .paused { pauseLeftover = true }
            take = .none
        default:
            break
        }
    }

    private mutating func applyToSession(_ event: Event) {
        // Take the session apart into its four facts, change them, and put
        // it back together; the enum is the only thing that is stored.
        var kind: Kind?
        var running = false
        var up = false
        var stopping = false
        switch session {
        case .idle: break
        case let .starting(k, pictureUp): kind = k; running = true; up = pictureUp
        case let .live(k): kind = k; up = true
        case let .stopping(k, r, u): kind = k; running = r; up = u; stopping = true
        }

        switch event {
        case .meetingStartRequested:
            startID += 1
            kind = .meeting; running = true; up = false
        case .meetingPictureUp:
            if kind == nil || kind == .meeting { kind = .meeting; up = true }
        case let .meetingStartTaskFinished(id):
            if id == startID, kind != .record { running = false }
        case .recordStartRequested:
            startID += 1
            if kind == .meeting { up = false }
            kind = .record; running = true
        case .recordPictureUp:
            if kind == nil || kind == .record { kind = .record; up = true }
        case .recordPictureDown:
            if kind == .record { up = false }
        case let .recordStartTaskFinished(id):
            if id == startID, kind == .record { running = false }
        case .stopRequested:
            stopping = true
        case .meetingTornDown:
            if kind != .record { running = false; up = false; stopping = false }
        case .recordStopFinished:
            stopping = false
        default:
            break
        }

        let k = (running || up) ? kind : nil
        if stopping {
            session = .stopping(k, startTaskRunning: running, pictureUp: up)
        } else if running, let k {
            session = .starting(k, pictureUp: up)
        } else if up, let k {
            session = .live(k)
        } else {
            session = .idle
        }
    }

    // MARK: The eight flags, derived

    private var kind: Kind? {
        switch session {
        case .idle: return nil
        case let .starting(k, _), let .live(k): return k
        case let .stopping(k, _, _): return k
        }
    }
    private var startTaskRunning: Bool {
        switch session {
        case .starting: return true
        case let .stopping(_, running, _): return running
        default: return false
        }
    }
    private var pictureUp: Bool {
        switch session {
        case let .starting(_, up): return up
        case .live: return true
        case let .stopping(_, _, up): return up
        case .idle: return false
        }
    }

    var isRunning: Bool { startTaskRunning }
    var stageLive: Bool { kind == .meeting && pictureUp }
    var isStopping: Bool {
        if case .stopping = session { return true }
        return false
    }
    var recordOnlyActive: Bool { kind == .record && pictureUp }
    var startingRecordOnly: Bool { kind == .record && startTaskRunning }
    var isRecording: Bool { take == .rolling || take == .paused }
    var isRecordingPaused: Bool { take == .paused || pauseLeftover }
    var isSavingRecording: Bool { take == .saving }

    // MARK: Named questions

    /// A session or a take is on screen: a meeting (starting or live), a Record
    /// session (starting, or live between takes), or a take being made. What
    /// keeps an automatic update dialog off a shared screen.
    var hasSessionOrTakeOnScreen: Bool { isRunning || stageLive || recordOnlyActive || isRecording }
}
