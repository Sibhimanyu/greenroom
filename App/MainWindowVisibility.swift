//
//  MainWindowVisibility.swift
//  Greenroom
//
//  While a class or a recording is live, the main window steps aside: the
//  meeting window or the recording bar is the surface. This is the pure
//  decision behind it, as a small state machine: events in (the session went
//  live or ended, a start failed, the person opened the window on purpose, the
//  app is quitting), actions out (remember the frame, hide, restore, show).
//  Foundation only, so the test target compiles this file as it is; the
//  coordinator turns the actions into window calls.
//
//  Hiding is `orderOut`, never close or miniaturize, so Home keeps whatever was
//  typed in it. It happens only once the session is live, never while it is
//  still getting ready, so a failed start finds the window where it was.
//
import Foundation

struct MainWindowVisibility: Equatable {

    enum Event: Equatable {
        /// Start was pressed and Home was on screen: it steps aside now, not
        /// when the meeting is live (StartChoreography.swift).
        case startBegan
        /// The session's live-ness changed (true: a meeting is joined or a
        /// recording is running; false: it is over).
        case liveChanged(Bool)
        /// A start failed at some step, or was cancelled.
        case startFailed
        /// The person brought the main window back on purpose while live
        /// (Sessions, Last, Open Greenroom Window). It stays until the next
        /// session starts.
        case openedOnPurpose
        /// The person deliberately quit: nothing is shown again.
        case quitting
    }

    enum Action: Equatable {
        case rememberFrame
        case hide
        /// Home steps aside toward the Control bar as a start begins (animated).
        case hideForStart
        /// A start ended before it was live: Home comes back where it was, on
        /// the page it was on (animated).
        case showAfterStart
        /// Put the window back at the remembered frame.
        case restoreFrame
        /// Back to the Home page.
        case goHome
        /// Bring it forward without activating the app.
        case show
    }

    private(set) var isLive = false
    /// We ordered the window out and it has not been brought back since.
    private(set) var hiddenByUs = false
    private(set) var isQuitting = false
    /// Hidden at the start click, not yet by a live session.
    private(set) var hiddenForStart = false

    mutating func handle(_ event: Event) -> [Action] {
        switch event {
        case .startBegan:
            guard !isQuitting, !hiddenByUs, !isLive else { return [] }
            hiddenByUs = true
            hiddenForStart = true
            return [.rememberFrame, .hideForStart]

        case .liveChanged(true):
            guard !isLive else { return [] }
            isLive = true
            guard !isQuitting else { return [] }
            // Already out of the way since the click: nothing more to do.
            if hiddenForStart { hiddenForStart = false; return [] }
            hiddenByUs = true
            return [.rememberFrame, .hide]

        case .liveChanged(false):
            guard isLive else { return [] }
            isLive = false
            return restore()

        case .startFailed:
            isLive = false
            return restore()

        case .openedOnPurpose:
            hiddenByUs = false
            hiddenForStart = false
            return []

        case .quitting:
            isQuitting = true
            hiddenByUs = false
            return []
        }
    }

    /// The window comes back: at its frame, on Home, when we had hidden it;
    /// just brought forward, where it is, when the person had opened it.
    private mutating func restore() -> [Action] {
        guard !isQuitting else { hiddenByUs = false; return [] }
        defer { hiddenByUs = false; hiddenForStart = false }
        if hiddenForStart { return [.showAfterStart] }
        return hiddenByUs ? [.restoreFrame, .goHome, .show] : [.show]
    }
}
