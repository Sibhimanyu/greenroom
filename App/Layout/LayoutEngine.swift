//
//  LayoutEngine.swift
//  Greenroom
//
//  Applies a LayoutTemplate: the one place that knows how a piece (Meeting,
//  Chat, an App) gets onto a screen. Start, Snap Back (\u{2325}\u{2318}S), a display
//  plugged in or pulled out, and a layout edited mid-class all come through
//  here, so there is exactly one set of rules (.context/layout-creator-plan.md
//  section 3).
//
//  The arithmetic - which variant, frames in both coordinate spaces, who grows
//  into the gap when the Meeting hides, how a neighbour fits around a window
//  Zoom made bigger - is pure and lives in LayoutResolver (tested). This file is
//  the AppKit half: screens, windows, apps.
//
//  Nothing is cached. Every call resolves the template against the displays as
//  they are at that moment.
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
        let result = LayoutResolver.resolve(template, screens: Self.connectedScreens(), primaryHeight: primaryHeight)
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

    func startsHidden(_ template: LayoutTemplate) -> Bool {
        guard let meeting = placedMeeting(template), case .meeting(_, let hidden) = meeting.piece.kind else { return false }
        return hidden
    }

    /// Where Greenroom's meeting window goes, and in which form. nil when the
    /// layout has no Meeting piece: the caller opens the free window.
    func meetingTarget(_ template: LayoutTemplate) -> (screen: NSScreen, form: ParticipantGridWindowController.Form)? {
        guard let meeting = resolve(template).meeting, let screen = screen(of: meeting) else { return nil }
        return (screen, meeting.fillsDisplay ? .reference : .placed(meeting.frames.ns))
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
    func openApps(_ template: LayoutTemplate, hidden: Bool = false, all: Bool = false) {
        let r = resolve(template, logNotes: true)
        let frames = LayoutResolver.frames(of: r, meetingHidden: hidden)
        for placed in r.apps {
            guard let app = placed.piece.kind.app, all || app.opensAtStart,
                  let frame = frames[placed.piece.id] else { continue }
            let name = AppCatalog.displayName(forBundleID: app.bundleID) ?? app.bundleID
            log("Opening \(name)\u{2026}")
            Task {
                if let line = await MainPaneManager.openWindow(bundleID: app.bundleID, url: app.url, frame: frame) {
                    log(line)
                }
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
        }
    }

    /// End Session: closes the App pieces that say so. Only windows Greenroom
    /// opened itself - the browser is ours, and a Chromium browser's session
    /// window is remembered by id. Other apps are never closed.
    func closeApps(_ template: LayoutTemplate) async {
        var seen = Set<String>()
        let all = template.oneDisplay + (template.twoDisplays.map { $0.main + $0.second } ?? [])
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
    /// teacher works in, so it takes focus.
    func activateLargestApp(_ template: LayoutTemplate) {
        guard let largest = LayoutResolver.largestAppOnMain(resolve(template)),
              let bundleID = largest.piece.kind.app?.bundleID else { return }
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
    func placeMeetingAndChat(_ template: LayoutTemplate, hidden: Bool) {
        let r = resolve(template, logNotes: true)
        let frames = LayoutResolver.frames(of: r, meetingHidden: hidden)
        if let piece = r.chat, let frame = frames[piece.piece.id]?.ns {
            if ChatWindowController.isOpen { ChatWindowController.setFrame(frame) }
        }
        guard let meeting = r.meeting, !meeting.fillsDisplay else { return }
        if hidden {
            ParticipantGridWindowController.hide()
        } else {
            ParticipantGridWindowController.show()   // Snap Back never leaves it hidden
            ParticipantGridWindowController.place(frame: meeting.frames.ns)
        }
    }

    /// Opens the Chat piece at its frame: the join of a class.
    func openChat(_ template: LayoutTemplate, meetingHidden: Bool) {
        guard let frame = chatFrame(template, meetingHidden: meetingHidden) else { return }
        ChatWindowController.show(chat: chat, frame: frame)
    }

    /// The chat button on the meeting window: the layout's chat if there is one,
    /// else a window opened on demand and left where it lands.
    func revealChat(_ template: LayoutTemplate?, hidden: Bool) {
        if ChatWindowController.isOpen {
            ChatWindowController.reveal()
        } else {
            ChatWindowController.show(chat: chat, frame: template.flatMap { chatFrame($0, meetingHidden: hidden) })
        }
    }

    // MARK: Hiding and showing the Meeting (\u{2325}\u{2318}Z)

    /// The neighbour that joins the Meeting into a rectangle grows into its gap
    /// when it hides, and shrinks back when it returns. The Meeting's own window
    /// is the caller's.
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

    // MARK: Zoom's own window

    /// Zoom clamps its meeting window to a minimum size, so what it ends up with
    /// can be bigger than the Meeting piece. The neighbour that sits against it
    /// steps back to fit around the ACTUAL frame (AppKit coordinates). The one
    /// place a neighbour is compensated for; an App that refuses a size never is.
    func fitNeighbour(_ template: LayoutTemplate, aroundActual actual: CGRect) {
        let r = resolve(template)
        guard let meeting = r.meeting, !meeting.fillsDisplay,
              LayoutResolver.differs(actual, from: meeting.frames.ns) else { return }
        let neighbours = r.placed
            .filter { $0.piece.id != meeting.piece.id && $0.screen.id == meeting.screen.id && !$0.fillsDisplay
                      && !$0.piece.kind.isView }
        guard let absorber = LayoutResolver.absorbingNeighbour(
            of: meeting.piece.rect, among: neighbours.map { (id: $0.piece.id, rect: $0.piece.rect) }),
              let placed = neighbours.first(where: { $0.piece.id == absorber.id }) else { return }
        let fitted = LayoutResolver.fit(placed.frames.ns, aroundActual: actual, planned: meeting.frames.ns)
        let ax = CGRect(x: fitted.minX, y: r.primaryHeight - fitted.maxY, width: fitted.width, height: fitted.height)
        move(placed, to: LayoutFrames(ns: fitted, ax: ax))
    }

    // MARK: Moving one piece

    private func move(_ placed: Placed, to frames: LayoutFrames) {
        switch placed.piece.kind {
        case .chat:
            if ChatWindowController.isOpen { ChatWindowController.setFrame(frames.ns) }
        case .app(let app):
            Task {
                if let line = await MainPaneManager.repositionFrontWindow(bundleID: app.bundleID, frame: frames) {
                    log(line)
                }
            }
        case .meeting, .view:
            break
        }
    }
}
