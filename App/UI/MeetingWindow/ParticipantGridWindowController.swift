//
//  ParticipantGridWindowController.swift
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
        /// Set only as the steps clear on a start that really went live (Zoom said
        /// InMeeting, or the take is rolling): the one reading the island may call Live.
        var liveConfirmed = false
        /// The failure's button when it is not Try again ("Open Settings").
        var failureActionTitle: String?

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
    static var chatBridge: ZoomChatBridge?
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

    /// Set by the coordinator: shrinks the meeting to the control bar and returns
    /// true while a meeting is live (see `MeetingMinimize`); false otherwise, and
    /// the window then minimises as any window does.
    static var shrinkInsteadOfMinimize: (@MainActor () -> Bool)?

    /// Set by the coordinator: asked before the teacher's own close. True lets
    /// the window close; false means a sheet is up and the close waits.
    static var confirmClose: (@MainActor (NSWindow) -> Bool)?

    private static var panel: MeetingControlPanel?

    /// Called when the teacher closes the meeting window with its own close
    /// button, so the coordinator can stop feeding it and the pill can take
    /// over. Not called for the closes the controller does itself.
    static var onUserClosed: (@MainActor () -> Void)?
    static var closingByCode = false
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
    static var panelScreen: NSScreen? { panel?.screen }
    /// The Meeting window, for the layout's share choice.
    static var meetingWindow: NSWindow? { panel }
    /// The panel window itself, for the alert runner to step around.
    static var panelWindowForAlerts: NSWindow? { panel }
    private static var root: MeetingRootView?
    /// You, as the SDK lists you: the Participants panel shows your own row.
    static var myEntry: ZoomMeetingSDKClient.RosterEntry?

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

    private static func makePanel(on screen: NSScreen, form: Form) -> MeetingControlPanel {
        let frame: NSRect
        switch form {
        case .meeting(let fills): frame = meetingFrame(on: screen, fillsScreen: fills)
        case .placed(let placed): frame = placed
        }
        let created = MeetingControlPanel(contentRect: frame,
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

        let hosting: MeetingControlPanel
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
            let view = MeetingRootView(frame: hosting.contentLayoutRect, form: form)
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

    /// The safety check's correction: a window that should be up but was ordered
    /// out comes back to its old place in the stack, not the front (R45.6).
    static func showInPlace() {
        guard let panel, MeetingSurfaceOwner.layoutMayRaiseWindow else { return }
        userHidden = false
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        WindowStackKeeper.shared.showInPlace(panel)
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
    /// MeetingRootView.confirm).
    static func confirmSuspend(_ action: @escaping () -> Void) {
        MeetingRootView.confirm(title: "Suspend all participant activities?",
                         message: "This stops every camera, microphone, share and chat in the meeting at once. Use it only if something has gone wrong.",
                         confirm: "Suspend", action: action)
    }

    static func report(_ message: String) { log?(message) }
    static var sdk: ZoomMeetingSDKClient? { client }
}
