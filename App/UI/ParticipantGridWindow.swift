//
//  ParticipantGridWindow.swift
//  Greenroom
//
//  Greenroom's own meeting window: every participant, and every control the SDK
//  exposes, with a Gallery/Speaker control, a stage, one side panel and a toolbar
//  (see `Form`). The old full-display "reference" panel with its rail is gone
//  (2026-11-24); a Meeting that fills a display is this window at the display's size.
//
//  In default Zoom-UI mode the gallery is one of the SDK's own windows, which
//  Greenroom had to identify among several, send to the right display, and keep
//  re-sending because the SDK moved it back on every meeting state change. That
//  produced a visible flicker between displays and a two-minute give-up
//  backstop. None of that applies here: the window is ours, so it goes where we
//  put it and stays, and clicking it cannot make the SDK rebuild anything
//  because in custom-UI mode the SDK owns no windows at all.
//
import AppKit
import SwiftUI
import Combine

@MainActor
enum ParticipantGridWindowController {

    // MARK: - What the caller supplies

    /// Session facts the roster cannot answer for itself. Passed in rather than
    /// read from the SDK because Greenroom, not Zoom, owns the meeting number
    /// the teacher typed and the recording state.
    struct SessionInfo: Equatable {
        var meetingNumber: String = ""
        var startedAt: Date?
        var isRecording: Bool = false
        /// The last recording is still being closed; Record waits.
        var isSavingRecording: Bool = false
        var presetName: String = ""
        /// How far the start has got. See `Readiness`.
        var readiness = Readiness()
    }

    /// How much of the session is up yet.
    ///
    /// The panel used to open only once the meeting was connected, which left
    /// the reference display blank for the whole start - several seconds of
    /// the picture coming up, meeting creation and SDK auth during which the
    /// teacher could see the workspace appear and then nothing at all. The work
    /// was never invisible to the app; every step already wrote a line into the
    /// status log. It was invisible to the person waiting, because that log is
    /// collapsed by default and lives in another window on another display.
    ///
    /// So the panel opens on the first frame of the start and shows this
    /// instead, filling in as each piece comes live. That is not decoration: a
    /// start that hangs now hangs visibly, on a named step.
    struct Readiness: Equatable {
        enum State: Equatable { case pending, active, done, skipped, failed }
        struct Step: Equatable {
            var label: String
            var state: State
        }

        var steps: [Step] = []
        /// Set when a start fails, so the panel stops promising it is coming.
        var failure: String?
        /// The newest status line, shown under the steps. Without it the card
        /// says only which step is running, and a slow step reads as a hang.
        var detail: String?

        /// True once there is nothing left to wait for. An empty list counts as
        /// live so that anything not driving readiness - a panel
        /// reopened mid-session - behaves exactly as before.
        var isLive: Bool {
            failure == nil && steps.allSatisfy { $0.state == .done || $0.state == .skipped }
        }
        var settled: Int { steps.filter { $0.state == .done || $0.state == .skipped }.count }
    }

    /// Started with the panel and stopped with it, so nothing taps the
    /// microphone outside a session.
    private static let micMonitor = MicLevelMonitor()
    private static var micTimer: Timer?

    /// What the two buttons on a failed start do. Set once by the coordinator
    /// and deliberately NOT cleared by `close()`: the failure card has to
    /// outlive the session teardown that put it there.
    static var readinessTryAgain: (@MainActor () -> Void)?
    static var readinessDismiss: (@MainActor () -> Void)?

    private static weak var client: ZoomMeetingSDKClient?
    private static var log: (@MainActor (String) -> Void)?
    /// The meeting window's chat panel reads this; the toolbar and the People
    /// panel's side column read `controls`.
    fileprivate static var chatBridge: ZoomChatBridge?
    static var controls: MeetingControlsModel?

    /// Wired once at session start. The window talks to the SDK directly rather
    /// than routing every button through the coordinator: the coordinator owns
    /// placement and session lifecycle, not what a host does to a roster.
    static func configure(client: ZoomMeetingSDKClient,
                          chat: ZoomChatBridge,
                          controls: MeetingControlsModel?,
                          log: @escaping @MainActor (String) -> Void) {
        self.client = client
        self.chatBridge = chat
        self.controls = controls
        self.log = log

        // Driven on its own timer, not the one-second roster poll: a meter that
        // updated once a second would not be a meter.
        micMonitor.start()
        micTimer?.invalidate()
        micTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { _ in
            Task { @MainActor in
                root?.applyMicLevel(micMonitor.level, running: micMonitor.isRunning)
            }
        }
    }

    // MARK: - Window

    /// Which of the window's two forms this is.
    ///
    /// `meeting` is Greenroom's own meeting window: video in the middle, a toolbar
    /// along the foot, Gallery or Speaker above, and one side panel on the right.
    /// It is a real titled window in every case, never borderless, so there is
    /// always a close button and a title bar to move it by.
    enum Form: Equatable {
        /// No layout: a window the teacher owns. `fillsScreen` is the first-run
        /// size only; after that the frame is wherever it was left.
        case meeting(fillsScreen: Bool)
        /// Arranged: the layout's Meeting piece, at the frame it was given. Under
        /// 760x520 it is the Speaker view with the toolbar on hover; at or above,
        /// the full meeting form.
        case placed(NSRect)

        /// A placed window too small for the full form: Speaker view, chrome on hover.
        var isSlot: Bool {
            if case .placed(let frame) = self { return LayoutResolver.isCompactMeeting(frame.size) }
            return false
        }
        var isPlaced: Bool { if case .placed = self { return true } else { return false } }
        /// Same kind of window, whatever its current frame. A placed window that
        /// crosses the compact/full line is a different window: its chrome and
        /// minimum size are fixed when it is made.
        func matches(_ other: Form) -> Bool {
            switch (self, other) {
            case (.meeting, .meeting): return true
            case (.placed, .placed): return isSlot == other.isSlot
            default: return false
            }
        }
    }

    /// A non-activating panel, not a plain window. Clicking a control must not
    /// pull Greenroom in front of whatever the teacher has on their main screen.
    private final class ControlPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }

        /// The yellow traffic light, the Window menu's Minimize, the title bar's
        /// double click and Command-M all arrive here (the standard button calls
        /// performMiniaturize, which calls miniaturize). NSWindowDelegate has no
        /// "should miniaturize", so the window itself decides: while a meeting is
        /// live it runs the shrink-to-control-bar morph instead of going to the Dock.
        /// The red light and Command-W. While a class is live the coordinator puts a
        /// sheet on this window instead (End / Leave, Shrink, Cancel); the close
        /// happens only when nothing is live, or by code.
        override func performClose(_ sender: Any?) {
            if !ParticipantGridWindowController.closingByCode,
               ParticipantGridWindowController.confirmClose?(self) == false { return }
            super.performClose(sender)
        }

        override func miniaturize(_ sender: Any?) {
            if ParticipantGridWindowController.shrinkInsteadOfMinimize?() == true { return }
            super.miniaturize(sender)
        }

        /// The customisable "Shrink meeting to control bar" key (Command-M by
        /// default), answered only while this window is key.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.type == .keyDown,
               let combo = ShortcutStore.shared.bindings.combo(for: .action(.shrinkToBar)),
               combo.keyCode == UInt32(event.keyCode),
               combo.modifiers == KeyCombo.carbonModifiers(cocoaFlags: event.modifierFlags.rawValue),
               ParticipantGridWindowController.shrinkInsteadOfMinimize?() == true {
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    /// Set by the coordinator: shrinks the meeting to the control bar and returns
    /// true while a meeting is live (see `MeetingMinimize`); false otherwise, and
    /// the window then minimises as any window does.
    static var shrinkInsteadOfMinimize: (@MainActor () -> Bool)?

    /// Set by the coordinator: asked before the teacher's own close. True lets
    /// the window close; false means a sheet is up and the close waits.
    static var confirmClose: (@MainActor (NSWindow) -> Bool)?

    private static var panel: ControlPanel?

    /// Called when the teacher closes the meeting window with its own close
    /// button, so the coordinator can stop feeding it and the pill can take
    /// over. Not called for the closes the controller does itself.
    static var onUserClosed: (@MainActor () -> Void)?
    fileprivate static var closingByCode = false
    private static var closeObserver: NSObjectProtocol?
    /// Set when the window was hidden on purpose (the speaker shortcut), so the
    /// one-second refresh does not bring it straight back.
    private static var userHidden = false

    private static func closePanelByCode() {
        closingByCode = true
        panel?.close()
        closingByCode = false
    }
    /// Where the panel currently lives, for alerts that must appear on the
    /// same display the teacher is looking at.
    fileprivate static var panelScreen: NSScreen? { panel?.screen }
    /// The Meeting window, for the layout's share choice.
    static var meetingWindow: NSWindow? { panel }
    /// The panel window itself, for the alert runner to step around.
    fileprivate static var panelWindowForAlerts: NSWindow? { panel }
    private static var root: RootView?
    /// You, as the SDK lists you: the Participants panel shows your own row.
    fileprivate static var myEntry: ZoomMeetingSDKClient.RosterEntry?

    /// The meeting window's frame when nothing has been saved: the whole visible
    /// display if asked to fill it, otherwise centred on the main display
    /// at 1280x800 or the screen less 80pt, whichever is smaller.
    private static func meetingFrame(on screen: NSScreen, fillsScreen: Bool) -> NSRect {
        let area = screen.visibleFrame
        if fillsScreen { return area }
        let size = NSSize(width: min(1280, area.width - 80), height: min(800, area.height - 80))
        return NSRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    private static func makePanel(on screen: NSScreen, form: Form) -> ControlPanel {
        let frame: NSRect
        switch form {
        case .meeting(let fills): frame = meetingFrame(on: screen, fillsScreen: fills)
        case .placed(let placed): frame = placed
        }
        let created = ControlPanel(contentRect: frame,
                                   styleMask: [.titled, .closable, .resizable, .miniaturizable, .nonactivatingPanel],
                                   backing: .buffered,
                                   defer: false,
                                   screen: screen)
        created.title = "Meeting"
        ZoomMeetingSDKClient.videoLog("panel form=\(form) screen=\(screen.localizedName)"
            + " size=\(Int(frame.width))x\(Int(frame.height))")
        created.isReleasedWhenClosed = false
        created.hidesOnDeactivate = false
        created.backgroundColor = MeetingTheme.windowNS
        // Zoom's meeting window is dark whatever the system is, and its bar
        // sits where the title bar is (MeetingTheme).
        created.appearance = NSAppearance(named: .darkAqua)
        created.titlebarAppearsTransparent = true
        created.titleVisibility = .hidden
        created.styleMask.insert(.fullSizeContentView)
        // Ordinary window level, deliberately. A window that covers the menu bar
        // and Dock at a higher level layers every other window on the display
        // underneath it, which made the display unusable for anything else.
        // Never a fullscreen Space either - a window in a Space cannot be re-framed.
        created.level = .normal
        created.collectionBehavior = [.managed, .fullScreenAuxiliary]
        created.isMovable = true
        // The toolbar and the three-button strip need this much to read.
        created.minSize = form.isSlot ? NSSize(width: 320, height: 200) : NSSize(width: 760, height: 520)
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        if case .meeting = form {
            // First time at the sized frame above; after that wherever the
            // teacher left it. A saved spot on a display that is gone is
            // dropped so the window cannot open off screen.
            created.setFrameAutosaveName("MeetingWindow")
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(created.frame) }) {
                created.setFrame(frame, display: false)
            }
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: created, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if !closingByCode { onUserClosed?() }
            }
        }
        return created
    }

    // MARK: - Refresh

    /// Pulls the roster itself and redraws. Called on a poll rather than driven
    /// by join/leave callbacks because a brand-new participant's video element
    /// is not renderable the instant the callback fires, and a poll converges
    /// whether or not any single event was missed.
    static func refresh(on screen: NSScreen, session: SessionInfo, form wanted: Form) {
        guard let client else { return }
        // R45: a window that is up keeps its form (and so its frame) on the
        // one-second pass. Only a placing pass the owner asked for (Start, a
        // switch, Snap Back, a display coming or going) lets the layout's form
        // through, which rebuilds the window when its size class changed.
        let form: Form
        if panel != nil, let current = currentForm,
           !LayoutPlacementRules.shouldPlace(pendingPlacement ?? .tick, .placed) {
            form = current
        } else {
            form = wanted
        }
        pendingPlacement = nil

        // Self is never in the grid. The corner preview carries it, and an NSView has one superview - having both would
        // mean two hosts fighting over one SDK render element.
        var roster = client.meetingRoster()
        myEntry = roster.first { $0.isMyself }
        roster.removeAll { $0.isMyself }

        let hosting: ControlPanel
        let isNewWindow: Bool
        if let existing = panel, let current = currentForm, current.matches(form) {
            hosting = existing
            isNewWindow = false
        } else {
            isNewWindow = true
            // Closed, not merely ordered out. orderOut leaves the window in
            // NSApp.windows for the life of the process, so swapping forms
            // would strand one there on every switch - invisible, but still
            // walked by the 500ms SDK-window sweep and never freed.
            root?.detachAllVideo()
            closePanelByCode()
            hosting = makePanel(on: screen, form: form)
            let view = RootView(frame: hosting.contentLayoutRect, form: form)
            view.autoresizingMask = [.width, .height]
            hosting.contentView = view
            // Only you see the Meeting window: its background is a dark frost,
            // the faces, text and controls on it stay opaque.
            WindowFrost.install(in: hosting, solid: MeetingTheme.windowNS)
            WindowShareController.attach(to: hosting, dark: true).set(LayoutShareChoice.meeting)
            panel = hosting
            root = view
            userHidden = false
        }
        currentForm = form
        lastScreen = screen
        lastSession = session
        // Hidden or shrunk to the bar: give the stage and tiles back to save
        // Zoom's stream budget (it caps concurrent streams). Duplicate holders
        // of one user are fine. Back on screen, the next refresh subscribes.
        let streamsHeld = !(!isNewWindow
            && (userHidden || hosting.isMiniaturized || !hosting.isVisible))
        if !streamsHeld {
            if client.holdsMeetingWindowStreams {
                ZoomMeetingSDKClient.videoLog("meeting window hidden; releasing stage and tiles")
            }
            client.releaseStage()
            client.pruneParticipantViews(keeping: [])
        }
        root?.update(roster: roster,
                     flags: client.roomFlags(),
                     waiting: client.waitingRoomNames(),
                     session: session,
                     featured: client.speakerToShow(),
                     videoProvider: { id, frame in
                         guard streamsHeld else { return nil }
                         return client.participantView(userID: id, frame: frame)
                     },
                     selfProvider: { frame in client.makeRailSelfView(frame: frame) },
                     stageProvider: { id, frame in streamsHeld ? client.stageView(userID: id, frame: frame) : nil },
                     releaseStage: { client.releaseStage() })
        // Pruned to the VISIBLE page, not the whole roster, so students on other
        // pages release their streams. The self view is a separate element and
        // is unaffected.
        if streamsHeld { client.pruneParticipantViews(keeping: root?.visibleIDs ?? []) }

        // Raise it only when it is new, or when it has gone away and was not
        // deliberately minimised or hidden. Placement here is CONVERGENT, not
        // assertive.
        //
        // The first version ordered the panel front on every tick of a
        // one-second poll, which meant clicking any other window sent it behind
        // and then had it jump back on top a second later - a tug-of-war with
        // the person using the Mac. A window that is merely BEHIND another is
        // still `isVisible`, so this leaves it where the user put it.
        // Over a Bar the person chose, a layout pass only updates the frame.
        if !MeetingSurfaceOwner.layoutMayRaiseWindow { return }
        if isNewWindow {
            hosting.comeToThisDesktop(settledBehavior: [.managed, .fullScreenAuxiliary])
        } else if (!hosting.isVisible && !hosting.isMiniaturized && !userHidden) {
            hosting.orderFrontRegardless()
        }
    }

    private static var currentForm: Form?
    /// The placing pass that ran since the last refresh
    /// (`CoordinatorController.placeCustomSurfaces`), if any. One the owner asked
    /// for lets the next refresh take the layout's form. Cleared by that refresh.
    static var pendingPlacement: PlacementTrigger?
    /// The last inputs to `refresh`, so a control can redraw the panel the
    /// instant it acts instead of waiting for the next poll tick.
    private static var lastScreen: NSScreen?
    private static var lastSession = SessionInfo()

    /// Re-reads SDK state and redraws now.
    ///
    /// Without this every control had up to a full second of dead time: the
    /// roster poll runs at 1Hz, so pressing "Mute me" left the button still
    /// saying "Mute me" until the next tick. Nothing was broken, but nothing
    /// acknowledged the press either, which is the whole of what "unresponsive"
    /// meant here.
    static func refreshNow() {
        guard let remembered = lastScreen, let form = currentForm else { return }
        // The remembered NSScreen can be one that has since been unplugged (or
        // rebuilt by AppKit after a display change). Re-find it by its display
        // ID, and fall back to the main display, so a control pressed in that
        // moment never re-frames the panel onto a dead screen.
        let screen = DisplayResolver.displayID(of: remembered)
            .flatMap { id in NSScreen.screens.first { DisplayResolver.displayID(of: $0) == id } }
            ?? DisplayResolver.mainDisplayScreen()
        guard let screen else { return }
        // A redraw, not a placing pass: a pending layout form waits for the loop.
        let pending = pendingPlacement
        refresh(on: screen, session: lastSession, form: form)
        pendingPlacement = pending
    }

    static var isOpen: Bool { panel != nil }
    /// The meeting window specifically, on screen or not.
    static var meetingWindowIsOpen: Bool { panel != nil }

    /// On screen in the sense that matters to the pill: open, not minimised and
    /// not hidden on purpose, with some part of it actually visible. A window
    /// entirely under other windows does not count; the controls would be
    /// unreachable.
    static var meetingWindowIsShowing: Bool {
        guard let panel else { return false }
        // A live meeting: the surface the model has chosen (it hears covered, minimised
        // and desktop changes). Before that, what the window says itself.
        if MeetingSurfaceOwner.isLive { return MeetingSurfaceOwner.model.surface == .window }
        return panel.isVisible && !panel.isMiniaturized && panel.isOnActiveSpace && panel.occlusionState.contains(.visible)
    }

    /// On screen the way the window itself reports it: open, not minimised, on the
    /// desktop in view and with some part of it visible. The safety check compares
    /// this with the model.
    static var windowIsOnScreen: Bool {
        guard let panel else { return false }
        return panel.isVisible && !panel.isMiniaturized && panel.isOnActiveSpace && panel.occlusionState.contains(.visible)
    }

    /// What the window says about itself, for `MeetingSurfaceOwner.syncWindowFacts`.
    /// Ordered out on purpose (shrunk, hidden) is none of the three: the person's
    /// choice reaches the model as its own event.
    static var windowFacts: (exists: Bool, minimised: Bool, elsewhere: Bool, covered: Bool) {
        guard let panel else { return (false, false, false, false) }
        if panel.isMiniaturized { return (true, true, false, false) }
        guard panel.isVisible else { return (true, false, false, false) }
        if !panel.isOnActiveSpace { return (true, false, true, false) }
        return (true, false, false, !panel.occlusionState.contains(.visible))
    }

    /// The meeting window exists but is out of sight on purpose: shrunk to the
    /// control bar, minimised or ordered out. Not the same as covered by another
    /// window, which `meetingWindowIsShowing` also reports as not showing.
    static var meetingWindowIsHidden: Bool {
        guard let panel else { return false }
        return !panel.isVisible || panel.isMiniaturized
    }

    /// A deliberate bring-forward (Dock click, menu choice): the window takes key.
    static func makeMeetingWindowKey() {
        guard let panel else { return }
        panel.makeKeyAndOrderFront(nil)
    }

    /// The Cycle meeting view shortcut: Speaker, Gallery, Multi-speaker, as the
    /// segmented control does. False when there is nothing to switch (no meeting
    /// window, or the small slot form, which is always Speaker).
    @discardableResult
    static func cycleMeetingView() -> Bool {
        root?.cycleViewMode() ?? false
    }

    /// So SDK window hunting recognises this as ours, the same as the chat
    /// window.
    static func owns(_ candidate: NSWindow) -> Bool { candidate == panel }

    /// A picture of the meeting window as it is, and where it is, for the morph
    /// into the control bar. Nil with no full meeting window. It is the view
    /// hierarchy drawn into a bitmap, so the SDK's own video surfaces may come
    /// out as the tile colour: the picture is only on screen for a third of a second.
    static func morphSnapshot() -> (image: NSImage, frame: NSRect)? {
        guard let panel, let view = panel.contentView, view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return (image, panel.frame)
    }

    /// Hides and shows the window (the speaker shortcut) without closing it, so
    /// nothing is torn down and it returns where it was.
    static func hide() {
        userHidden = true
        panel?.orderOut(nil)
    }

    /// Brings the window back from hidden, closed-to-the-Dock or covered,
    /// without activating the app.
    /// Up on another desktop, it comes to the one the teacher is on, a
    /// full-screen app's included, with no desktop switch and no activation, so
    /// Greenroom's main window stays away from the slides (owner, 2026-11-16:
    /// "They should open where I am"). A layout placing its pieces
    /// (`takingYouThere: false`) only raises it where it is: that can run on a
    /// display change, which no one clicked.
    static func show(takingYouThere: Bool = true) {
        // A placing pass (takingYouThere false) never undoes a Bar the person chose.
        if !takingYouThere, !MeetingSurfaceOwner.layoutMayRaiseWindow { return }
        userHidden = false
        guard let panel else { return }
        if takingYouThere, isElsewhere {
            panel.comeToThisDesktop(settledBehavior: [.managed, .fullScreenAuxiliary])
            return
        }
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        panel.orderFrontRegardless()
    }

    /// The meeting window is up on a desktop other than the one in view.
    static var meetingWindowIsElsewhere: Bool { isElsewhere }

    private static var isElsewhere: Bool {
        guard let panel else { return false }
        return MeetingSurfaces.meetingWindowElsewhere(visible: panel.isVisible, miniaturized: panel.isMiniaturized,
                                                      onActiveSpace: panel.isOnActiveSpace)
    }

    /// Puts a placed window back at its frame (Snap Windows Back, a display
    /// change, a layout edit). Other forms are the teacher's to place. Returns
    /// false when the window is a different size class than the frame wants
    /// (compact vs full): the next refresh makes a new one.
    @discardableResult
    static func place(frame: NSRect) -> Bool {
        guard let panel, let current = currentForm, case .placed = current else { return false }
        let sameClass = Form.placed(frame).matches(current)
        // A different class keeps the old form on record, so the next refresh
        // sees the mismatch and builds the window the new size needs.
        if sameClass { currentForm = .placed(frame) }
        panel.setFrame(frame, display: true)
        if !userHidden, MeetingSurfaceOwner.layoutMayRaiseWindow { panel.orderFrontRegardless() }
        return sameClass
    }

    /// The window's frame in screen coordinates, for the chat window to tuck
    /// under it.
    static var frameInScreen: NSRect? { panel?.frame }
    static var isSlot: Bool { currentForm?.isSlot ?? false }
    /// The layout placed the Meeting piece in a rectangle at full size (not compact).
    static var isPlacedFull: Bool { currentForm?.isPlaced == true && !isSlot }
    /// The display the meeting window is on, from where it sits (also while hidden).
    static var meetingScreen: NSScreen? {
        guard let frame = panel?.frame else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? panel?.screen
    }

    static func close() {
        root?.detachAllVideo()
        panel?.contentView = NSView()
        closePanelByCode()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        onUserClosed = nil
        shrinkInsteadOfMinimize = nil
        confirmClose = nil
        userHidden = false
        panel = nil
        root = nil
        currentForm = nil
        client = nil
        chatBridge = nil
        controls = nil
        log = nil
        micTimer?.invalidate()
        micTimer = nil
        micMonitor.stop()
    }

    /// Cues's cards, pushed once a second by the coordinator like the mic
    /// level. An empty state clears the block. No-op when the panel is closed.
    static func applyCues(_ state: CuesSurfaceState) {
        root?.applyCues(state)
    }

    /// The one confirmation the toolbar's Security menu needs. A destructive,
    /// rare action, so the alert's focus pull is the right behaviour (see
    /// RootView.confirm).
    static func confirmSuspend(_ action: @escaping () -> Void) {
        RootView.confirm(title: "Suspend all participant activities?",
                         message: "This stops every camera, microphone, share and chat in the meeting at once. Use it only if something has gone wrong.",
                         confirm: "Suspend", action: action)
    }

    fileprivate static func report(_ message: String) { log?(message) }
    fileprivate static var sdk: ZoomMeetingSDKClient? { client }
}

// MARK: - Root layout

/// Top bar, video grid, contextual strip, bottom bar.
///
/// Hand-laid rather than Auto Layout: the video views come from the SDK with
/// frames of their own and are re-framed every refresh anyway, so one layout
/// pass over explicit rects is both simpler and cheaper than maintaining
/// constraints for a grid whose shape changes as students join.
@MainActor
private final class RootView: NSView {

    /// Which form this window is. Fixed for the life of the view: a change of
    /// form is a new window (see `refresh`).
    private let form: ParticipantGridWindowController.Form
    /// The small slot form shows its top bar and toolbar only while the pointer
    /// is over it; there is no room to give them a permanent band.
    private var hoverChrome: Bool { form.isSlot }

    private let bottomBar = ToolbarFootView()
    /// The selected student's drawer, over the grid's right edge. Exists only
    /// while somebody is selected - see ParticipantInspectorView.
    private let inspector = ParticipantInspectorView(frame: .zero)
    /// Live only while the drawer is open. The panel is non-activating and is
    /// rarely key, so Escape has to be caught before the responder chain gets
    /// a chance not to deliver it.
    private var escapeMonitor: Any?
    /// Clicks, while the drawer is open. See `updateEscapeMonitor`.
    private var clickMonitor: Any?

    /// Below this the window stops being a grid with panels beside it.
    ///
    /// Phase 4: on a laptop the queue and the drawer would leave the class
    /// itself a strip, so they overlay the grid's right edge instead of taking
    /// a column off it. 900pt is where 320 + 300 + a usable canvas stops
    /// fitting side by side.
    private static let narrowWidth: CGFloat = 900
    private var isNarrow: Bool { bounds.width < Self.narrowWidth }
    private let gridHost = NSView()
    private let emptyState = NSTextField(labelWithString: "")

    private var tiles: [UInt32: TileView] = [:]
    private var selected: UInt32?
    private var lastGridShape: (cols: Int, rows: Int, count: Int) = (0, 0, -1)
    /// What the inspector was last built from. Deliberately excludes who is TALKING:
    /// that changes constantly and only affects tile rings, never a button.
    private var lastBarSignature = ""
    /// Held so a page change can re-attach video without waiting for the poll.
    private var lastVideoProvider: ((UInt32, NSRect) -> NSView?)?
    private var lastSelfProvider: ((NSRect) -> NSView?)?

    // MARK: Meeting form state

    private typealias ViewMode = MeetingViewMode
    private var viewMode: ViewMode = .gallery
    /// The layouts drawn right now (MeetingViewRules.swift): Multi-speaker shows as
    /// Speaker with fewer than three people. Rebuilt by `rebuildPlan`.
    private var plan = MeetingTilePlan.empty
    private var isSpeakerMode: Bool { plan.mode == .speaker }
    private var isMultiMode: Bool { plan.mode == .multiSpeaker }
    /// Speaker and Multi-speaker both keep a filmstrip.
    private var usesStrip: Bool { isSpeakerMode || isMultiMode }
    private let prefs = MeetingViewPrefs()
    private var shareLayout: MeetingShareLayout = .standard
    private var splitFraction = MeetingSplit.defaultFraction
    private var hideSelfView = false
    private var hideNoVideo = false
    private var featuredSpeaker: UInt32?
    /// Who holds Multi-speaker's large tiles: four places, kept for at least 3 s,
    /// fed from who is talking each time the roster is read.
    private var multiTracker = RecentSpeakers(limit: 4, minimumStay: 3)
    private var recentIDs: [UInt32] = []
    /// The stage as last laid out, for the divider's drag.
    private var lastSideStage = NSRect.zero
    /// The View menu's three choices, held as a control so the rest of the window
    /// keeps one way to read and write the mode. It is not on screen: the top bar's
    /// View button is the visible control.
    private lazy var modeControl = FirstClickSegmented(labels: MeetingViewMode.menuOrder.map(\.title),
                                                       trackingMode: .selectOne,
                                                       target: self, action: #selector(modeChanged(_:)))
    /// Zoom-style slim top bar, in the title-bar area (MeetingTopBar.swift).
    private let meetingTopBar = MeetingTopBarView(frame: .zero)
    private let stageChrome = MeetingTileChrome(frame: .zero)
    /// The frame to go back to when Fullscreen is turned off.
    private var frameBeforeFullscreen: NSRect?
    private var isFilling: Bool { frameBeforeFullscreen != nil }
    /// Speaker view's big picture. It is NOT a tile: a view has one superview,
    /// and the speaker's filmstrip tile is a different element. See
    /// ZoomMeetingSDKClient.stageView.
    private let stageHost = NSView()
    private let stageScrim = NSView()
    private let stageName = NSTextField(labelWithString: "")
    private var stageVideo: NSView?
    /// Who the stage shows: spotlight, then a local pin, then whoever speaks.
    private var stageSpeakerID: UInt32?
    // Shared screens (phase 2). A share takes the stage and forces Speaker; Gallery
    // gets a chip that says whose screen it is and brings it back.
    private var shareVideo: NSView?
    private lazy var shareChip: ClosureButton = {
        let button = ClosureButton { [weak self] in self?.shareChipPressed() }
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        button.layer?.cornerRadius = 13
        button.isHidden = true
        return button
    }()
    private lazy var selfShareCard = SelfShareCardView { [weak self] in self?.stopOwnShare() }
    /// A share chose the view; the one to go back to when it ends.
    private var shareForcedSpeaker = false
    /// Side-by-side: the share on the left, its own host, with a divider.
    private let shareHost = NSView()
    private let shareChrome = MeetingTileChrome(frame: .zero)
    private let splitDivider = MeetingSplitDivider(frame: .zero)
    private var viewBeforeShare: ViewMode?
    private var userChoseDuringShare = false
    private var sharedNow: (sourceID: UInt32, userID: UInt32, name: String)? {
        ParticipantGridWindowController.sdk?.shareViewer.current
    }
    private var selfSharingNow: Bool { ParticipantGridWindowController.sdk?.shareViewer.selfSharing ?? false }
    /// Someone else's share is the stage's picture.
    private var shareOnStage: Bool { plan.mode == .speaker && sharedNow != nil && !shareBeside }
    /// Someone else's share on the left of a view, with the divider between.
    private var shareBeside: Bool { !form.isSlot && sharedNow != nil && shareLayout.isSideBySide }
    /// Your own share, as a card where the picture would be.
    private var selfCardShown: Bool { plan.mode == .speaker && selfSharingNow && sharedNow == nil }
    private var lastStageProvider: ((UInt32, NSRect) -> NSView?)?
    private var lastReleaseStage: (() -> Void)?
    /// While the Shared screen window draws the share, the stage says so.
    private let shareElsewhere: NSTextField = {
        let label = NSTextField(labelWithString: "Showing in Shared screen window")
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = MeetingTheme.secondaryTextNS
        label.alignment = .center
        label.isHidden = true
        return label
    }()
    private let sidePanelHost = BarView()
    private let sidePanelDivider = NSView()
    /// Solid #1A1A1A under the panel: the system material would show the window through it.
    private let sidePanelBacking = NSView()
    private let sidePanelTitle = NSTextField(labelWithString: "")
    /// "12 \u{00B7} 2 hands up" beside the People title.
    private let sidePanelCount = NSTextField(labelWithString: "")
    /// Copies the invite link, the one `meetingInvite().joinURL` gives.
    private lazy var inviteButton: ClosureButton = {
        let button = ClosureButton { [weak self] in self?.controls?.copyInviteLink() }
        button.title = "Invite"
        button.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.toolTip = "Copy the invite link"
        button.setAccessibilityLabel("Copy invite link")
        return button
    }()
    private lazy var sidePanelClose = MeetingBarButton { [weak self] in self?.controls?.sidePanel = nil }
    private var chatHost: NSView?
    private let peopleView = MeetingPeopleView(frame: .zero)
    private var controlsSub: AnyCancellable?
    private var chromeHover = false
    private var chromeHideWork: DispatchWorkItem?
    private var controls: MeetingControlsModel? { ParticipantGridWindowController.controls }
    /// DESIGN.md's drawer range is 280-320pt; the side panel takes the top.
    private static let sidePanelWidth: CGFloat = 320
    private static let selfPreviewSize = NSSize(width: 192, height: 108)
    private static let stripHeight: CGFloat = MeetingTheme.stripHeight

    private var roster: [ZoomMeetingSDKClient.RosterEntry] = []
    private var page = 0
    /// The queue's own scroller, at the top of the People panel: Cues's cards.
    private let queueScroll = NSScrollView()
    /// Your own picture, over the grid.
    private let selfPreview = SelfPreviewView(frame: .zero)
    private var lastMicLevel: Double = 0
    private var selfVideo: NSView?
    /// Cues's cards, in the People panel's container. Its own view with a
    /// discipline: a fixed pool, updated in place, one measuring/placing walk.
    private let cuesBlock = CuesRailBlock(frame: .zero)
    /// The exception panel on the right of the grid. Fixed width.
    private lazy var liveQueue = LiveQueueView(assist: cuesBlock)
    /// When each currently-raised hand went up.
    ///
    /// The SDK reports `isRaisingHand` as a bare bool with no timestamp, so
    /// raise order is remembered here or not at all. It has to be remembered:
    /// a set of raised hands tells a teacher how many, and the one thing they
    /// actually need from it is who to call on first.
    private var handRaisedAt: [UInt32: Date] = [:]
    private var pagePrev: NSButton?
    private var pageNext: NSButton?
    private var flags = ZoomMeetingSDKClient.RoomFlags()
    private var waiting: [(id: UInt32, name: String)] = []
    private var session = ParticipantGridWindowController.SessionInfo()
    /// How many students fit on one page before the carousel appears. Fixed
    /// rather than computed from the area: a page size that changed as people
    /// joined would reshuffle faces mid-lesson, which is exactly when a teacher
    /// is relying on their position.
    /// How many students fit before the carousel appears, derived from the grid's
    /// real size rather than fixed.
    ///
    /// It was a flat 9, which on a small window meant nine unreadable slivers and
    /// on a large one wasted room. Quantised into a few steps rather than computed
    /// exactly, because a page size that changed by one on every few pixels of
    /// resize would reshuffle faces while a teacher was looking at them.
    private var perPage: Int {
        // Speaker view's filmstrip is one row, as many as fit; Multi-speaker adds its large tiles.
        if isSpeakerMode { return stripCapacity }
        if isMultiMode { return max(1, plan.large.count) + stripCapacity }
        let area = gridHost.bounds
        guard area.width > 0, area.height > 0 else { return 9 }
        // ~260x150 is the smallest tile a face and a name label stay legible in.
        let fits = Int(area.width / 260) * Int(area.height / 150)
        switch fits {
        case ..<2: return 1
        case ..<4: return 2
        case ..<6: return 4
        case ..<9: return 6
        case ..<12: return 9
        default: return 12
        }
    }
    /// How many 16:9 filmstrip tiles fit along the strip, capped so the strip
    /// stays a strip. Quantised by whole tiles, so it moves only when a tile does.
    private var stripCapacity: Int {
        MeetingVideoLayout.stripCapacity(width: max(0, gridHost.bounds.width - stripReservedRight),
                                         tileHeight: Self.stripHeight - 8)
    }
    /// Multi-speaker's strip leaves its right end to your preview.
    private var stripReservedRight: CGFloat {
        guard isMultiMode, !hideSelfView else { return 0 }
        return ((Self.stripHeight - 8) * 16 / 9).rounded() + 8
    }
    /// Who the gallery or the filmstrip lists: everyone, or everyone but the
    /// person already on the stage.
    private var listed: [ZoomMeetingSDKClient.RosterEntry] {
        let byID = Dictionary(roster.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return plan.listed.compactMap { byID[$0] }
    }

    /// Settles who has a tile and where, from the roster, the view, the two
    /// filters and the recent speakers. Cheap; called whenever any of them moves.
    private func rebuildPlan() {
        let others = roster.map { MeetingTileCandidate(id: $0.id, videoOn: $0.videoOn) }
        let choice = roster.first(where: \.isSpotlighted)?.id ?? roster.first(where: \.isPinned)?.id ?? featuredSpeaker
        let sharing = sharedNow != nil && !shareBeside
        plan = MeetingTilePlan.make(others: others, mode: viewMode, hideNoVideo: hideNoVideo, stageChoice: choice,
                                    recentSpeakers: recentIDs, shareOnStage: sharing)
        stageSpeakerID = plan.stage
    }

    /// The tracker takes who is talking now and the people the filter leaves.
    private func feedMultiSpeakers() {
        let now = Date()
        let shown = MeetingTileFilter.apply(roster.map { MeetingTileCandidate(id: $0.id, videoOn: $0.videoOn) },
                                            hideNoVideo: hideNoVideo).map(\.id)
        multiTracker.heard(roster.filter(\.isTalking).map(\.id), selfID: nil, now: now)
        multiTracker.update(present: Set(shown), now: now)
        recentIDs = multiTracker.occupied.map(\.userID)
    }
    init(frame frameRect: NSRect, form: ParticipantGridWindowController.Form) {
        self.form = form
        super.init(frame: frameRect)
        wantsLayer = true
        // The meeting window's background is the frost behind it (WindowFrost).
        layer?.backgroundColor = NSColor.clear.cgColor

        addSubview(bottomBar)
        gridHost.wantsLayer = true
        gridHost.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(gridHost)

        queueScroll.drawsBackground = false
        queueScroll.hasVerticalScroller = true
        queueScroll.scrollerStyle = .overlay
        queueScroll.autohidesScrollers = true
        queueScroll.documentView = liveQueue

        // The preview goes on the window, above the grid, so the grid never
        // measures around it. Actions are the two that are about you.
        selfPreview.actions = SelfPreviewView.Actions(
            toggleMute: {
                guard let sdk = ParticipantGridWindowController.sdk else { return }
                let muted = sdk.iAmMuted
                Self.perform(muted ? "Unmuted yourself" : "Muted yourself") { $0.setMyMute(!muted) }
            },
            toggleVideo: {
                guard let sdk = ParticipantGridWindowController.sdk else { return }
                let on = sdk.myVideoIsOn
                Self.perform(on ? "Stopped your video" : "Started your video") { $0.setMyVideo(on: !on) }
            })
        addSubview(selfPreview)

        inspector.onClose = { [weak self] in
            guard let self else { return }
            self.selected = nil
            self.selectionChanged()
        }
        inspector.isHidden = true
        addSubview(inspector)

        emptyState.font = .systemFont(ofSize: 15)
        emptyState.textColor = .secondaryLabelColor
        emptyState.alignment = .center
        emptyState.maximumNumberOfLines = 3
        emptyState.usesSingleLineMode = false
        emptyState.lineBreakMode = .byWordWrapping
        addSubview(emptyState)

        setupMeetingForm()
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { false }

    // MARK: Update

    func update(roster: [ZoomMeetingSDKClient.RosterEntry],
                flags: ZoomMeetingSDKClient.RoomFlags,
                waiting: [(id: UInt32, name: String)],
                session: ParticipantGridWindowController.SessionInfo,
                featured: UInt32?,
                videoProvider: @escaping (UInt32, NSRect) -> NSView?,
                selfProvider: @escaping (NSRect) -> NSView?,
                stageProvider: @escaping (UInt32, NSRect) -> NSView?,
                releaseStage: @escaping () -> Void) {
        self.roster = roster
        featuredSpeaker = featured
        syncShareMode()
        feedMultiSpeakers()
        rebuildPlan()
        lastStageProvider = stageProvider
        lastReleaseStage = releaseStage
        self.flags = flags
        self.waiting = waiting
        self.session = session

        // A selection whose owner left must not linger: its actions would apply
        // to a user ID the SDK has already recycled.
        if let selected, !roster.contains(where: { $0.id == selected }) { self.selected = nil }

        // Stamp new hands, forget lowered ones. Dropping the entry on lower is
        // what makes a hand that goes up again go to the BACK of the queue,
        // which is the fair reading and the one a class will expect.
        var raised: Set<UInt32> = []
        for entry in roster where entry.isRaisingHand {
            raised.insert(entry.id)
            if handRaisedAt[entry.id] == nil { handRaisedAt[entry.id] = Date() }
        }
        handRaisedAt = handRaisedAt.filter { raised.contains($0.key) }

        // Clamp rather than reset. If someone leaves while the teacher is on the
        // last page, dropping them to page one would lose their place; this only
        // moves them when the page they are on no longer exists.
        let pages = max(1, Int(ceil(Double(listed.count) / Double(perPage))))
        page = min(page, pages - 1)

        syncTiles()
        updateChromeText()
        if let popOut = PeoplePopOutController.view { feedPeople(popOut) }
        // Rebuilt ONLY when something the inspector actually shows has changed:
        // tearing buttons down on every tick of a one-second poll races the
        // accessibility tree and drops clicks that land mid-teardown.
        let signature = barSignature()
        if signature != lastBarSignature {
            lastBarSignature = signature
            rebuildContextBar()
        }
        layoutEverything()
        // Video is attached only once the tiles have real frames. The SDK
        // resizes its render element to whatever rect it is handed, and handing
        // it the zero rect a freshly created tile still has produces an element
        // that never draws.
        attachVideo(videoProvider)
        attachSelfVideo(selfProvider)
        attachStage()
        updateMeetingChrome()
    }

    private func syncTiles() {
        // Only the current page. An off-page student keeps no tile and therefore
        // no video subscription - a class of forty should not mean forty live
        // streams for twelve visible faces.
        let visible = pageRoster
        let live = Set(visible.map(\.id))
        for (id, tile) in tiles where !live.contains(id) {
            tile.detachVideo()
            tile.removeFromSuperview()
            tiles.removeValue(forKey: id)
        }
        for entry in visible {
            let tile = tiles[entry.id] ?? {
                let made = TileView(userID: entry.id)
                made.onSelect = { [weak self] id in
                    guard let self else { return }
                    // Clicking the selected tile clears it, so there is always a
                    // way back to the room-wide controls without a Done button.
                    self.selected = (self.selected == id) ? nil : id
                    self.selectionChanged()
                }
                made.onSpotlightInWindow = { [weak self] id in
                    guard let name = self?.roster.first(where: { $0.id == id })?.name else { return }
                    MeetingViewWindows.spotlight(userID: id, name: name)
                }
                tiles[entry.id] = made
                gridHost.addSubview(made)
                return made
            }()
            let badges = tileBadges(entry.id)
            tile.apply(entry: entry, isSelected: selected == entry.id,
                       reaction: badges.reaction, feedback: badges.feedback)
        }
    }

    /// What a tile shows from the room's events: a three-second reaction and the
    /// persistent feedback badge.
    private func tileBadges(_ id: UInt32) -> (reaction: String?, feedback: String?) {
        guard let ledger = ParticipantGridWindowController.sdk?.roomEvents.reactions else { return (nil, nil) }
        return (ledger.reaction(for: id, now: Date()), ledger.feedbackLabel(for: id))
    }

    /// The SDK renders into a view it owns; the tile only parents it, and only
    /// when it changes. Re-parenting a live video view every refresh would
    /// flicker the whole wall.
    private func attachVideo(_ videoProvider: @escaping (UInt32, NSRect) -> NSView?) {
        lastVideoProvider = videoProvider
        for entry in pageRoster {
            guard let tile = tiles[entry.id], !tile.bounds.isEmpty else { continue }
            tile.attach(video: videoProvider(entry.id, tile.videoBounds))
        }
    }

    /// Selection changes the tile rings, the contextual strip, and therefore
    /// the height available to the grid - so all three are redone, without
    /// waiting for the next poll. A click has to feel immediate.
    private func selectionChanged() {
        for entry in pageRoster {
            let badges = tileBadges(entry.id)
            tiles[entry.id]?.apply(entry: entry, isSelected: selected == entry.id,
                                   reaction: badges.reaction, feedback: badges.feedback)
        }
        lastBarSignature = barSignature()
        rebuildContextBar()
        layoutEverything()
    }

    /// Fed at 20Hz from the mic monitor, independent of the roster poll.
    func applyMicLevel(_ level: Double, running: Bool) {
        selfPreview.setLevel(running ? level : 0)
        guard running else { return }
        lastMicLevel = level
    }

    /// Who is on screen right now, for the caller's stream pruning.
    var visibleIDs: Set<UInt32> { Set(pageRoster.map(\.id)) }

    /// The self view, in its own render element so it never contends with the
    /// speaker window for one NSView.
    private func attachSelfVideo(_ provider: @escaping (NSRect) -> NSView?) {
        lastSelfProvider = provider
        let host = selfPreview.videoHost
        guard !host.bounds.isEmpty else { return }
        guard let view = provider(host.bounds) else { return }
        if selfVideo !== view {
            selfVideo?.removeFromSuperview()
            view.autoresizingMask = [.width, .height]
            host.addSubview(view)
            selfVideo = view
        }
        view.frame = host.bounds
    }

    func detachAllVideo() {
        tiles.values.forEach { $0.detachVideo() }
        selfVideo?.removeFromSuperview()
        selfVideo = nil
        stageVideo?.removeFromSuperview()
        stageVideo = nil
        lastReleaseStage?()
        shareVideo?.removeFromSuperview()
        shareVideo = nil
        ParticipantGridWindowController.sdk?.shareViewer.releaseElement()
    }

    // MARK: Layout

    /// The students on the current page. Everything downstream - layout, video
    /// subscription, ring state - works from this rather than the whole roster,
    /// so a class of forty does not mean forty live video streams.
    private var pageRoster: [ZoomMeetingSDKClient.RosterEntry] {
        let list = listed
        let start = page * perPage
        guard start < list.count else { return [] }
        return Array(list[start..<min(start + perPage, list.count)])
    }

    /// Puts your own picture at `rect` (in the grid host's space): in Gallery and
    /// Multi-speaker you are an ordinary tile of the grid or strip, placed last.
    private func placeSelf(_ rect: CGRect?) {
        guard let rect else { return }
        selfPreview.frame = rect.offsetBy(dx: gridHost.frame.minX, dy: gridHost.frame.minY)
        selfPreview.layoutSubtreeIfNeeded()
    }

    private func layoutTiles() {
        if isMultiMode { layoutMultiSpeaker(); return }
        if isSpeakerMode { layoutFilmstrip(); return }
        let visible = pageRoster
        let lastPage = (page + 1) * perPage >= listed.count
        let withSelf = !hideSelfView && lastPage
        placeSelf(MeetingVideoLayout.galleryWithSelf(count: visible.count, includeSelf: withSelf,
                                                     in: gridHost.bounds.size).me)
        guard !visible.isEmpty else { return }
        // Zoom's gallery: an even grid of 16:9 tiles, 4pt apart, centred, you last.
        let frames = MeetingVideoLayout.galleryWithSelf(count: visible.count, includeSelf: withSelf,
                                                        in: gridHost.bounds.size).others
        let shape = (0, 0, visible.count)
        let animate = lastGridShape.count >= 0 && shape != lastGridShape
        lastGridShape = shape
        for (entry, target) in zip(visible, frames) {
            guard let tile = tiles[entry.id], tile.frame != target else { continue }
            if animate, !tile.frame.isEmpty {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    tile.animator().frame = target
                }
            } else {
                tile.frame = target
            }
        }
    }

    // MARK: Meeting form

    /// The meeting window's views: a Gallery/Speaker control in the top bar, the
    /// stage, one side panel on the right and the toolbar along the foot. The
    /// self view is the corner preview, and Cues sits at the top of the People panel.
    private func setupMeetingForm() {
        viewMode = form.isSlot ? .speaker : prefs.view
        shareLayout = prefs.shareLayout
        splitFraction = prefs.splitFraction
        hideSelfView = prefs.hideSelfView
        hideNoVideo = prefs.hideNoVideo
        modeControl.selectedSegment = viewMode.segmentIndex
        rebuildPlan()
        modeControl.setAccessibilityLabel("Video layout")
        meetingTopBar.actions = MeetingTopBarView.Actions(
            showInfo: { [weak self] anchor in self?.showMeetingInfoPopover(from: anchor) },
            viewMenu: { [weak self] in self?.viewMenuEntries() ?? [] },
            shrink: { [weak self] in self?.controls?.collapseMeeting() },
            tipClosed: { MeetingShrinkTip.markDone() })
        addSubview(meetingTopBar)

        // A black stage: letterboxing against window-background grey reads as a
        // rendering fault.
        stageHost.wantsLayer = true
        stageHost.layer?.backgroundColor = MeetingTheme.tileNS.cgColor
        stageHost.layer?.cornerRadius = MeetingTheme.tileRadius
        stageHost.layer?.masksToBounds = true
        addSubview(stageHost, positioned: .below, relativeTo: emptyState)
        // Layer-backed so the caption composites ABOVE the SDK's render surface.
        stageScrim.wantsLayer = true
        stageScrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        stageHost.addSubview(stageScrim)
        stageScrim.isHidden = true      // the chrome below draws the name instead
        stageHost.addSubview(stageChrome)
        // Side-by-side's share, on its own host so the stage can hold the speaker.
        shareHost.wantsLayer = true
        shareHost.layer?.backgroundColor = MeetingTheme.tileNS.cgColor
        shareHost.layer?.cornerRadius = MeetingTheme.tileRadius
        shareHost.layer?.masksToBounds = true
        shareHost.isHidden = true
        addSubview(shareHost, positioned: .below, relativeTo: emptyState)
        shareHost.addSubview(shareChrome)
        splitDivider.isHidden = true
        splitDivider.onDrag = { [weak self] x in self?.dragSplit(toBoundaryX: x) }
        splitDivider.onEnd = { [weak self] in
            guard let self else { return }
            self.prefs.splitFraction = self.splitFraction
        }
        splitDivider.onReset = { [weak self] in
            guard let self else { return }
            self.splitFraction = MeetingSplit.defaultFraction
            self.prefs.splitFraction = self.splitFraction
            self.relayoutAfterSplit()
        }
        selfShareCard.isHidden = true
        stageHost.addSubview(selfShareCard)
        stageName.font = .systemFont(ofSize: 13, weight: .medium)
        stageName.textColor = .white
        stageName.lineBreakMode = .byTruncatingTail
        stageScrim.addSubview(stageName)

        sidePanelHost.isHidden = true
        sidePanelBacking.wantsLayer = true
        sidePanelBacking.layer?.backgroundColor = NSColor.clear.cgColor // the window's frost shows through
        sidePanelHost.addSubview(sidePanelBacking)
        sidePanelTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        sidePanelTitle.textColor = .white
        sidePanelDivider.wantsLayer = true
        sidePanelDivider.layer?.backgroundColor = MeetingTheme.hairlineNS.cgColor
        sidePanelClose.isBordered = false
        sidePanelClose.imagePosition = .imageOnly
        sidePanelClose.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close panel")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        sidePanelClose.contentTintColor = MeetingTheme.secondaryTextNS
        sidePanelClose.toolTip = "Close panel"
        sidePanelCount.font = .systemFont(ofSize: 12)
        sidePanelCount.textColor = MeetingTheme.secondaryTextNS
        for view in [sidePanelDivider, sidePanelTitle, sidePanelCount, inviteButton, sidePanelClose, queueScroll, peopleView] as [NSView] {
            sidePanelHost.addSubview(view)
        }
        peopleView.onSelect = { [weak self] id in
            if id == ParticipantGridWindowController.myEntry?.id { return }
            self?.selected = id
            self?.selectionChanged()
        }
        // The waiting room's three answers, and the footer's two room-wide ones.
        // Each is `perform`: one definition, one log line, one redraw.
        peopleView.onAdmit = { [weak self] id in
            let name = self?.waiting.first { $0.id == id }?.name ?? "them"
            Self.perform("Admitted \(name)") { $0.admitFromWaitingRoom(userID: id) }
        }
        peopleView.onDeny = { [weak self] id in
            let name = self?.waiting.first { $0.id == id }?.name ?? "them"
            Self.perform("Denied \(name)") { $0.denyWaiting(userID: id) }
        }
        peopleView.onInvite = { [weak self] in self?.controls?.copyInviteLink() }
        peopleView.onAdmitAll = { Self.perform("Admitted everyone waiting") { $0.admitEveryoneWaiting() } }
        peopleView.onMuteAll = { Self.perform("Muted everyone") { $0.muteEveryone() } }
        peopleView.onAskAllToUnmute = { Self.perform("Asked everyone to unmute") { $0.askEveryoneToUnmute() } }

        if let controls {
            let host = FirstMouseHostingView(rootView: MeetingToolbarView(model: controls, coordinator: controls.coordinator)
                .tint(Brand.green))
            host.frame = bottomBar.bounds
            host.autoresizingMask = [.width, .height]
            bottomBar.addSubview(host)
            // Published fires before the value lands; lay out on the next turn.
            controlsSub = controls.$sidePanel.sink { [weak self] _ in
                DispatchQueue.main.async { self?.sidePanelChanged() }
            }
        }
        // Chrome last, so in the hover form it sits over the video.
        for view in [splitDivider, shareChip, selfPreview, sidePanelHost, inspector, bottomBar] as [NSView] {
            addSubview(view)
        }
    }

    func cycleViewMode() -> Bool {
        guard !form.isSlot else { return false }
        let others = roster.count + 1 >= MeetingTilePlan.multiSpeakerMinimumPeople
        modeControl.selectedSegment = viewMode.next(multiSpeakerAvailable: others).segmentIndex
        modeChanged(modeControl)
        return true
    }

    /// The View button's menu. Without a share: Speaker, Gallery, Multi-speaker.
    /// While someone shares: Standard and the three Side-by-side layouts. Then the
    /// two tile filters, then Fullscreen.
    private func viewMenuEntries() -> [MenuEntry] {
        var entries: [MenuEntry] = []
        if !form.isSlot {
            if sharedNow != nil {
                for layout in MeetingShareLayout.allCases {
                    entries.append(.item(layout.menuTitle, checked: shareLayout == layout) { [weak self] in
                        self?.chooseShareLayout(layout)
                    })
                }
            } else {
                for mode in MeetingViewMode.menuOrder {
                    entries.append(.item(mode.title, checked: viewMode == mode) { [weak self] in self?.chooseMode(mode) })
                }
            }
            entries.append(.separator)
            entries.append(.item("Hide self view", checked: hideSelfView) { [weak self] in
                guard let self else { return }
                self.hideSelfView.toggle()
                self.prefs.hideSelfView = self.hideSelfView
                self.applyViewChange()
            })
            entries.append(.item("Hide participants with video off", checked: hideNoVideo) { [weak self] in
                guard let self else { return }
                self.hideNoVideo.toggle()
                self.prefs.hideNoVideo = self.hideNoVideo
                self.applyViewChange()
            })
            entries.append(.separator)
        }
        entries.append(.item(isFilling ? "Exit Fullscreen" : "Fullscreen") { [weak self] in self?.toggleFill() })
        return entries
    }

    private func chooseMode(_ mode: ViewMode) {
        guard viewMode != mode else { return }
        modeControl.selectedSegment = mode.segmentIndex
        modeChanged(modeControl)
    }

    /// Standard, or the share beside a layout. Remembered for the next share; while
    /// one is up it takes effect now, and the view the person had comes back after.
    private func chooseShareLayout(_ layout: MeetingShareLayout) {
        shareLayout = layout
        prefs.shareLayout = layout
        if sharedNow != nil, !form.isSlot {
            setViewMode(layout.sideMode ?? .speaker)
            applyViewChange()
        }
    }

    private func dragSplit(toBoundaryX x: CGFloat) {
        splitFraction = MeetingSplit.fraction(forBoundaryX: x, in: lastSideStage)
        relayoutAfterSplit()
    }

    private func relayoutAfterSplit() {
        layoutEverything()
        if let provider = lastVideoProvider { attachVideo(provider) }
        attachStage()
    }

    /// Fullscreen fills the display the window is on, over the menu bar and Dock
    /// notwithstanding, and goes back to where it was. It is not a macOS
    /// fullscreen Space: a window in a Space cannot be re-framed (2026-08-24).
    private func toggleFill() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        if let before = frameBeforeFullscreen {
            frameBeforeFullscreen = nil
            window.setFrame(before, display: true, animate: true)
        } else {
            frameBeforeFullscreen = window.frame
            window.setFrame(screen.frame, display: true, animate: true)
        }
        updateMeetingTopBar()
    }

    private var infoPopover: NSPopover?

    private func showMeetingInfoPopover(from anchor: NSView) {
        if let infoPopover, infoPopover.isShown { infoPopover.close(); return }
        let invite = ParticipantGridWindowController.sdk?.meetingInvite()
        let facts = MeetingMenus.MeetingFacts(number: invite?.number ?? "", passcode: invite?.passcode ?? "",
                                              joinURL: invite?.joinURL ?? "")
        let view = MeetingInfoView(title: invite?.topic ?? "", facts: facts) { text, what in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            ParticipantGridWindowController.report("\(what) copied.")
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = NSHostingController(rootView: view)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        infoPopover = popover
    }

    private func updateMeetingTopBar() {
        var state = MeetingTopBarState()
        state.title = session.presetName.isEmpty ? "Meeting" : session.presetName
        state.recording = session.isRecording
        state.mode = viewMode
        state.isFullscreen = isFilling
        state.canShrink = !form.isSlot
        state.shrinkShortcut = ShortcutStore.shared.bindings.combo(for: .action(.shrinkToBar))?.glyphs ?? ""
        meetingTopBar.apply(state)
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        let mode = ViewMode(segment: sender.selectedSegment)
        let beside = shareBeside
        setViewMode(mode)
        if beside {
            // Beside a share the choice is the share layout; the view the person had
            // before the share is what comes back when it ends.
            shareLayout = .sideBySide(mode)
            prefs.shareLayout = shareLayout
        } else {
            // A choice made while a share is up stays: it is not undone when the share ends.
            if shareForcedSpeaker { userChoseDuringShare = true }
            if !form.isSlot { prefs.view = viewMode }
        }
        applyViewChange()
    }

    /// A different list of people is on screen, so tiles, then layout, then
    /// video, in that order and without waiting for the poll.
    private func applyViewChange() {
        rebuildPlan()
        let pages = max(1, Int(ceil(Double(listed.count) / Double(perPage))))
        page = min(page, pages - 1)
        syncTiles()
        updateChromeText()
        layoutEverything()
        if let provider = lastVideoProvider { attachVideo(provider) }
        attachStage()
    }

    private func sidePanelChanged() {
        controls?.refresh()
        layoutEverything()
    }

    /// Speaker view's picture: one element, handed whoever is on the stage, or a
    /// shared screen when somebody else is sharing. Beside a share the screen has
    /// its own host on the left and the stage keeps the speaker.
    private func attachStage() {
        let viewer = ParticipantGridWindowController.sdk?.shareViewer
        let shareTarget: NSView? = shareOnStage ? stageHost : (shareBeside ? shareHost : nil)
        if let viewer, let target = shareTarget {
            drawShare(viewer, in: target)
        } else {
            shareElsewhere.isHidden = true
            if shareVideo != nil {
                shareVideo?.removeFromSuperview()
                shareVideo = nil
            }
            if viewer?.windowOwnsShare != true { viewer?.releaseElement() }
        }
        if shareOnStage {
            // The speaker's 720p stream is given back while a screen is shown.
            if stageVideo != nil {
                stageVideo?.removeFromSuperview()
                stageVideo = nil
                lastReleaseStage?()
            }
            return
        }
        guard isSpeakerMode, let id = stageSpeakerID, let provider = lastStageProvider else {
            stageVideo?.removeFromSuperview()
            stageVideo = nil
            lastReleaseStage?()
            return
        }
        guard !stageHost.bounds.isEmpty else { return }
        guard let view = provider(id, stageHost.bounds) else { return }
        if stageVideo !== view {
            stageVideo?.removeFromSuperview()
            view.autoresizingMask = [.width, .height]
            stageHost.addSubview(view, positioned: .below, relativeTo: stageScrim)
            stageVideo = view
        }
        view.frame = stageHost.bounds
    }

    /// The share in `host`. A share that was drawn in the other host is given
    /// back and made again: an element is not moved while it renders.
    private func drawShare(_ viewer: ShareViewer, in host: NSView) {
        let anchor: NSView = host === stageHost ? stageScrim : shareChrome
        if viewer.windowOwnsShare {
            shareVideo?.removeFromSuperview()
            shareVideo = nil
            if shareElsewhere.superview !== host {
                shareElsewhere.removeFromSuperview()
                host.addSubview(shareElsewhere, positioned: .below, relativeTo: anchor)
            }
            shareElsewhere.isHidden = false
            shareElsewhere.frame = NSRect(x: 12, y: host.bounds.midY - 12,
                                          width: max(0, host.bounds.width - 24), height: 24)
            return
        }
        shareElsewhere.isHidden = true
        if let video = shareVideo, video.superview !== host {
            video.removeFromSuperview()
            shareVideo = nil
            viewer.releaseElement()
        }
        guard !host.bounds.isEmpty, let view = viewer.stageView(frame: host.bounds) else { return }
        if shareVideo !== view {
            shareVideo?.removeFromSuperview()
            view.autoresizingMask = [.width, .height]
            host.addSubview(view, positioned: .below, relativeTo: anchor)
            shareVideo = view
        }
        view.frame = host.bounds
        // Only now, with the view in a visible window: a share asked to draw
        // before that never does (the video stage's lesson).
        viewer.renderIfReady()
    }

    // MARK: Shared screens

    /// A share starting takes the view its layout names (Standard is Speaker with
    /// the share on the stage); its ending puts the view back, unless the person
    /// picked one in between.
    private func syncShareMode() {
        let sharing = sharedNow != nil
        if sharing, !shareForcedSpeaker {
            shareForcedSpeaker = true
            userChoseDuringShare = false
            viewBeforeShare = viewMode
            let forced = shareLayout.sideMode ?? .speaker
            if viewMode != forced, !form.isSlot { setViewMode(forced) }
            ZoomMeetingSDKClient.videoLog("Share view: \(shareLayout.menuTitle) (was \(viewBeforeShare?.title ?? "?"))")
        } else if !sharing, shareForcedSpeaker {
            shareForcedSpeaker = false
            if !userChoseDuringShare, let before = viewBeforeShare, before != viewMode, !form.isSlot {
                setViewMode(before)
            }
            viewBeforeShare = nil
            ZoomMeetingSDKClient.videoLog("Share view: share ended, view restored")
        }
    }

    private func setViewMode(_ mode: ViewMode) {
        viewMode = mode
        modeControl.selectedSegment = mode.segmentIndex
        page = 0
        rebuildPlan()
    }

    private func shareChipPressed() {
        guard let viewer = ParticipantGridWindowController.sdk?.shareViewer else { return }
        if sharedNow == nil {
            // Your own share, in Gallery: the chip is its Stop.
            stopOwnShare()
            return
        }
        let choices = viewer.choices
        if choices.count > 1 {
            let entries: [MenuEntry] = choices.map { choice in
                .item("\(choice.name)\u{2019}s screen", checked: choice.sourceID == viewer.current?.sourceID) { [weak self] in
                    viewer.pick(choice.sourceID)
                    self?.showShareOnStage()
                }
            }
            MeetingMenuBuilder.popUp(entries, above: shareChip, below: true)
        } else if !shareBeside {
            showShareOnStage()
        }
    }

    /// Back to Speaker, where the share is drawn.
    private func showShareOnStage() {
        guard !shareBeside, viewMode != .speaker else { return }
        modeControl.selectedSegment = ViewMode.speaker.segmentIndex
        modeChanged(modeControl)
    }

    private func stopOwnShare() {
        Self.perform("Stopped sharing") { $0.stopShare() }
    }

    /// The chip over the stage or gallery, and your own share's card.
    private func layoutShareChip(in stage: NSRect) {
        let viewer = ParticipantGridWindowController.sdk?.shareViewer
        var text: String?
        var help = ""
        if let now = sharedNow, let viewer {
            // On the stage the caption already says whose screen it is; the chip
            // is there to choose between several, and in Gallery to bring it back.
            if !shareOnStage && !shareBeside {
                text = "Viewing \(now.name)\u{2019}s screen \u{00B7} Show"
                help = "Show \(now.name)\u{2019}s screen again."
            } else if viewer.selection.hasChoice {
                text = "\(now.name)\u{2019}s screen \u{25BE}"
                help = "Several people are sharing. Choose whose screen to see."
            }
        } else if selfSharingNow, !selfCardShown {
            text = "You are sharing your screen \u{00B7} Stop"
            help = "Stop sharing your screen"
        }
        guard let text else { shareChip.isHidden = true; return }
        shareChip.isHidden = false
        shareChip.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white])
        shareChip.toolTip = help
        shareChip.setAccessibilityLabel(text)
        shareChip.sizeToFit()
        let width = min(stage.width - 24, shareChip.frame.width + 24)
        shareChip.frame = NSRect(x: stage.midX - width / 2, y: stage.maxY - 12 - 26, width: width, height: 26)
    }

    /// Your corner preview and the roster, rewritten once a second.
    private func updateMeetingChrome() {
        if let sdk = ParticipantGridWindowController.sdk {
            selfPreview.apply(muted: sdk.iAmMuted, videoOn: sdk.myVideoIsOn, level: lastMicLevel)
        }
        if shareBeside, let now = sharedNow {
            shareChrome.apply(MeetingTileModel(name: "\(now.name)\u{2019}s screen"))
        }
        if shareOnStage, let now = sharedNow {
            stageName.stringValue = "\(now.name)\u{2019}s screen"
            stageChrome.apply(MeetingTileModel(name: stageName.stringValue))
        } else if let id = stageSpeakerID, let entry = roster.first(where: { $0.id == id }) {
            var name = entry.name
            if entry.isHost { name += " \u{00B7} host" } else if entry.isCoHost { name += " \u{00B7} co-host" }
            stageName.stringValue = name
            stageChrome.apply(MeetingTileModel(name: entry.name, muted: entry.isMuted && entry.hasJoinedAudio,
                                               videoOn: entry.videoOn, speaking: entry.isTalking, handUp: entry.isRaisingHand))
        }
        updateMeetingTopBar()
    }

    private func updatePeopleRows() { applyPeople(to: peopleView) }

    /// The bar's People pop-out shows the same list. A row opens the Meeting
    /// window on that person, since their actions live in its inspector.
    private func feedPeople(_ popOut: MeetingPeopleView) {
        popOut.onSelect = { [weak self] id in
            guard let self, id != ParticipantGridWindowController.myEntry?.id else { return }
            self.selected = id
            self.selectionChanged()
            self.controls?.openPeopleInWindow()
        }
        popOut.onAdmit = peopleView.onAdmit
        popOut.onDeny = peopleView.onDeny
        popOut.onInvite = peopleView.onInvite
        popOut.onAdmitAll = peopleView.onAdmitAll
        popOut.onMuteAll = peopleView.onMuteAll
        popOut.onAskAllToUnmute = peopleView.onAskAllToUnmute
        applyPeople(to: popOut)
    }

    private func applyPeople(to target: MeetingPeopleView) {
        let queue = handQueue
        let handIDs = Set(queue.map(\.id))
        func row(_ entry: ZoomMeetingSDKClient.RosterEntry) -> MeetingPeopleView.Row {
            var tags: [String] = []
            if entry.isHost { tags.append("Host") } else if entry.isCoHost { tags.append("Co-host") }
            if entry.isMyself { tags.append("me") }
            var detail: [String] = []
            if entry.isSpotlighted { detail.append("spotlit") }
            return .init(id: entry.id, name: entry.name, tags: tags, detail: detail.joined(separator: " \u{00B7} "),
                         handUp: entry.isRaisingHand, muted: entry.isMuted, hasAudio: entry.hasJoinedAudio,
                         cameraOff: !entry.videoOn, selected: selected == entry.id)
        }
        // You first, as Zoom lists you. Your own row opens nothing: there is no
        // inspector for yourself, and the toolbar is where your controls are.
        var mine: [MeetingPeopleView.Row] = []
        if let me = ParticipantGridWindowController.myEntry {
            var entry = row(me)
            if let sdk = ParticipantGridWindowController.sdk {
                entry.muted = sdk.iAmMuted
                entry.cameraOff = !sdk.myVideoIsOn
            }
            mine = [entry]
        }
        target.apply(waiting: waiting.map { .init(id: $0.id, name: $0.name) },
                         canDeny: ParticipantGridWindowController.sdk?.canExpelFromWaitingRoom() ?? false,
                         isHost: flags.iAmHostOrCoHost,
                         hands: queue.map(row),
                         everyone: mine + roster.filter { !handIDs.contains($0.id) }.map(row),
                         total: roster.count + 1)
    }

    /// The pointer over the small slot form brings its chrome in; leaving takes
    /// it out after a beat, so a menu opened from the toolbar is not pulled out
    /// from under the pointer.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard hoverChrome else { return }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard hoverChrome else { return }
        chromeHideWork?.cancel()
        guard !chromeHover else { return }
        chromeHover = true
        layoutEverything()
    }

    override func mouseExited(with event: NSEvent) {
        guard hoverChrome else { return }
        chromeHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.chromeHover = false
            self?.layoutEverything()
        }
        chromeHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func layoutEverything() {
        let width = bounds.width, height = bounds.height
        let barHeight = MeetingTheme.topBarHeight, toolbarHeight = MeetingToolbarView.height
        let panel = controls?.sidePanel
        let chrome = !hoverChrome || chromeHover || panel != nil

        meetingTopBar.isHidden = !chrome
        bottomBar.isHidden = !chrome
        // The window's frost is the toolbar's background. Only the slot form,
        // where the toolbar lies over live video, keeps a blur to read against.
        bottomBar.showsBlur = hoverChrome
        meetingTopBar.frame = NSRect(x: 0, y: height - barHeight, width: width, height: barHeight)
        meetingTopBar.needsLayout = true   // re-lifts its tip above tiles added since
        bottomBar.frame = NSRect(x: 0, y: 0, width: width, height: toolbarHeight)

        // The slot form has no room for permanent chrome, so it lies over the
        // video; the full form gives the stage what is left between the bars.
        let reserveTop = hoverChrome ? 0 : barHeight
        let reserveBottom = hoverChrome ? 0 : toolbarHeight
        let panelWidth = panel == nil ? 0 : min(Self.sidePanelWidth, width)
        // Below narrowWidth the panel covers the stage's right edge instead of
        // taking a column off it, and the stage keeps its full width.
        let overlay = isNarrow
        let stageRight = (panel != nil && !overlay) ? width - panelWidth : width
        let clearRight = panel != nil ? width - panelWidth : width      // left of the panel
        let stage = NSRect(x: 0, y: reserveBottom, width: stageRight,
                           height: max(0, height - reserveTop - reserveBottom))

        sidePanelHost.isHidden = panel == nil
        if let panel {
            sidePanelHost.frame = NSRect(x: width - panelWidth, y: reserveBottom,
                                         width: panelWidth, height: stage.height)
            layoutSidePanel(panel)
        }

        // Beside a share, the chosen view lives in the right part of the stage.
        let side = shareBeside ? MeetingSplit.regions(stage: stage, fraction: splitFraction) : nil
        lastSideStage = stage
        shareHost.isHidden = side == nil
        splitDivider.isHidden = side == nil
        if let side {
            shareHost.frame = side.share
            shareChrome.frame = shareHost.bounds
            splitDivider.frame = side.divider
        }
        let area = side?.video ?? stage

        let others = !listed.isEmpty
        let pages = max(1, Int(ceil(Double(listed.count) / Double(perPage))))
        // Paging is two arrows at the sides (layoutPager), not a band.
        let pagerHeight: CGFloat = 0

        // You, in the corner, over the grid: laid out after it and never part of
        // its arithmetic. "Hide self view" only hides this picture, here.
        let stripTile = Self.stripHeight - 8
        // In Speaker view you are one of the strip's small tiles, at its right
        // end; in Multi-speaker the strip's too; in Gallery you are the corner picture.
        let inStrip = !hideSelfView && ((isSpeakerMode && others) || (isMultiMode && !plan.rest.isEmpty))
        let preview = inStrip ? NSSize(width: (stripTile * 16 / 9).rounded(), height: stripTile) : Self.selfPreviewSize
        let areaRight = min(area.maxX, clearRight)
        selfPreview.isHidden = hideSelfView
        if isMultiMode, inStrip {
            selfPreview.frame = NSRect(x: areaRight - MeetingTheme.tileGap - preview.width, y: area.minY + MeetingTheme.tileGap,
                                       width: preview.width, height: preview.height)
        } else {
            selfPreview.frame = inStrip
                ? NSRect(x: areaRight - preview.width - 4, y: area.maxY - 4 - preview.height,
                         width: preview.width, height: preview.height)
                : NSRect(x: areaRight - preview.width - 12,
                         y: area.minY + 12 + pagerHeight, width: preview.width, height: preview.height)
        }
        // Its video host is sized in its own layout pass; the self element is
        // attached later in this same update and needs real bounds.
        selfPreview.layoutSubtreeIfNeeded()

        if isSpeakerMode {
            // Zoom puts the strip of small tiles along the TOP in Speaker view.
            let strip: CGFloat = others ? Self.stripHeight : 0
            gridHost.layer?.backgroundColor = NSColor.clear.cgColor
            // The preview owns the strip's right-hand end.
            gridHost.frame = NSRect(x: area.minX, y: area.maxY - strip,
                                    width: max(0, areaRight - area.minX - (inStrip ? preview.width + 8 : 0)),
                                    height: strip)
            stageHost.isHidden = (roster.isEmpty || plan.everyoneHidden) && !shareOnStage && !selfCardShown
            stageHost.frame = NSRect(x: area.minX + 4, y: area.minY + 4,
                                     width: max(0, area.width - 8), height: max(0, area.height - strip - 8))
            stageChrome.frame = stageHost.bounds
            selfShareCard.isHidden = !selfCardShown
            if selfCardShown {
                let card = SelfShareCardView.size
                selfShareCard.frame = NSRect(x: (stageHost.bounds.width - card.width) / 2,
                                             y: (stageHost.bounds.height - card.height) / 2,
                                             width: card.width, height: card.height)
            }
            layoutPager(pages: 1, y: area.minY, width: area.width)
        } else if isMultiMode {
            gridHost.layer?.backgroundColor = NSColor.clear.cgColor
            stageHost.isHidden = true
            gridHost.frame = NSRect(x: area.minX + MeetingTheme.tileGap, y: area.minY + MeetingTheme.tileGap,
                                    width: max(0, areaRight - area.minX - MeetingTheme.tileGap * 2),
                                    height: max(0, area.height - MeetingTheme.tileGap * 2))
            layoutPager(pages: 1, y: area.minY, width: area.width)
        } else {
            gridHost.layer?.backgroundColor = NSColor.clear.cgColor
            stageHost.isHidden = true
            // 4pt all round, so the gaps between tiles and the window's edge agree.
            gridHost.frame = area.insetBy(dx: MeetingTheme.tileGap, dy: MeetingTheme.tileGap)
            layoutPager(pages: pages, y: area.minY, width: area.width)
        }

        if !isSpeakerMode { selfShareCard.isHidden = true }
        let shareArea = side?.share ?? NSRect(x: stage.minX, y: stage.minY,
                                              width: min(stage.maxX, clearRight) - stage.minX, height: stage.height)
        layoutShareChip(in: shareArea)
        emptyState.isHidden = !(roster.isEmpty || plan.everyoneHidden) || shareOnStage || selfCardShown
        emptyState.frame = NSRect(x: area.minX + 40, y: area.midY - 40,
                                  width: max(80, areaRight - area.minX - 80), height: 80)

        inspector.isHidden = selected == nil
        updateEscapeMonitor(active: selected != nil)
        if selected != nil {
            let drawer = min(inspector.height(), stage.height - 32)
            inspector.frame = NSRect(x: clearRight - ParticipantInspectorView.width - 16,
                                     y: stage.maxY - drawer - 16,
                                     width: ParticipantInspectorView.width, height: drawer)
        }

        layoutMeetingTopBar()
        layoutTiles()
    }

    /// The Zoom-style bar lays itself out; this only keeps its state current.
    private func layoutMeetingTopBar() {
        updateMeetingTopBar()
    }

    private func layoutSidePanel(_ panel: MeetingSidePanel) {
        let width = sidePanelHost.bounds.width, height = sidePanelHost.bounds.height
        let head: CGFloat = 44
        sidePanelBacking.frame = sidePanelHost.bounds
        sidePanelDivider.frame = NSRect(x: 0, y: 0, width: 1, height: height)
        // On top of the panel's contents: the people list and the chat are
        // opaque and covered it, so the line stopped under the queue (owner,
        // 2026-11-16: "a proper line should be drawn in between").
        if sidePanelHost.subviews.last !== sidePanelDivider {
            sidePanelHost.addSubview(sidePanelDivider, positioned: .above, relativeTo: nil)
        }
        // Zoom's panel headers: "Participants (N)" and "Chat".
        sidePanelTitle.stringValue = panel == .chat ? "Chat" : "Participants (\(roster.count + 1))"
        sidePanelTitle.sizeToFit()
        sidePanelTitle.frame = NSRect(x: 16, y: height - head + (head - sidePanelTitle.frame.height) / 2,
                                      width: min(sidePanelTitle.frame.width, max(0, width - 64)),
                                      height: sidePanelTitle.frame.height)
        sidePanelClose.frame = NSRect(x: width - 36, y: height - head + 10, width: 24, height: 24)
        // The count and Invite moved into the Participants panel itself (its
        // footer), as Zoom has them.
        sidePanelCount.isHidden = true
        inviteButton.isHidden = true
        let body = NSRect(x: 0, y: 0, width: width, height: max(0, height - head))

        switch panel {
        case .chat:
            if chatHost == nil, let bridge = ParticipantGridWindowController.chatBridge {
                let host = FirstMouseHostingView(rootView: ChatWindowView(chat: bridge).environment(\.meetingZoomChat, true).tint(Brand.green))
                sidePanelHost.addSubview(host)
                chatHost = host
            }
            chatHost?.isHidden = false
            chatHost?.frame = body
            queueScroll.isHidden = true
            peopleView.isHidden = true
        case .people:
            chatHost?.isHidden = true
            peopleView.isHidden = false
            // The needs block and Cues sit at the top, taking what they want up
            // to under half the panel and scrolling inside that; the roster has
            // the rest.
            let state = peoplePanelQueueState
            let wanted = liveQueue.height(for: state, width: width)
            let queueHeight = wanted == 0 ? 0 : min(wanted, (body.height * 0.45).rounded())
            queueScroll.isHidden = queueHeight <= 0
            queueScroll.frame = NSRect(x: 0, y: body.height - queueHeight, width: width, height: queueHeight)
            if queueHeight > 0 { placeQueue(height: queueHeight, width: width, state: state) }
            peopleView.frame = NSRect(x: 0, y: 0, width: width, height: max(0, body.height - queueHeight))
            updatePeopleRows()
        }
    }

    /// Multi-speaker: the recent speakers large in a row or grid, everyone else
    /// in a strip along the bottom, your preview at the strip's right end.
    private func layoutMultiSpeaker() {
        let visible = pageRoster
        let largeCount = visible.filter { plan.large.contains($0.id) }.count
        let frames = MeetingVideoLayout.multiSpeaker(largeCount: largeCount, stripCount: visible.count - largeCount,
                                                     in: gridHost.bounds.size, stripHeight: Self.stripHeight,
                                                     includeSelf: !hideSelfView)
        placeSelf(frames.me)
        guard !visible.isEmpty else { return }
        for (entry, target) in zip(visible, frames.large + frames.strip) {
            guard let tile = tiles[entry.id], tile.frame != target else { continue }
            if !tile.frame.isEmpty {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    tile.animator().frame = target
                }
            } else {
                tile.frame = target
            }
        }
    }

    /// Speaker view's filmstrip: one centred row under the stage.
    private func layoutFilmstrip() {
        let visible = pageRoster
        guard !visible.isEmpty else { return }
        // Zoom's strip, along the top of Speaker view. The corner preview owns
        // the strip's right end (the grid host stops short of it).
        let tileHeight = Self.stripHeight - 8
        let size = NSSize(width: gridHost.bounds.width, height: gridHost.bounds.height - 4)
        let frames = MeetingVideoLayout.strip(count: visible.count, in: size, tileHeight: tileHeight)
        for (entry, target) in zip(visible, frames) {
            guard let tile = tiles[entry.id], tile.frame != target else { continue }
            tile.frame = target
        }
    }

    // MARK: Chrome

    override func layout() {
        super.layout()
        layoutEverything()
    }

    private func updateChromeText() {
        emptyState.stringValue = plan.everyoneHidden ? MeetingTileFilter.emptyNote : waiting.isEmpty
            ? "Waiting for others.\nThey appear here as they join."
            : "\(waiting.count) waiting to be let in.\nOpen Participants to admit them."
    }

    /// Raised hands in the order they went up.
    private var handQueue: [ZoomMeetingSDKClient.RosterEntry] {
        roster.filter(\.isRaisingHand).sorted {
            (handRaisedAt[$0.id] ?? .distantPast) < (handRaisedAt[$1.id] ?? .distantPast)
        }
    }

    /// Everything the window shows, as one value.
    ///
    /// Phase 1 of the redesign plan: the rail's blocks each used to work out
    /// their own idea of what mattered, so "what needs the teacher" was decided
    /// in more than one place and could disagree. It is decided here now, and
    /// the views read the answer. See ParticipantConsoleState.
    private var consoleState: ParticipantConsoleState {
        var state = ParticipantConsoleState()
        state.isLive = session.readiness.isLive
        state.meetingNumber = session.meetingNumber
        state.isRecording = session.isRecording
        state.students = roster.count
        state.waiting = waiting.map { .init(id: $0.id, name: $0.name) }
        state.hands = handQueue.map { .init(id: $0.id, name: $0.name) }
        state.selected = selected
        state.cuesCards = cuesBlock.cardCount
        state.cuesListening = cuesBlock.isActive
        return state
    }

    /// Everything the toolbar and context strip render from, flattened.
    private func barSignature() -> String {
        let sdk = ParticipantGridWindowController.sdk
        var parts: [String] = [
            selected.map(String.init) ?? "-",
            String(page),
            String(roster.count),
            String(waiting.count),
            session.isRecording ? "rec" : "-",
            (sdk?.iAmMuted ?? false) ? "me-muted" : "-",
            (sdk?.myVideoIsOn ?? false) ? "me-video" : "-",
            (sdk?.myHandIsRaised ?? false) ? "me-hand" : "-",
            flags.chatAllowed ? "c" : "-",
            flags.shareAllowed ? "s" : "-",
            flags.renameAllowed ? "r" : "-",
            flags.startVideoAllowed ? "v" : "-",
            flags.unmuteSelfAllowed ? "u" : "-",
            flags.focusModeOn ? "f" : "-",
            flags.incomingAudioStopped ? "q" : "-",
            flags.canSuspend ? "z" : "-",
            roster.contains(where: \.isRaisingHand) ? "hands" : "-",
            roster.contains(where: \.isSpotlighted) ? "spots" : "-",
            // Readiness changes what the controls look like - dimmed or live -
            // so a step completing has to rebuild the rail like any other
            // state a button renders from.
            String(describing: session.readiness)
        ]
        // The context strip mirrors one student, so its state belongs here too.
        if let id = selected, let entry = roster.first(where: { $0.id == id }) {
            parts.append("\(entry.name)|\(entry.isMuted)|\(entry.videoOn)|\(entry.isSpotlighted)|\(entry.isPinned)|\(entry.isRaisingHand)|\(entry.isCoHost)|\(entry.isMyself)")
        }
        return parts.joined(separator: ";")
    }

    /// The People panel lists who is waiting and whose hand is up itself,
    /// with Admit and Deny on each row, so the queue above it keeps only
    /// Cues: the same person was shown twice (owner, 2026-11-16).
    private var peoplePanelQueueState: ParticipantConsoleState {
        var state = consoleState
        state.waiting = []
        state.hands = []
        return state
    }

    private func placeQueue(height queueHeight: CGFloat, width: CGFloat, state: ParticipantConsoleState) {
        // Where the teacher had scrolled the queue to, from its top, read
        // BEFORE the view is resized and rewritten below. This runs on
        // every one-second poll, and it used to end by scrolling the
        // queue back to the top unconditionally - so a scroll lasted until
        // the next tick and then snapped, which is what "laggy" was.
        let queueViewport = queueScroll.contentView.bounds
        let queueFromTop = liveQueue.bounds.height > 0
            ? max(0, liveQueue.bounds.height - queueViewport.maxY) : 0
        // Frame first, THEN write it: the view lays out from its own
        // height, so it has to know that height before it draws.
        // The VIEWPORT height, not what the queue wanted. Sized to the
        // want, the block fitted five cards into a 400pt document that an
        // 80pt scroller showed the top of - measured live, every card sat
        // below the window edge. Sized to what it has, the block fits whole
        // cards and counts the rest, which is what it was built to do.
        liveQueue.frame = NSRect(x: 0, y: 0, width: width, height: queueHeight)
        liveQueue.apply(state, width: width)
        // Non-flipped document views scroll to the bottom by default, which
        // would open the queue showing its last row - so the position is
        // put back counted from the top, clamped to what now exists.
        let maxFromTop = max(0, liveQueue.bounds.height - queueViewport.height)
        liveQueue.scroll(NSPoint(x: 0, y: liveQueue.bounds.height - queueViewport.height
                                         - min(queueFromTop, maxFromTop)))
    }
    /// Cues's state, once a second. Re-lays the rail only when the block
    /// changed height, so a stable set of cards costs nothing.
    func applyCues(_ state: CuesSurfaceState) {
        let hadCards = cuesBlock.hasCards
        guard cuesBlock.apply(state) || hadCards != cuesBlock.hasCards else { return }
        layoutEverything()
    }

    /// The students-overflow carousel. Only drawn when there is a second page.
    private func layoutPager(pages: Int, y: CGFloat, width: CGFloat) {
        let show = pages > 1
        pagePrev?.isHidden = !show
        pageNext?.isHidden = !show
        guard show else { return }

        if pagePrev == nil {
            let previous = Self.pagerButton("chevron.left") { [weak self] in
                guard let self else { return }
                self.page = max(0, self.page - 1)
                self.pageChanged()
            }
            let next = Self.pagerButton("chevron.right") { [weak self] in
                guard let self, let pageCount = self.pageCount else { return }
                self.page = min(pageCount - 1, self.page + 1)
                self.pageChanged()
            }
            pagePrev = previous
            pageNext = next
            addSubview(previous)
            addSubview(next)
        }
        do {
            // Zoom pages with a pair of arrows at the sides of the gallery.
            let area = gridHost.frame
            let size = NSSize(width: 30, height: 56)
            for button in [pagePrev, pageNext] {
                button?.isBordered = false
                button?.wantsLayer = true
                button?.layer?.cornerRadius = 8
                button?.contentTintColor = .white
                if let arrow = button as? MeetingBarButton {
                    arrow.restColor = MeetingTheme.capsuleNS
                    arrow.hoverColor = MeetingTheme.capsuleHoverNS
                }
            }
            pagePrev?.isEnabled = page > 0
            pageNext?.isEnabled = page < pages - 1
            // An arrow with nowhere to go loses its capsule and fades.
            for button in [pagePrev, pageNext] { button?.alphaValue = button?.isEnabled == true ? 1 : 0.35 }
            pagePrev?.frame = NSRect(x: area.minX + 6, y: area.midY - size.height / 2, width: size.width, height: size.height)
            pageNext?.frame = NSRect(x: area.maxX - 6 - size.width, y: area.midY - size.height / 2,
                                     width: size.width, height: size.height)
            pagePrev?.toolTip = "Previous page"
            pageNext?.toolTip = "Next page"
        }
    }

    private var pageCount: Int? {
        listed.isEmpty ? nil : max(1, Int(ceil(Double(listed.count) / Double(perPage))))
    }

    /// A page change swaps which students are on screen, so tiles, video
    /// subscriptions and layout all have to follow immediately rather than
    /// waiting for the next poll.
    private func pageChanged() {
        selected = nil
        lastBarSignature = barSignature()
        rebuildContextBar()
        layoutEverything()
        if let provider = lastVideoProvider { attachVideo(provider) }
        if let provider = lastSelfProvider { attachSelfVideo(provider) }
    }

    // MARK: Context bar - the selected student

    private func rebuildContextBar() {
        guard let id = selected, let entry = roster.first(where: { $0.id == id }) else { return }

        let name = NSTextField(labelWithString: entry.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = .labelColor
        var controls: [NSView] = [name]

        if !entry.isMyself {
            controls.append(Self.button(entry.isMuted ? "Unmute" : "Mute",
                                        symbol: entry.isMuted ? "mic" : "mic.slash") {
                let mute = !entry.isMuted
                // Unmuting someone else is a request in Zoom's model, never a
                // command - the wording has to match or the teacher waits for
                // something that was never going to happen on its own.
                Self.perform(mute ? "Muted \(entry.name)" : "Asked \(entry.name) to unmute") {
                    $0.setMuted(mute, userID: id)
                }
            })
            controls.append(Self.button(entry.videoOn ? "Stop video" : "Ask to start video",
                                        symbol: (entry.videoOn ? VisibilitySymbol.cameraOff : VisibilitySymbol.cameraOn).name) {
                let stop = entry.videoOn
                Self.perform(stop ? "Stopped \(entry.name)'s video" : "Asked \(entry.name) to start video") {
                    $0.setVideoMuted(stop, userID: id)
                }
            })
        }
        controls.append(Self.button(entry.isSpotlighted ? "Unspotlight" : "Spotlight",
                                    symbol: entry.isSpotlighted ? "star.slash" : "star",
                                    prominent: !entry.isSpotlighted) {
            let on = !entry.isSpotlighted
            Self.perform(on ? "Spotlighted \(entry.name) for everyone" : "Removed \(entry.name) from spotlight") {
                $0.spotlight(on, userID: id)
            }
        })
        controls.append(Self.button(entry.isPinned ? "Unpin" : "Pin for me",
                                    symbol: entry.isPinned ? "pin.slash" : "pin") {
            let on = !entry.isPinned
            Self.perform(on ? "Pinned \(entry.name) on this Mac only" : "Unpinned \(entry.name)") {
                $0.pin(on, userID: id)
            }
        })
        if entry.isRaisingHand {
            controls.append(Self.button("Lower hand", symbol: "hand.raised.slash") {
                Self.perform("Lowered \(entry.name)'s hand") { $0.lowerHand(userID: id) }
            })
        }
        controls.append(Self.button("Rename", symbol: "pencil") {
            Self.prompt(title: "Rename \(entry.name)", current: entry.name) { newName in
                Self.perform("Renamed \(entry.name) to \(newName)") { $0.rename(userID: id, to: newName) }
            }
        })
        if !entry.isMyself {
            controls.append(Self.button(entry.isCoHost ? "Remove co-host" : "Make co-host",
                                        symbol: "person.2") {
                let on = !entry.isCoHost
                Self.perform(on ? "\(entry.name) is now a co-host" : "\(entry.name) is no longer a co-host") {
                    $0.setCoHost(on, userID: id)
                }
            })
            if flags.iAmHostOrCoHost, ParticipantGridWindowController.sdk?.waitingRoomAvailable == true {
                // The way back is Admit in the waiting list, so no confirmation.
                controls.append(Self.button("Put in waiting room", symbol: "door.left.hand.closed") {
                    Self.perform("Sent \(entry.name) back to the waiting room") {
                        $0.putInWaitingRoom(userID: id)
                    }
                })
            }
            controls.append(Self.button("Make host", symbol: "person.badge.key") {
                Self.confirm(title: "Make \(entry.name) the host?",
                             message: "You become a co-host. You cannot take the host role back without the host key.",
                             confirm: "Make host") {
                    Self.perform("\(entry.name) is now the host") { $0.makeHost(userID: id) }
                }
            })
            controls.append(Self.button("Remove", symbol: "person.fill.xmark", destructive: true) {
                Self.confirm(title: "Remove \(entry.name) from the meeting?",
                             message: "They cannot rejoin this meeting.",
                             confirm: "Remove") {
                    Self.perform("Removed \(entry.name)") { $0.expel(userID: id) }
                }
            })
        }
        // Straight into the drawer. The strip along the bottom is gone: it was
        // always in the layout and empty most of the time, which is the third
        // competing region the plan asks to remove.
        let head = controls.first
        inspector.apply(name: entry.name,
                        status: Self.stateWords(for: entry),
                        controls: Array(controls.dropFirst()))
        _ = head
    }

    // MARK: Control helpers

    /// A global monitor outlives the view that installed it, so ending a
    /// session with the drawer open would leave one running for the rest of
    /// the app's life, swallowing Escape everywhere.
    deinit {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    /// Escape closes the drawer, and only while it is open.
    ///
    /// A local monitor rather than `cancelOperation`: the participants panel is
    /// a non-activating panel and is usually not key, so the responder chain
    /// cannot be relied on to deliver the key at all.
    private func updateEscapeMonitor(active: Bool) {
        if active, escapeMonitor == nil {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.keyCode == 53 else { return event }   // Escape
                guard self.selected != nil else { return event }
                self.selected = nil
                self.selectionChanged()
                return nil
            }
        } else if !active, let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }

        // And a click anywhere outside the drawer closes it, the way every
        // popover on the Mac behaves. The tile's own toggle was not enough:
        // clicking the same student again was meant to close it, but where
        // the click landed on Zoom's video the tile never heard it, and a
        // click on the empty grid or the rail did nothing at all - reported
        // as "it doesn't go away".
        //
        // A click on a tile is handled here rather than passed on, so it
        // toggles once instead of twice (here, then in the tile).
        if active, clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, event.window === self.window, self.selected != nil else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                if !self.inspector.isHidden, self.inspector.frame.contains(point) { return event }
                let inGrid = self.gridHost.convert(event.locationInWindow, from: nil)
                if let (id, _) = self.tiles.first(where: { !$0.value.isHidden && $0.value.frame.contains(inGrid) }) {
                    self.selected = (self.selected == id) ? nil : id
                    self.selectionChanged()
                    return nil
                }
                self.selected = nil
                self.selectionChanged()
                return event
            }
        } else if !active, let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    /// The selected student's state as words, not colour.
    ///
    /// The plan asks for one strong alert treatment that does not depend on
    /// colour alone, and this is the "alone" part: whatever a dot on the tile
    /// says, the drawer says it in English too.
    private static func stateWords(for entry: ZoomMeetingSDKClient.RosterEntry) -> String {
        var parts: [String] = []
        if entry.isMuted { parts.append("Muted") }
        if !entry.videoOn { parts.append("Video off") }
        if entry.isRaisingHand { parts.append("Hand up") }
        if entry.isSpotlighted { parts.append("Spotlighted") }
        if entry.isCoHost { parts.append("Co-host") }
        if entry.isMyself { parts.append("You") }
        return parts.joined(separator: "  \u{00B7}  ")
    }

    private static func pagerButton(_ symbol: String, action: @escaping () -> Void) -> NSButton {
        // Wears the capsule and its hover (set in layoutPager).
        let button = MeetingBarButton(action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
        button.imagePosition = .imageOnly
        button.bezelStyle = .rounded
        return button
    }

    private static func button(_ title: String,
                               symbol: String,
                               prominent: Bool = false,
                               destructive: Bool = false,
                               action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(action)
        button.title = " " + title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 12)
        if prominent { button.hasDestructiveAction = false; button.bezelColor = NSColor(named: "AccentColor") ?? .systemGreen }
        if destructive { button.hasDestructiveAction = true }
        button.sizeToFit()
        return button
    }

    /// Maps a status sentence to a fixed code for the dashboard. The sentences
    /// are written here, so the prefixes are stable; anything new reads as
    /// "other" until it is added, never as the sentence itself.
    fileprivate static func actionCode(for sentence: String) -> String {
        switch true {
        case sentence.hasPrefix("Muted everyone"): return "mute_all"
        case sentence.hasPrefix("Asked everyone"): return "ask_unmute_all"
        case sentence.hasPrefix("Lowered all"): return "lower_all_hands"
        case sentence.hasPrefix("Lowered"): return "lower_hand"
        case sentence.hasPrefix("Cleared spotlight"): return "clear_spotlight"
        case sentence.hasPrefix("Admitted"): return "admit_all"
        case sentence.hasPrefix("Sent"): return "reaction"
        case sentence.hasPrefix("Suspended"): return "suspend_activities"
        case sentence.hasPrefix("Renamed"): return "rename"
        case sentence.hasSuffix("is now the host"): return "make_host"
        case sentence.hasPrefix("Removed"): return "remove"
        default: return "other"
        }
    }

    fileprivate static func perform(_ success: String,
                                    _ body: (ZoomMeetingSDKClient) -> Bool) {
        guard let sdk = ParticipantGridWindowController.sdk else { return }
        let ok = body(sdk)
        // The success string is a sentence for the status log and can name a
        // student, so it is NEVER the event. Only the outcome travels, plus the
        // kind of control, derived from the sentence's fixed opening words.
        Analytics.track(.controlAction, [.action: actionCode(for: success), .refused: ok ? "no" : "yes"])
        // Redraw immediately rather than at the next poll tick, so the control
        // that was just pressed reflects what it did.
        ParticipantGridWindowController.refreshNow()
        if ok {
            ParticipantGridWindowController.report(success)
        } else {
            // Named as a refusal rather than a failure: the usual cause is
            // that the SDK will not allow it in this role, not that anything
            // broke. The attempted outcome is quoted so the log says which
            // button was pressed.
            ParticipantGridWindowController.report("Zoom refused that \u{2014} nothing changed. (\(success))")
        }
    }

    /// Runs an alert ABOVE the panel, wherever the panel lives.
    ///
    /// The full-screen panel is a borderless window at .statusBar level - that
    /// is what lets it cover the menu bar and Dock on the reference display.
    /// runModal's alert window sits at .modalPanel, which is LOWER, so every
    /// confirmation opened underneath the very surface whose button had just
    /// been pressed - reported live on a two-display setup as End session and
    /// Copy invitation "going behind the participant window". The alert also
    /// centres on the panel's screen, so on two displays it appears where the
    /// teacher is looking rather than on the other monitor.
    private static func runAboveEverything(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        // Setting the ALERT's level does not work, and the first version of
        // this runner proved it: runModal(for:) assigns the window to
        // .modalPanel itself when the modal session begins, clobbering any
        // level set beforehand - and it re-centres the window, clobbering the
        // origin too. Pre-modal mutations of the alert are simply overwritten.
        //
        // So step the PANEL down instead. Nothing in the modal machinery
        // touches other windows' levels, which makes this the version that
        // cannot be clobbered: at .normal the panel sits below .modalPanel for
        // exactly the alert's lifetime, and the saved level comes back after.
        // The menu bar showing through during a dialog is fine - the dialog is
        // the one moment the panel is not the surface being used.
        let panelWindow = ParticipantGridWindowController.panelWindowForAlerts
        let savedLevel = panelWindow?.level
        panelWindow?.level = .normal
        // Placement re-asserted from INSIDE the modal session, where it
        // sticks: the async block runs after runModal has done its own
        // centring, and puts the dialog on the display the teacher is
        // actually looking at.
        if let screen = ParticipantGridWindowController.panelScreen {
            DispatchQueue.main.async { [weak window = alert.window] in
                guard let window else { return }
                let area = screen.visibleFrame
                let size = window.frame.size
                window.setFrameOrigin(NSPoint(x: (area.midX - size.width / 2).rounded(),
                                              y: (area.midY - size.height / 2).rounded()))
            }
        }
        let response = alert.runModal()
        if let savedLevel { panelWindow?.level = savedLevel }
        return response
    }

    fileprivate static func confirm(title: String, message: String, confirm: String, action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        // Run modal rather than as a sheet: the host is a non-activating panel,
        // and a sheet on a window whose app is not frontmost can appear behind
        // everything with no way to answer it. A destructive confirmation is
        // also the one moment where pulling focus is the correct behaviour.
        if runAboveEverything(alert) == .alertFirstButtonReturn { action() }
    }

    private static func prompt(title: String, current: String, action: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        let response = runAboveEverything(alert)
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if response == .alertFirstButtonReturn, !trimmed.isEmpty { action(trimmed) }
    }
}

// MARK: - Your own share

/// Where the picture would be while you are sharing a screen through Zoom: it
/// says so, and says the camera picture carries on. Zoom shows the sharer no
/// view of their own share in custom UI, so without it the stage looks idle.
@MainActor
private final class SelfShareCardView: NSView {
    static let size = NSSize(width: 360, height: 132)
    private let title = NSTextField(labelWithString: "You are sharing your screen")
    private let detail = NSTextField(wrappingLabelWithString: "Everyone sees your shared display. Your camera picture keeps going underneath.")
    private lazy var stop: ClosureButton = {
        let button = ClosureButton { [weak self] in self?.onStop() }
        button.title = "Stop sharing"
        button.bezelStyle = .rounded
        button.contentTintColor = .systemRed
        return button
    }()
    private let onStop: () -> Void

    init(onStop: @escaping () -> Void) {
        self.onStop = onStop
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        layer?.cornerRadius = 14          // DESIGN.md radius-lg: a card
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        for view in [title, detail, stop] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityLabel("You are sharing your screen")
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let pad: CGFloat = 20
        title.frame = NSRect(x: pad, y: bounds.height - 44, width: bounds.width - pad * 2, height: 24)
        detail.frame = NSRect(x: pad, y: 52, width: bounds.width - pad * 2, height: 40)
        stop.sizeToFit()
        stop.frame = NSRect(x: (bounds.width - stop.frame.width - 16) / 2, y: 14,
                            width: stop.frame.width + 16, height: 28)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - First-click controls

/// Both of these live in a window that is almost never key. A stock control in a
/// non-key window discards its first press as "make me key", so every click
/// would need doing twice. See ClosureButton for the same lesson.
private final class FirstClickSegmented: NSSegmentedControl {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The grab strip between a share and the view beside it. Drags report the
/// pointer's x in the parent's coordinates; a double click puts the split back.
@MainActor
private final class MeetingSplitDivider: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    var onReset: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var dragging = false { didSet { needsDisplay = true } }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onReset?(); return }
        dragging = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging, let parent = superview else { return }
        onDrag?(parent.convert(event.locationInWindow, from: nil).x)
    }
    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onEnd?()
    }
    override func draw(_ dirtyRect: NSRect) {
        let handle = NSRect(x: bounds.midX - 2, y: bounds.midY - 18, width: 4, height: 36)
        NSColor.white.withAlphaComponent(hovering || dragging ? 0.7 : 0.28).setFill()
        NSBezierPath(roundedRect: handle, xRadius: 2, yRadius: 2).fill()
    }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Chrome background

/// System material, not a hardcoded grey: DESIGN.md reserves the brand palette
/// for content and asks chrome to follow the platform.
@MainActor
private final class BarView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
    }
    required init?(coder: NSCoder) { nil }
}

/// The toolbar's backing. Clear, so the Meeting window's frost (WindowFrost,
/// which also turns solid while the class can see the window) is what shows
/// behind it, as behind the rest of the window. A blur sits under it only when
/// asked, for the slot form's toolbar over video.
@MainActor
private final class ToolbarFootView: NSView {
    private let blur = BarView()
    var showsBlur = false { didSet { blur.isHidden = !showsBlur } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        blur.frame = bounds
        blur.autoresizingMask = [.width, .height]
        blur.isHidden = true
        addSubview(blur)
    }
    required init?(coder: NSCoder) { nil }
}

// MARK: - One student

/// A video view plus the state that video cannot show.
///
/// Zoom draws its own name label into the video it renders, but nothing else:
/// whether a microphone is off, whether a hand is up, whether this is the
/// student currently being spotlighted. Those are the facts a teacher scans for,
/// so they are drawn here rather than inferred.
@MainActor
private final class TileView: NSView {

    let userID: UInt32
    var onSelect: ((UInt32) -> Void)?
    /// Right-click: this person, large, in a window of their own.
    var onSpotlightInWindow: ((UInt32) -> Void)?

    private var video: NSView?
    private let scrim = NSView()
    /// An emoji someone just sent, for three seconds (the SDK's reaction event),
    /// and the yes / no / slow down badge that stays until it is cancelled.
    private let reactionLabel = NSTextField(labelWithString: "")
    private let feedbackLabel = NSTextField(labelWithString: "")
    private let chrome = MeetingTileChrome(frame: .zero)

    init(userID: UInt32) {
        self.userID = userID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = MeetingTheme.tileNS.cgColor
        layer?.cornerRadius = MeetingTheme.tileRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 0

        // Only an anchor for the video to sit below; the chrome draws the name.
        scrim.isHidden = true
        addSubview(scrim)
        // Above the video (which goes below the scrim), below the reaction badges.
        addSubview(chrome)

        reactionLabel.font = .systemFont(ofSize: 28)
        reactionLabel.isHidden = true
        addSubview(reactionLabel)
        feedbackLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        feedbackLabel.textColor = .white
        feedbackLabel.alignment = .center
        feedbackLabel.wantsLayer = true
        feedbackLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        feedbackLabel.layer?.cornerRadius = 9          // a pill: DESIGN.md `pill`, status badges
        feedbackLabel.isHidden = true
        addSubview(feedbackLabel)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { false }

    var videoBounds: NSRect { NSRect(origin: .zero, size: bounds.size) }
    private var lastLoggedSublayers = -2

    func attach(video newVideo: NSView?) {
        // The common case by far - the poll runs at 1Hz and the view rarely
        // changes. It used to log a full view-state line here, which meant a
        // synchronous open/seek/write/close per tile per second on the main
        // thread: 571 of 632 lines in one session's log, and the reason the
        // panel felt sluggish. The probe had already done its job (it proved
        // the views were on screen and correctly sized, which is what pointed
        // the investigation at subscriptions instead).
        guard video !== newVideo else {
            // Change-only render probe. A rendering element grows its layer
            // tree (1 sublayer bare, 4 once the SDK wires the surface up); one
            // that reports dataType=Video but never leaves 1 is accepting data
            // and drawing none of it - the exact state under investigation.
            let sublayers = video?.layer?.sublayers?.count ?? -1
            if sublayers != lastLoggedSublayers {
                lastLoggedSublayers = sublayers
                ZoomMeetingSDKClient.videoLog("render user=\(userID) sublayers=\(sublayers)"
                    + " size=\(Int(bounds.width))x\(Int(bounds.height))")
            }
            return
        }
        video?.removeFromSuperview()
        video = newVideo
        guard let newVideo else {
            ZoomMeetingSDKClient.videoLog("attach user=\(userID) provider returned nil")
            return
        }
        newVideo.autoresizingMask = [.width, .height]
        newVideo.frame = videoBounds
        addSubview(newVideo, positioned: .below, relativeTo: scrim)
        ZoomMeetingSDKClient.videoLog(Self.viewState("attached", userID: userID,
                                                     video: newVideo, tile: self))
    }

    /// TEMPORARY QA INSTRUMENTATION - remove once the tiles are confirmed.
    private static func viewState(_ stage: String, userID: UInt32,
                                  video: NSView?, tile: NSView) -> String {
        guard let video else { return "\(stage) user=\(userID) video=nil" }
        let layerInfo: String
        if let layer = video.layer {
            layerInfo = "layer=yes sublayers=\(layer.sublayers?.count ?? 0) "
                + "opaque=\(layer.isOpaque) hidden=\(layer.isHidden)"
        } else {
            layerInfo = "layer=NONE"
        }
        return "\(stage) user=\(userID)"
            + " videoFrame=\(Int(video.frame.width))x\(Int(video.frame.height))"
            + " tileBounds=\(Int(tile.bounds.width))x\(Int(tile.bounds.height))"
            + " superview=\(video.superview == nil ? "NONE" : "ok")"
            + " window=\(video.window == nil ? "NONE" : (video.window!.isVisible ? "visible" : "hidden"))"
            + " hidden=\(video.isHidden) alpha=\(String(format: "%.2f", video.alphaValue))"
            + " subviews=\(video.subviews.count) \(layerInfo)"
            + " tileInWindow=\(tile.window == nil ? "NONE" : "ok")"
    }

    func detachVideo() {
        video?.removeFromSuperview()
        video = nil
    }

    func apply(entry: ZoomMeetingSDKClient.RosterEntry, isSelected: Bool,
               reaction: String? = nil, feedback: String? = nil) {
        reactionLabel.stringValue = reaction ?? ""
        reactionLabel.isHidden = reaction == nil
        feedbackLabel.stringValue = feedback ?? ""
        feedbackLabel.isHidden = feedback == nil
        reactionLabel.setAccessibilityLabel(reaction.map { "Reaction \($0)" })
        feedbackLabel.setAccessibilityLabel(feedback.map { "Feedback: \($0)" })

        chrome.apply(MeetingTileModel(name: entry.name, isMe: entry.isMyself,
                                      muted: entry.isMuted && entry.hasJoinedAudio, videoOn: entry.videoOn,
                                      speaking: entry.isTalking, handUp: entry.isRaisingHand,
                                      selected: isSelected))
        needsLayout = true
        layoutStates()
    }

    override func layout() {
        super.layout()
        video?.frame = videoBounds
        layoutStates()
    }

    private func layoutStates() {
        // The chrome draws the name, the badges and the ring; only the
        // reaction emoji and the feedback pill are laid out here.
        chrome.frame = bounds
        layoutReactions(inset: 8)
        layer?.borderWidth = 0
    }

    /// Top-right: the feedback badge, with a fresh emoji to its left.
    private func layoutReactions(inset: CGFloat) {
        var badgeRight = bounds.width - inset
        if !feedbackLabel.isHidden {
            feedbackLabel.sizeToFit()
            let w = feedbackLabel.frame.width + 14
            feedbackLabel.frame = NSRect(x: badgeRight - w, y: bounds.height - inset - 18, width: w, height: 18)
            badgeRight -= w + 6
        }
        if !reactionLabel.isHidden {
            reactionLabel.sizeToFit()
            reactionLabel.frame = NSRect(x: badgeRight - reactionLabel.frame.width,
                                         y: bounds.height - inset - reactionLabel.frame.height + 2,
                                         width: reactionLabel.frame.width, height: reactionLabel.frame.height)
        }
    }

    /// The whole tile is one click target. Without this the SDK's own video
    /// view sits on top and may consume the click, so selecting a student would
    /// work on some tiles and not others depending on what Zoom is rendering.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    /// Accept the very first click.
    ///
    /// AppKit swallows the click that brings a non-key window forward unless the
    /// view under the cursor opts in, and this panel is deliberately
    /// non-activating so it never steals focus from the main screen - so it is
    /// almost never key. Without this, EVERY control needed two clicks: one
    /// discarded to make the panel key, one to act. Found live on a three-display
    /// setup; the second click worked, which is what identified it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onSelect?(userID) }

    /// Right-click: our own panel, since an NSMenu shows nothing while Greenroom is inactive.
    override func rightMouseDown(with event: NSEvent) {
        guard let onSpotlightInWindow, MeetingViewPieces.enabled else { return }
        let id = userID
        MeetingMenuPanel.show([.item("Spotlight in window") { onSpotlightInWindow(id) }], for: event)
    }
}

// MARK: - Meters

/// The start sequence, carried by the notch island (NotchStatusController).
///
/// Named steps rather than a spinner: a start stuck on one step looks different
/// from a start that is about to finish. The island grows out of the notch, sits
/// above the tiling so nothing hides it, and folds away the moment there is
/// nothing left to say.
enum ReadinessHUDController {

    /// `screen` is unused: the pill goes on the screen the person is working on
    /// (NotchStatusController.swift).
    static func show(_ readiness: ParticipantGridWindowController.Readiness,
                     on screen: NSScreen, cancellable: Bool = false,
                     onCancel: (() -> Void)? = nil) {
        let input = NotchInput(
            steps: readiness.steps.map { NotchStep(label: $0.label, state: NotchStepState($0.state)) },
            failure: readiness.failure,
            detail: readiness.detail,
            cancellable: cancellable && readiness.failure == nil)
        // An empty reading is the end of the start: the island says Live and folds.
        let carrying = !readiness.steps.isEmpty || readiness.failure != nil
        if carrying, !isShowing { shownAt = Date() }
        isShowing = carrying
        MainActor.assumeIsolated {
            NotchStatusController.shared.update(
                input,
                onAction: { ParticipantGridWindowController.readinessTryAgain?() },
                onDismiss: { ParticipantGridWindowController.readinessDismiss?() },
                onCancel: onCancel)
        }
    }

    static func close() {
        isShowing = false
        MainActor.assumeIsolated { NotchStatusController.shared.clear() }
    }

    /// The island is carrying a start right now.
    private(set) static var isShowing = false
    /// When it first came up, for `letItOpen`.
    private static var shownAt: Date?

    /// Waits until the island has finished growing (its spring settles in about
    /// 0.35s), so the start's heavy main-thread work does not stall the grow.
    /// Returns at once when the island is not carrying the start.
    @MainActor static func letItOpen() async {
        guard isShowing, let shownAt else { return }
        let left = 0.35 - Date().timeIntervalSince(shownAt)
        guard left > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000))
    }
}

extension NotchStepState {
    init(_ state: ParticipantGridWindowController.Readiness.State) {
        switch state {
        case .pending: self = .pending
        case .active: self = .active
        case .done: self = .done
        case .skipped: self = .skipped
        case .failed: self = .failed
        }
    }
}

/// A segmented level bar, the shape of a hardware meter: discrete segments read
/// as "loud enough" at a glance. System greens, amber near the top.
final class LevelMeterView: NSView {

    var level: Double = 0 { didSet { if abs(level - oldValue) > 0.01 { needsDisplay = true } } }
    /// Drawn hollow when the mic is muted in Zoom, so a moving meter never
    /// implies the class can hear you.
    var muted = false { didSet { needsDisplay = true } }

    /// Follows the width, so a segment is always about 10pt and the meter reads
    /// the same whatever it is given. Fixed at 20 it was fine at toolbar widths
    /// and wrong in the rail, where twenty cells stretched across the column
    /// turned a level into a progress track.
    private var segments: Int { max(6, min(20, Int(bounds.width / 12))) }

    override func draw(_ dirtyRect: NSRect) {
        let segments = self.segments
        let gap: CGFloat = 2
        let unit = (bounds.width - CGFloat(segments - 1) * gap) / CGFloat(segments)
        let lit = Int((Double(segments) * level).rounded())

        for index in 0..<segments {
            let rect = NSRect(x: CGFloat(index) * (unit + gap), y: 0, width: unit, height: bounds.height)
            let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
            let hot = index >= segments - 3
            if index < lit && !muted {
                (hot ? NSColor.systemOrange : NSColor.systemGreen).setFill()
                path.fill()
            } else if index < lit && muted {
                // Muted: outline only. The level is still real, but it is going
                // nowhere, and the drawing should say so.
                (hot ? NSColor.systemOrange : NSColor.systemGreen).withAlphaComponent(0.5).setStroke()
                path.lineWidth = 1
                path.stroke()
            } else {
                NSColor.tertiaryLabelColor.withAlphaComponent(0.25).setFill()
                path.fill()
            }
        }
    }
}

// MARK: - Target carriers

// ClosureButton lives in App/UI/ClosureButton.swift now - the Cues cards
// share it. See TileView.acceptsFirstMouse for why it exists.
