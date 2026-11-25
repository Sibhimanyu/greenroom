//
//  MeetingSurfaceOwner.swift
//  Greenroom
//
//  The one `MeetingSurface` value of the running meeting, and the people who
//  talk to it. The two controllers that draw the surfaces are static enums, so
//  the value lives here instead of in the coordinator: every trigger calls
//  `send`, and the controllers draw what `model` says. Spec:
//  docs/specs/meeting-surface.md (R13).
//
//  Three jobs besides holding the value:
//  - the settle: a cover or desktop change waits half a second, then
//    `settleElapsed` (a new change while it waits starts the wait again);
//  - a morph that no animation is running (a minimise with nothing to animate,
//    a go-live) is finished on the next turn, so both surfaces are never left up;
//  - `syncWindowFacts`: the window's own state (covered, on another desktop,
//    minimised, gone) read from the window and sent as events, from every
//    notification and from the safety check.
//
import AppKit
import os

@MainActor
enum MeetingSurfaceOwner {

    private(set) static var model = MeetingSurface()

    /// The meeting is live: there is a surface to show.
    static var isLive: Bool { model.isLive }

    /// The person put the Bar up themselves (collapse, close then shrink, toggle,
    /// the speaker tile, started small while alone). A layout pass must not undo it.
    static var personChoseTheBar: Bool { model.isLive && model.reopenTarget == .bar }

    /// Held so the safety check can build a Bar that was never installed.
    static weak var coordinator: CoordinatorController?

    private static var settleTimer: Timer?
    private static var morphFinishQueued = false

    static let settleSeconds: TimeInterval = 0.5

    /// Tells the model, then draws what it says.
    static func send(_ event: MeetingSurface.Event) {
        let before = model
        model.apply(event)
        guard model != before else { return }
        if model.isSettling { armSettle() } else { disarmSettle() }
        if model.isMorphing { queueMorphFinishIfNoneRuns() }
        MeetingControlBarController.render()
    }

    // MARK: Settle

    private static func armSettle() {
        settleTimer?.invalidate()
        let timer = Timer(timeInterval: settleSeconds, repeats: false) { _ in
            MainActor.assumeIsolated {
                settleTimer = nil
                send(.settleElapsed)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    private static func disarmSettle() {
        settleTimer?.invalidate()
        settleTimer = nil
    }

    // MARK: Morph

    /// Every morph the model owes is finished by the animation that ran it. A
    /// morph with no animation (nothing to draw, no Bar to land on) has nobody
    /// to say so: it is finished on the next turn, by which time a real morph
    /// has started if there is one.
    private static func queueMorphFinishIfNoneRuns() {
        guard !morphFinishQueued else { return }
        morphFinishQueued = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                morphFinishQueued = false
                if model.isMorphing, !MeetingControlBarController.morphRunning { send(.morphFinished) }
            }
        }
    }

    // MARK: The window's own state

    /// Sends what the window says about itself and the model does not know yet.
    /// Missing window while the model wants it: it is gone, so the Bar stands in.
    static func syncWindowFacts() {
        guard model.isLive else { return }
        let facts = ParticipantGridWindowController.windowFacts
        guard facts.exists else {
            if model.surface == .window { send(.windowClosedByCode) }
            return
        }
        if facts.minimised != model.isMinimised { send(facts.minimised ? .minimised : .restored) }
        if facts.elsewhere != model.onOtherDesktop { send(facts.elsewhere ? .movedToOtherDesktop : .backOnDesktop) }
        if facts.covered != model.isCovered { send(facts.covered ? .covered : .uncovered) }
    }

    // MARK: Ending

    /// The meeting is over (or never started): no surface, no timers.
    static func reset() {
        disarmSettle()
        morphFinishQueued = false
        send(.sessionEnded)
    }

    #if DEBUG
    private static let logger = Logger(subsystem: "com.sibhimanyu.greenroom", category: "meeting-surface")
    static func debugLog(_ line: String) { logger.notice("\(line, privacy: .public)") }
    #endif
}
