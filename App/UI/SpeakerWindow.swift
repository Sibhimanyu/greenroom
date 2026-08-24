//
//  SpeakerWindow.swift
//  Greenroom
//
//  The speaker tile, in custom-UI mode, as OUR window.
//
//  In default Zoom-UI mode the tile is one of the SDK's own meeting windows,
//  which Greenroom has to hunt for, park into the side column, re-park when the
//  SDK recreates it, and defend against panels being mistaken for it. Every one
//  of those steps has produced a live bug: a tug-of-war between two placement
//  loops, a grid pinned to the wrong display, an info popup adopted as the tile
//  and stuck there.
//
//  Custom UI removes the hunt entirely. The SDK hands over an NSView rendering
//  whoever last spoke (ZoomMeetingSDKClient.speakerView) and we put it
//  in a window we own. No Zoom chrome, so no "i" button and no toolbar. Nothing
//  to fight over, because there is no second party.
//
import AppKit

@MainActor
enum SpeakerWindowController {

    private static var window: NSWindow?

    /// Shows the speaker view in the side column's top slot - the same
    /// geometry the parked SDK tile used, so the rest of the layout (and the
    /// chat filling the space below) is unchanged.
    /// The video view currently on screen. Tracked so swapping between the
    /// active-speaker view and the self view only re-parents when the choice
    /// actually changes - the deciding loop runs every couple of seconds, and
    /// tearing a live SDK-rendered view out and back on every tick would
    /// flicker.
    private static var shownVideo: NSView?

    /// `visible` is the caller's quick-hide state, passed in rather than tracked
    /// here so there is one source of truth.
    ///
    /// It has to be a parameter because this is called from a two-second poll.
    /// The first version raised the window on every one of those calls, so the
    /// caller had to hide it again immediately afterwards - its own comment said
    /// as much - which made a quick-hidden tile flicker open and shut every two
    /// seconds. Now visibility is stated once and simply obeyed.
    static func show(videoView: NSView, layout: WorkspaceLayout, visible: Bool = true) {
        let slot = ChatWindowController.zoomSlotNSFrame(for: layout)

        if shownVideo === videoView, let existing = window {
            // Same content, nothing to rebuild. Re-frame only on an actual
            // drift; assigning an identical frame every tick is a wasted layout
            // pass.
            if let slot, existing.frame != slot { existing.setFrame(slot, display: true) }
            applyVisibility(visible, to: existing)
            return
        }

        let hosting: NSWindow
        if let existing = window {
            hosting = existing
            // Remove only the OUTGOING video view. The placeholder underneath
            // stays, and the view we drop is owned by the SDK and may be shown
            // again later, so it is detached rather than destroyed.
            shownVideo?.removeFromSuperview()
        } else {
            guard let created = makeWindow(slot: slot) else { return }
            hosting = created
        }

        // The message lives behind the video, added once: an active-speaker
        // element renders whoever is currently speaking, so before anyone does
        // there is legitimately nothing to draw and the window would be plain
        // black. The video simply covers this the moment someone speaks.
        ensurePlaceholder(in: hosting)
        let content = hosting.contentView ?? NSView()

        // Manual frame plus an autoresizing mask - NOT Auto Layout.
        //
        // This is why the speaker window rendered black while the participant
        // tiles, which share the same container and the same SDK, rendered
        // fine. The element OWNS its view's geometry: ZoomSDKVideoElement's
        // resize: sets the frame and the render surface is sized from it.
        // Turning translatesAutoresizingMaskIntoConstraints off hands that
        // frame to AppKit's layout engine instead, so every resize: the SDK
        // made was overridden on the next layout pass and the surface never
        // matched the view. The tiles were always right; only this window
        // was pinning an SDK-owned view with constraints.
        videoView.translatesAutoresizingMaskIntoConstraints = true
        videoView.frame = content.bounds
        videoView.autoresizingMask = [.width, .height]
        content.addSubview(videoView)

        shownVideo = videoView
        if let slot, hosting.frame != slot { hosting.setFrame(slot, display: true) }
        applyVisibility(visible, to: hosting)
    }

    /// Never re-raises a window that is already on screen. A window sitting
    /// BEHIND another is still `isVisible`, so this leaves it where the user put
    /// it instead of yanking it forward on the next poll.
    private static func applyVisibility(_ visible: Bool, to window: NSWindow) {
        if visible {
            if !window.isVisible { window.orderFrontRegardless() }
        } else if window.isVisible {
            window.orderOut(nil)
        }
    }

    private static func makeWindow(slot: NSRect?) -> NSWindow? {
        if let window { return window }
        let created = NSWindow(contentRect: slot ?? NSRect(x: 0, y: 0, width: 505, height: 351),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered,
                               defer: false)
        created.title = "Speaker"
        created.isReleasedWhenClosed = false
        // Black rather than the window background: video letterboxing against
        // grey reads as a rendering fault.
        created.backgroundColor = .black
        window = created
        return created
    }

    /// Adds the message once, behind wherever video goes.
    private static func ensurePlaceholder(in window: NSWindow) {
        let content = window.contentView ?? NSView()
        guard !content.subviews.contains(where: { $0 is NSTextField }) else { return }
        let placeholder = NSTextField(labelWithString: emptyMessage)
        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.maximumNumberOfLines = 3
        placeholder.usesSingleLineMode = false
        placeholder.lineBreakMode = .byWordWrapping
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -24)
        ])
    }

    fileprivate static let emptyMessage =
        "No one is in the class yet.\nWhoever speaks will appear here."

    /// Shows the window with no video in it, just the message.
    ///
    /// This deliberately reverses an earlier decision. When the tile was black
    /// while alone in a room it looked broken, so it fell back to showing your
    /// own camera. Now that the control panel carries a large self view of its
    /// own, a second copy of your face in the corner is redundant - and it hid
    /// the more useful fact, which is that nobody has arrived. Saying so is
    /// better than filling the space.
    static func showEmpty(layout: WorkspaceLayout, visible: Bool) {
        let slot = ChatWindowController.zoomSlotNSFrame(for: layout)
        guard let hosting = window ?? makeWindow(slot: slot) else { return }
        // Detach whatever was rendering, so the SDK is not drawing over the
        // message. The view belongs to the SDK and may be shown again later, so
        // it is detached rather than destroyed.
        shownVideo?.removeFromSuperview()
        shownVideo = nil
        ensurePlaceholder(in: hosting)
        if let slot, hosting.frame != slot { hosting.setFrame(slot, display: true) }
        applyVisibility(visible, to: hosting)
    }

    static var isOpen: Bool { window?.isVisible ?? false }

    /// So the window-management code can recognise this as ours and leave it
    /// alone, exactly as it does for the chat window.
    static func owns(_ candidate: NSWindow) -> Bool { candidate == window }

    /// Fills the whole side column - the quick-hide counterpart, for when the
    /// speaker is hidden and the chat takes over, and back again.
    static func fillSideColumn(layout: WorkspaceLayout) {
        guard let window, let column = layout.sideColumnNSFrame() else { return }
        window.setFrame(column, display: true)
    }

    static func hide() { window?.orderOut(nil) }

    /// Brings the speaker back into its slot after a quick-hide. Deliberately
    /// does NOT rebuild the video element: the SDK is still rendering into the
    /// same view, so re-creating it would drop and re-subscribe the stream for
    /// nothing.
    static func reveal(layout: WorkspaceLayout) {
        guard let window else { return }
        if let slot = ChatWindowController.zoomSlotNSFrame(for: layout) {
            window.setFrame(slot, display: true)
        }
        window.orderFrontRegardless()
    }

    static func close() {
        window?.orderOut(nil)
        window?.contentView?.subviews.forEach { $0.removeFromSuperview() }
        shownVideo = nil
        window = nil
    }
}
