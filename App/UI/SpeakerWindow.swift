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
//  the active speaker (ZoomMeetingSDKClient.makeActiveSpeakerView) and we put it
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
    static func show(videoView: NSView, layout: WorkspaceLayout) {
        let slot = ChatWindowController.zoomSlotNSFrame(for: layout)

        let hosting: NSWindow
        if let existing = window {
            hosting = existing
            existing.contentView?.subviews.forEach { $0.removeFromSuperview() }
        } else {
            let created = NSWindow(contentRect: slot ?? NSRect(x: 0, y: 0, width: 505, height: 351),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered,
                                   defer: false)
            created.title = "Speaker"
            created.isReleasedWhenClosed = false
            // Black rather than the window background: video letterboxing
            // against grey reads as a rendering fault.
            created.backgroundColor = .black
            window = created
            hosting = created
        }

        // An empty state BEHIND the video, not instead of it.
        //
        // An active-speaker element renders whoever is currently speaking, so
        // alone in a room it legitimately has nothing to draw and the window is
        // simply black. Default Zoom UI hides that by showing your own
        // self-view; here the honest black reads as broken. A label underneath
        // says which it is, and the video covers it the moment anyone speaks.
        let content = hosting.contentView ?? NSView()
        let placeholder = NSTextField(labelWithString: "Waiting for someone to speak")
        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])

        // The SDK's view is sized by us and must follow the window, so it is
        // pinned rather than left at whatever frame it was created with.
        videoView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: content.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        if let slot { hosting.setFrame(slot, display: true) }
        hosting.orderFrontRegardless()
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
        window = nil
    }
}
