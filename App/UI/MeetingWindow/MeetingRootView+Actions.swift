//
//  MeetingRootView+Actions.swift
//  Greenroom
//
//  Escape and click monitors, the person menu, and the alert and action helpers.
//
import AppKit
import SwiftUI
import Combine

@MainActor
extension MeetingRootView {

    /// Escape closes the drawer, and only while it is open.
    ///
    /// A local monitor rather than `cancelOperation`: the participants panel is
    /// a non-activating panel and is usually not key, so the responder chain
    /// cannot be relied on to deliver the key at all.
    func updateEscapeMonitor(active: Bool) {
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
    }

    /// Every click in the window, heard before any view: a click that lands on
    /// Zoom's video element (a tile's or the stage's) never reaches our views, so
    /// the tiles and Speaker view's stage are hit-tested here and the drawer opens,
    /// switches or closes by `ParticipantClick` (tested). A click anywhere else
    /// closes the drawer, the way every popover on the Mac behaves, and goes on.
    /// A click on a person is used up here, so it toggles once (not here, then in
    /// the tile). Right-click gives the tile's menu, on the stage too.
    func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === self.window, !self.isHidden else { return event }
            let target = self.clickTarget(event)
            if event.type == .rightMouseDown {
                guard let id = ParticipantClick.menuFor(target), self.showPersonMenu(id, for: event) else { return event }
                return nil
            }
            let outcome = ParticipantClick.leftClick(on: target, selected: self.selected)
            if outcome.selected != self.selected {
                self.selected = outcome.selected
                self.selectionChanged()
            }
            return outcome.consumed ? nil : event
        }
    }

    /// What a click lands on: the drawer, a control, a tile, or the stage's person.
    private func clickTarget(_ event: NSEvent) -> ParticipantClick.Target {
        let point = convert(event.locationInWindow, from: nil)
        if !inspector.isHidden, inspector.frame.contains(point) { return .drawer }
        // A button under the pointer (the stage's chrome, the toolbar) keeps its click.
        if let frameView = superview {
            var hit = frameView.hitTest(frameView.convert(event.locationInWindow, from: nil))
            while let view = hit, view !== self {
                if view is NSControl { return .elsewhere }
                hit = view.superview
            }
        }
        let inGrid = gridHost.convert(event.locationInWindow, from: nil)
        if let (id, _) = tiles.first(where: { !$0.value.isHidden && $0.value.frame.contains(inGrid) }) {
            return .person(id, isMyself: ParticipantGridWindowController.myEntry?.id == id)
        }
        if isSpeakerMode, !shareOnStage, !selfCardShown, !stageHost.isHidden,
           stageHost.frame.contains(point), let id = stageSpeakerID {
            // The roster here leaves you out: someone not in it is you (or gone).
            let isMyself = ParticipantGridWindowController.myEntry?.id == id || !roster.contains(where: { $0.id == id })
            return .person(id, isMyself: isMyself)
        }
        return .elsewhere
    }

    /// The tile's right-click menu, for a tile or the stage. False when there is none.
    private func showPersonMenu(_ id: UInt32, for event: NSEvent) -> Bool {
        guard MeetingViewPieces.enabled, let name = roster.first(where: { $0.id == id })?.name else { return false }
        MeetingMenuPanel.show([.item("Spotlight in window") { MeetingViewWindows.spotlight(userID: id, name: name) }], for: event)
        return true
    }

    /// The selected student's state as words, not colour.
    ///
    /// The plan asks for one strong alert treatment that does not depend on
    /// colour alone, and this is the "alone" part: whatever a dot on the tile
    /// says, the drawer says it in English too.
    static func stateWords(for entry: ZoomMeetingSDKClient.RosterEntry) -> String {
        var parts: [String] = []
        if entry.isMuted { parts.append("Muted") }
        if !entry.videoOn { parts.append("Video off") }
        if entry.isRaisingHand { parts.append("Hand up") }
        if entry.isSpotlighted { parts.append("Spotlighted") }
        if entry.isCoHost { parts.append("Co-host") }
        if entry.isMyself { parts.append("You") }
        return parts.joined(separator: "  \u{00B7}  ")
    }

    static func pagerButton(_ symbol: String, action: @escaping () -> Void) -> NSButton {
        // Wears the capsule and its hover (set in layoutPager).
        let button = MeetingBarButton(action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
        button.imagePosition = .imageOnly
        button.bezelStyle = .rounded
        return button
    }

    static func button(_ title: String,
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
    private static func actionCode(for sentence: String) -> String {
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

    static func perform(_ success: String,
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

    static func confirm(title: String, message: String, confirm: String, action: @escaping () -> Void) {
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

    /// How a person control runs from this window: `perform`, and alerts above the panel.
    static var actionSurface: ParticipantActionRunner.Surface {
        ParticipantActionRunner.Surface(perform: { perform($0, $1) }, runAlert: { runAboveEverything($0) })
    }
}
