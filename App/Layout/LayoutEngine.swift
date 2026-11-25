//
//  LayoutEngine.swift
//  Greenroom
//
//  Applies a LayoutTemplate: the one place that knows how a piece (Meeting,
//  Chat, an App) gets onto a screen. Start, Snap Back, Apply now and a display
//  plugged in or pulled out all come through here, so there is exactly one set
//  of rules (.context/layout-creator-plan.md section 3). A layout edited
//  mid-meeting no longer re-tiles by itself (R45): Snap Back places it.
//
//  The arithmetic - which variant, frames in both coordinate spaces, who grows
//  into the gap when the Meeting hides, how a neighbour fits around a window
//  Zoom made bigger - is pure and lives in LayoutResolver (tested). This file is
//  the AppKit half: screens, windows, apps.
//
//  Nothing is cached. Every call resolves the template against the displays as
//  they are at that moment.
//
//  When a window may move at all is LayoutPlacementRules' (R45): placed once,
//  re-placed only by Start, a layout switch, Snap Back or a display coming or
//  going; a window the owner moved stays put; placing never activates an app.
//  The engine keeps a record of the frame it last put each piece at
//  (`placedFrames`) so it can tell a window the owner moved from one it placed.
//
import AppKit

@MainActor
final class LayoutEngine {

    typealias Resolution = LayoutResolver.Result
    typealias Placed = LayoutResolver.Placed

    private let chat: ZoomChatBridge
    private let log: (String) -> Void

    init(chat: ZoomChatBridge, log: @escaping (String) -> Void) {
        self.chat = chat
        self.log = log
    }

    // MARK: Where each piece was put (R45)

    /// The frame each piece's window had right after Greenroom last placed it,
    /// read back from the window (an app may clamp what it was asked for). Apps
    /// in Accessibility coordinates, Greenroom's own windows in AppKit ones; each
    /// piece is always read the same way (`currentFrame`).
    private var placedFrames: [UUID: CGRect] = [:]

    /// The piece's window frame now, or nil when there is none to read (not
    /// running, no Accessibility grant, closed).
    private func currentFrame(_ piece: LayoutPiece) -> CGRect? {
        switch piece.kind {
        case .chat:
            guard ChatWindowController.isOpen else { return nil }
            return ChatWindowController.currentWindow?.frame
        case .app(let app):
            if AppCatalog.isBuiltInBrowser(app.bundleID) { return BrowserWindowController.visibleFrame }
            guard AppWindowManager.hasAccessibilityPermission,
                  let window = AppWindowManager.frontWindow(ofAppWithBundleID: app.bundleID) else { return nil }
            return AppWindowManager.frame(of: window)
        case .meeting, .view, .roomScreen:
            return nil
        }
    }

    private func pieceName(_ piece: LayoutPiece) -> String {
        if case .app(let app) = piece.kind { return AppCatalog.displayName(forBundleID: app.bundleID) ?? app.bundleID }
        return "The chat"
    }

    private func recordPlacement(_ piece: LayoutPiece) {
        placedFrames[piece.id] = currentFrame(piece)
    }

    /// Where this piece's window stands: never placed, still placed, or moved by hand.
    private func placementState(_ piece: LayoutPiece) -> PlacedWindowState {
        let current = currentFrame(piece)
        return LayoutPlacementRules.state(windowExists: current != nil, current: current, placed: placedFrames[piece.id])
    }

    // MARK: Resolving

    static func connectedScreens() -> [LayoutScreen] {
        let mainID = CGMainDisplayID()
        return NSScreen.screens.compactMap { screen in
            guard let did = DisplayResolver.displayID(of: screen), let uuid = DisplayResolver.uuidString(for: did) else { return nil }
            return LayoutScreen(id: uuid, name: screen.localizedName, visibleFrame: screen.visibleFrame, isMain: did == mainID)
        }
    }

    /// `logNotes` is for the moments a layout is actually applied; the loops that
    /// ask every second pass false, or the log would repeat a fallback forever.
    func resolve(_ template: LayoutTemplate, logNotes: Bool = false) -> Resolution {
        let primaryHeight = DisplayResolver.mainDisplayScreen()?.frame.height ?? 0
        let viewsCanOpen = LayoutResolver.viewsCanOpen(viewsEnabled: MeetingViewPieces.enabled,
                                                       meetingWindowOnly: MeetingViewWindows.meetingWindowOnly)
        let screens = Self.connectedScreens()
        let template = LayoutResolver.substitutingMeetingForActiveSpeaker(
            template, viewsCanOpen: viewsCanOpen, secondConnected: LayoutResolver.secondIsConnected(template, screens: screens))
        let result = LayoutResolver.resolve(template, screens: screens, primaryHeight: primaryHeight)
        if logNotes { result.notes.forEach(log) }
        return result
    }

    func screen(of placed: Placed) -> NSScreen? { DisplayResolver.screen(forUUID: placed.screen.id) }

    // MARK: Questions the coordinator asks

    /// The display a Meeting piece fills (the participants form), if the layout
    /// has one right now.
    func referenceScreen(_ template: LayoutTemplate) -> NSScreen? {
        guard let meeting = resolve(template).meeting, meeting.fillsDisplay else { return nil }
        return screen(of: meeting)
    }

    /// The Meeting piece when it is a window in a rectangle, not a whole display.
    func placedMeeting(_ template: LayoutTemplate) -> Placed? {
        resolve(template).meeting.flatMap { $0.fillsDisplay ? nil : $0 }
    }

    /// Whether the placed meeting surfaces (the Meeting window in a rectangle, or
    /// any view) start hidden: any one flagged "Starts hidden" hides them all.
    func startsHidden(_ template: LayoutTemplate) -> Bool {
        resolve(template).placed.contains { placed in
            if case .meeting(let fills, let hidden) = placed.piece.kind { return !fills && hidden }
            // A Self view's own "Starts hidden" hides only itself (selfViewStartsHidden).
            if case .view(let view, let hidden) = placed.piece.kind { return hidden && SelfViewVisibility.joinsTogetherHide(view) }
            return false
        }
    }

    /// Something \u{2325}\u{2318}Z can hide: a Meeting window in a rectangle, or a view.
    func hasPlacedSurface(_ template: LayoutTemplate) -> Bool {
        let r = resolve(template)
        return placedMeeting(template) != nil || !r.views.isEmpty
    }

    /// View pieces are placed and drawn: the layout has some, and they are switched on.
    func viewPieces(_ template: LayoutTemplate) -> [Placed] {
        MeetingViewPieces.enabled ? resolve(template).views : []
    }

    /// The layout has view pieces but no Meeting window of its own: Start does not
    /// open the Meeting window then, and the control bar shows.
    func hasViewsButNoMeeting(_ template: LayoutTemplate) -> Bool {
        let r = resolve(template)
        return r.meeting == nil && !viewPieces(template).isEmpty
    }

    /// Where the layout puts one view right now (grown into a gap while the
    /// others are hidden is not a thing: views go away together), or nil.
    func viewFrame(_ template: LayoutTemplate, _ view: MeetingView) -> (frame: NSRect, screen: NSScreen?)? {
        guard let placed = viewPieces(template).first(where: { $0.piece.kind.view == view }) else { return nil }
        return (placed.frames.ns, screen(of: placed))
    }

    /// Where Greenroom's meeting window goes, and in which form. nil when the
    /// layout has no Meeting piece: the caller opens the free window.
    func meetingTarget(_ template: LayoutTemplate) -> (screen: NSScreen, form: ParticipantGridWindowController.Form)? {
        guard let meeting = resolve(template).meeting, let screen = screen(of: meeting) else { return nil }
        // A Meeting that fills a display is the Zoom-style meeting window filling
        // that display's visible area, not the old reference panel with the rail
        // (owner, 2026-11-24: "the true Zoom UI we made").
        return (screen, .placed(meeting.fillsDisplay ? screen.visibleFrame : meeting.frames.ns))
    }

    /// The Chat piece's frame now (grown into the gap while the Meeting is hidden).
    func chatFrame(_ template: LayoutTemplate, meetingHidden: Bool) -> NSRect? {
        let r = resolve(template)
        guard let piece = r.chat else { return nil }
        return LayoutResolver.frames(of: r, meetingHidden: meetingHidden)[piece.piece.id]?.ns
    }

    /// Where the Greenroom Browser piece is, for a page opened later (Cues).
    func builtInBrowserFrame(_ template: LayoutTemplate) -> NSRect? {
        resolve(template).apps.first { AppCatalog.isBuiltInBrowser($0.piece.kind.app?.bundleID ?? "") }?.frames.ns
    }

    // MARK: Apps

    /// Start: one task per App piece that opens at start. `all` is the manual
    /// "open the layout's apps" - every piece, whatever its Open at Start says.
    /// Each app is placed once, when its window first appears (however late), and
    /// is not activated (R45) unless `activates` (the owner's own "Open This
    /// Layout's Apps"); Start hands focus over once, at its end.
    func openApps(_ template: LayoutTemplate, hidden: Bool = false, all: Bool = false, activates: Bool = false) {
        let r = resolve(template, logNotes: true)
        let frames = LayoutResolver.frames(of: r, meetingHidden: hidden)
        for placed in r.apps {
            guard let app = placed.piece.kind.app, all || app.opensAtStart,
                  let frame = frames[placed.piece.id] else { continue }
            let name = AppCatalog.displayName(forBundleID: app.bundleID) ?? app.bundleID
            let minimised = Visibility.opensMinimised(piece: placed.piece)
            log("Opening \(name)\u{2026}")
            Task {
                if let line = await MainPaneManager.openWindow(bundleID: app.bundleID, url: app.url, frame: frame,
                                                               activates: activates) {
                    log(line)
                }
                recordPlacement(placed.piece)
                // The eye badge off: placed, then out of the way.
                if minimised { await MainPaneManager.minimiseFrontWindow(bundleID: app.bundleID) }
            }
        }
    }

    /// Snap Back: every App piece's front window back in its frame. Launches
    /// nothing; an app that is not running is left alone.
    func repositionApps(_ template: LayoutTemplate, hidden: Bool) async {
        let r = resolve(template, logNotes: true)
        let frames = LayoutResolver.frames(of: r, meetingHidden: hidden)
        for placed in r.apps {
            guard let app = placed.piece.kind.app, let frame = frames[placed.piece.id] else { continue }
            if let line = await MainPaneManager.repositionFrontWindow(bundleID: app.bundleID, frame: frame) {
                log(line)
            }
            recordPlacement(placed.piece)
        }
    }

    /// `open: false` is Snap Back, a display change and a live edit: re-place
    /// what is there. `open: true` also opens the apps (Apply now with another
    /// layout). The Chat moves if it is open; the Meeting is the coordinator's,
    /// because it depends on whose window the picture is in.
    func apply(_ template: LayoutTemplate, open: Bool, meetingHidden: Bool) async {
        if open {
            openApps(template, hidden: meetingHidden)
        } else {
            await repositionApps(template, hidden: meetingHidden)
        }
        if ChatWindowController.isOpen, let frame = chatFrame(template, meetingHidden: meetingHidden) {
            ChatWindowController.setFrame(frame)
            if let chat = resolve(template).chat { recordPlacement(chat.piece) }
        }
    }

    /// End Session: closes the App pieces that say so. Only windows Greenroom
    /// opened itself - the browser is ours, and a Chromium browser's session
    /// window is remembered by id. Other apps are never closed.
    func closeApps(_ template: LayoutTemplate) async {
        var seen = Set<String>()
        let all = template.oneDisplay + (template.twoDisplays?.second ?? [])
        for piece in all {
            guard let app = piece.kind.app, app.closesOnStop, seen.insert(app.bundleID).inserted else { continue }
            if AppCatalog.isBuiltInBrowser(app.bundleID) {
                if BrowserWindowController.isOpen {
                    BrowserWindowController.close()
                    log("Closed the Greenroom Browser window.")
                }
            } else if AppCatalog.isBrowser(app.bundleID),
                      let line = await ChromeWindowManager.closeSessionWindow(bundleID: app.bundleID) {
                log(line)
            }
        }
    }

    /// The end of a start: the largest App piece on the main display is what the
    /// teacher works in, so it takes focus. The one focus hand-off a layout makes
    /// (R45): no other trigger gets here.
    func activateLargestApp(_ template: LayoutTemplate, after trigger: PlacementTrigger) {
        guard LayoutPlacementRules.handsFocusToMainApp(trigger),
              let largest = LayoutResolver.largestAppOnMain(resolve(template)),
              let bundleID = largest.piece.kind.app?.bundleID,
              !Visibility.opensMinimised(piece: largest.piece) else { return }
        if AppCatalog.isBuiltInBrowser(bundleID) {
            BrowserWindowController.activate()
        } else {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
        }
    }

    // MARK: Chat and Meeting (Greenroom's own windows)

    /// Puts the Chat and Greenroom's meeting window where the layout wants them.
    /// The chat moves only if it is open: it is opened at the join, and one the
    /// teacher closed is not brought back. The Meeting piece that fills a display
    /// needs no placing here: the participants window opens on that display by
    /// itself.
    ///
    /// `trigger` (R45): Start, a switch, Snap Back and a display coming or going
    /// place everything; the Meeting coming back (`.meetingShown`) only opens a
    /// view that never opened, and moves or raises nothing already up.
    func placeMeetingAndChat(_ template: LayoutTemplate, hidden: Bool, trigger: PlacementTrigger) {
        let r = resolve(template, logNotes: LayoutPlacementRules.isExplicit(trigger))
        LayoutShareChoice.record(r)      // "Show to everyone" per piece, before the windows open
        let frames = LayoutResolver.frames(of: r, meetingHidden: hidden)
        if let piece = r.chat, let frame = frames[piece.piece.id]?.ns, ChatWindowController.isOpen,
           LayoutPlacementRules.shouldPlace(trigger, placementState(piece.piece)) {
            ChatWindowController.setFrame(frame)
            recordPlacement(piece.piece)
        }
        placeViews(r, frames: frames, hidden: hidden, trigger: trigger)
        let roomState: PlacedWindowState = RoomScreen.isOpen ? .placed : .neverPlaced
        if LayoutPlacementRules.shouldPlace(trigger, roomState) {
            placeRoomScreen(r, frames: frames, layoutHidden: hidden)
        }
        // The Meeting window: a placing pass the owner asked for puts it back. Any
        // other pass leaves it; one that is not there yet is made at its rectangle
        // by the follow loop (ParticipantGridWindowController.refresh).
        let meetingState: PlacedWindowState = ParticipantGridWindowController.meetingWindowIsOpen ? .placed : .neverPlaced
        guard LayoutPlacementRules.shouldPlace(trigger, meetingState) else { return }
        guard let meeting = r.meeting, !meeting.fillsDisplay else { return }
        if hidden {
            ParticipantGridWindowController.hide()
        } else {
            // Snap Back never leaves it hidden; a placing pass never switches desktops.
            ParticipantGridWindowController.show(takingYouThere: false)
            ParticipantGridWindowController.place(frame: meeting.frames.ns)
        }
    }

    /// The view pieces: each opens at its rectangle, or is re-placed there. Hidden
    /// (\u{2325}\u{2318}Z, "Starts hidden"), they stay away, together with the Meeting window.
    private func placeViews(_ r: Resolution, frames: [UUID: LayoutFrames], hidden: Bool, trigger: PlacementTrigger) {
        guard MeetingViewPieces.enabled else { return }
        MeetingViewWindows.setHiddenTogether(hidden)
        for placed in r.views {
            guard let view = placed.piece.kind.view, let frame = frames[placed.piece.id]?.ns else { continue }
            var away = hidden
            if view == .selfView, case .view(_, let startsHidden) = placed.piece.kind {
                away = SelfViewVisibility.hidden(startsHidden: startsHidden, hiddenTogether: hidden)
            }
            // Hiding is not placing: a view that should be away goes, whatever the pass.
            if away { MeetingViewWindows.hide(view); continue }
            let state: PlacedWindowState = MeetingViewWindows.isOpen(view) ? .placed : .neverPlaced
            guard LayoutPlacementRules.shouldPlace(trigger, state) else { continue }
            MeetingViewWindows.place(view, frame: frame, hidden: false)
        }
    }

    /// The Room screen: opens on its display at its rectangle, stays up from Start to Stop whatever the
    /// layout's hide does (it is the room's view, not the owner's), and closes when the layout has none, the second display is gone or it
    /// is mirrored (no second slot then; `RoomScreenRules.placement`).
    private func placeRoomScreen(_ r: Resolution, frames: [UUID: LayoutFrames], layoutHidden: Bool) {
        guard let room = r.roomScreen, let frame = frames[room.piece.id]?.ns else { RoomScreen.close(); return }
        RoomScreen.place(frame: frame, rect: room.piece.rect, screenID: room.screen.id, hidden: RoomScreenRules.isHidden(layoutHidden: layoutHidden))
    }

    /// Opens the Chat piece at its frame: the join of a class.
    func openChat(_ template: LayoutTemplate, meetingHidden: Bool) {
        guard let frame = chatFrame(template, meetingHidden: meetingHidden) else { return }
        ChatWindowController.show(chat: chat, frame: frame)
        if let piece = resolve(template).chat { recordPlacement(piece.piece) }
    }

    /// The chat button on the meeting window: the layout's chat if there is one,
    /// else a window opened on demand and left where it lands.
    func revealChat(_ template: LayoutTemplate?, hidden: Bool) {
        if ChatWindowController.isOpen {
            ChatWindowController.reveal()
        } else {
            ChatWindowController.show(chat: chat, frame: template.flatMap { chatFrame($0, meetingHidden: hidden) })
            if let piece = template.flatMap({ resolve($0).chat }) { recordPlacement(piece.piece) }
        }
    }

    // MARK: Hiding and showing the Meeting (\u{2325}\u{2318}Z)

    /// The neighbour that joins the Meeting into a rectangle grows into its gap
    /// when it hides, and shrinks back when it returns. The Meeting's own window
    /// is the caller's. A neighbour the owner moved or resized is left where it
    /// is (R45); Snap Back puts it back.
    func moveNeighbour(_ template: LayoutTemplate, meetingHidden: Bool) {
        let r = resolve(template)
        let shown = LayoutResolver.frames(of: r, meetingHidden: false)
        let chosen = LayoutResolver.frames(of: r, meetingHidden: meetingHidden)
        // Only the joining neighbour differs between the two; nothing else is touched.
        for placed in r.placed where !placed.piece.kind.isMeetingSurface && chosen[placed.piece.id] != shown[placed.piece.id] {
            guard let frame = chosen[placed.piece.id] else { continue }
            move(placed, to: frame)
        }
        // Shown again: the neighbour that had grown goes back to its own rect.
        if !meetingHidden {
            let hiddenFrames = LayoutResolver.frames(of: r, meetingHidden: true)
            for placed in r.placed where !placed.piece.kind.isMeetingSurface && hiddenFrames[placed.piece.id] != shown[placed.piece.id] {
                if let frame = shown[placed.piece.id] { move(placed, to: frame) }
            }
        }
    }

    // MARK: Moving one piece

    private func move(_ placed: Placed, to frames: LayoutFrames) {
        guard LayoutPlacementRules.shouldPlace(.neighbourMakesRoom, placementState(placed.piece)) else {
            log("\(pieceName(placed.piece)) stays where you put it. Snap Windows Back puts it back in the layout.")
            return
        }
        switch placed.piece.kind {
        case .chat:
            if ChatWindowController.isOpen {
                ChatWindowController.setFrame(frames.ns)
                recordPlacement(placed.piece)
            }
        case .app(let app):
            Task {
                if let line = await MainPaneManager.repositionFrontWindow(bundleID: app.bundleID, frame: frames) {
                    log(line)
                }
                recordPlacement(placed.piece)
            }
        case .meeting, .view, .roomScreen:
            break
        }
    }
}
