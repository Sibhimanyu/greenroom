//
//  MeetingSurface.swift
//  Greenroom
//
//  Which control surface a live meeting shows: the Meeting window or the Bar
//  (the floating control bar). One value, events in, answers out, like
//  `SessionPhase`. Spec: docs/specs/meeting-surface.md.
//
//  The rule it keeps (owner D3): while a meeting is live there is always a
//  surface, the window when nothing holds it down, else the Bar. Zero is not
//  representable: `surface` is non-nil whenever the phase is live, and `visible`
//  always contains it. Both surfaces are visible together only during a settle
//  (the 0.5 s after a cover or desktop change) or a morph (shrink/expand).
//
//  Pure value type: Foundation only, no AppKit, SwiftUI or Zoom.
//
import Foundation

struct MeetingSurface: Hashable {

    /// One of the two places the controls live.
    enum Surface: Hashable { case window, bar }

    /// What happened, in the words of the controllers.
    enum Event: Hashable, CaseIterable {
        // Lifecycle
        case startBegan
        /// Live on the Bar (the default) or on the Meeting window (the layout places one).
        case wentLiveOnBar, wentLiveOnWindow
        case sessionEnded
        // The person's choices
        case collapse, expand, toggle
        // The close button (answers are the close sheet's buttons)
        case closeRequested
        case closeEnd, closeLeave, closeShrink, closeCancel
        /// The window went away with no question (code closed it).
        case windowClosedByCode
        // Where the window is
        case covered, uncovered
        case movedToOtherDesktop, backOnDesktop
        case minimised, restored
        /// The speaker tile's hide / show.
        case tileHidden, tileShown
        // Bookkeeping
        /// A Dock click or menu choice. Changes nothing; read `reopenTarget`.
        case reopen
        case morphFinished
        /// The 0.5 s settle ran out.
        case settleElapsed
    }

    private enum Phase: Hashable { case idle, starting, live }

    private var phase = Phase.idle
    /// The person (or a code close, or a start on the Bar) put the window away.
    private var collapsed = false
    /// The window was closed by code (or never opened): the Bar stands in, but it is
    /// not the person's choice, so a reopen brings the window back.
    private var closedByCode = false
    private(set) var isCovered = false
    private(set) var onOtherDesktop = false
    private(set) var isMinimised = false
    private var hiddenByTile = false
    private var morphing = false
    private var settling = false
    private var askingToClose = false
    /// The surface that was settled on screen before the pending change.
    private var from: Surface?

    init() {}

    /// Where a meeting goes live (owner, 2026-11-26): the Bar, unless the active
    /// layout places a Meeting window piece. Leave my windows alone has none, so it
    /// starts on the Bar. Nobody joining changes it; the Bar's Meeting button and
    /// the shortcut (`expand`) bring the window up on demand.
    static func wentLive(layoutPlacesMeeting: Bool) -> Event {
        layoutPlacesMeeting ? .wentLiveOnWindow : .wentLiveOnBar
    }

    // MARK: Answers

    /// Nothing holds the window down.
    var windowIsUp: Bool {
        !collapsed && !isCovered && !onOtherDesktop && !isMinimised && !hiddenByTile
    }

    /// The surface that should carry the controls. Nil only when not live or starting.
    var surface: Surface? {
        switch phase {
        case .idle: return nil
        case .starting: return .bar
        case .live: return windowIsUp ? .window : .bar
        }
    }

    /// What may be on screen right now: the answer alone, or, during a settle or
    /// a morph, the old and the new.
    var visible: Set<Surface> {
        guard let now = surface else { return [] }
        if (morphing || settling), let old = from { return [old, now] }
        return [now]
    }

    /// The meeting is live (past starting).
    var isLive: Bool { phase == .live }
    var isMorphing: Bool { morphing }
    var isSettling: Bool { settling }
    var closePromptUp: Bool { askingToClose }

    /// What a Dock click or menu choice brings forward. The window, unless the
    /// person chose the Bar (collapse, close then shrink, toggle, the speaker
    /// tile, or a start on the Bar): a window that is only covered, on
    /// another desktop or minimised comes forward. Nil only when not live or starting.
    var reopenTarget: Surface? {
        switch phase {
        case .idle: return nil
        case .starting: return .bar
        case .live: return ((collapsed && !closedByCode) || hiddenByTile) ? .bar : .window
        }
    }

    /// A layout pass (placing, re-placing) may bring the window forward. Not over a Bar
    /// the person chose: the pass only updates the frame the window will use next time.
    var layoutMayRaiseWindow: Bool { reopenTarget != .bar || phase == .starting }

    /// Does the screen agree with the model? Live: something is up and all of it
    /// is allowed. Not live: nothing is up.
    func screenMatches(_ onScreen: Set<Surface>) -> Bool {
        surface == nil ? onScreen.isEmpty : (!onScreen.isEmpty && onScreen.isSubset(of: visible))
    }

    // MARK: Events

    mutating func apply(_ event: Event) {
        if event == .sessionEnded || event == .closeEnd || event == .closeLeave {
            self = MeetingSurface()
            return
        }
        if event == .startBegan {
            self = MeetingSurface()
            phase = .starting
            from = .bar
            return
        }
        guard phase != .idle else { return }

        let before = surface
        var kind = Change.immediate

        switch event {
        case .wentLiveOnBar, .wentLiveOnWindow:
            guard phase == .starting else { return }
            phase = .live
            collapsed = event == .wentLiveOnBar
            closedByCode = false
            kind = .morph
        case .collapse:
            guard phase == .live else { return }
            collapsed = true
            closedByCode = false
            kind = .morph
        case .expand:
            guard phase == .live else { return }
            expandAll()
            kind = .morph
        case .toggle:
            guard phase == .live else { return }
            if windowIsUp { collapsed = true; closedByCode = false } else { expandAll() }
            kind = .morph
        case .closeRequested:
            guard phase == .live else { return }
            askingToClose = true
            return
        case .closeCancel:
            askingToClose = false
            return
        case .closeShrink:
            askingToClose = false
            guard phase == .live else { return }
            collapsed = true
            closedByCode = false
            kind = .morph
        case .windowClosedByCode:
            collapsed = true
            closedByCode = true
        case .covered: isCovered = true; kind = .settle
        case .uncovered: isCovered = false; kind = .settle
        case .movedToOtherDesktop: onOtherDesktop = true; kind = .settle
        case .backOnDesktop: onOtherDesktop = false; kind = .settle
        case .minimised: isMinimised = true; kind = .morph
        case .restored: isMinimised = false; kind = .morph
        case .tileHidden: hiddenByTile = true
        case .tileShown: hiddenByTile = false
        case .reopen:
            // Brought forward: whatever only covered it is cleared. A chosen Bar stays.
            guard phase == .live, reopenTarget == .window else { return }
            collapsed = false; closedByCode = false
            isCovered = false; onOtherDesktop = false; isMinimised = false
        case .morphFinished:
            morphing = false
            if !settling { from = surface }
            return
        case .settleElapsed:
            settling = false
            if !morphing { from = surface }
            return
        case .sessionEnded, .closeEnd, .closeLeave, .startBegan:
            return
        }

        let changed = surface != before
        switch kind {
        case .immediate:
            if !morphing && !settling { from = surface }
        case .morph:
            if changed { morphing = true }
            if !morphing && !settling { from = surface }
        case .settle:
            if changed && phase == .live { settling = true }
            if !morphing && !settling { from = surface }
        }
    }

    private enum Change { case immediate, morph, settle }

    /// Expand brings the window to where the person is and in front.
    private mutating func expandAll() {
        collapsed = false
        closedByCode = false
        isMinimised = false
        hiddenByTile = false
        onOtherDesktop = false
        isCovered = false
    }
}
