//
//  ParticipantGridWindow.swift
//  Greenroom
//
//  The participant gallery, in custom-UI mode, as OUR window on the reference
//  display.
//
//  This is the surface that caused the most trouble in default Zoom-UI mode.
//  There, the gallery is one of the SDK's windows: Greenroom has to identify it
//  among several, send it to the right display, and keep re-sending it because
//  the SDK moves it back on meeting state changes. That produced a visible
//  flicker between displays, a gallery pinned to the wrong monitor, and a
//  backstop that gives up for two minutes when the fight cannot be won.
//
//  None of that exists here. The window is ours, so it goes where we put it and
//  stays there. The only job left is laying out one video view per participant.
//
import AppKit

@MainActor
enum ParticipantGridWindowController {

    private static var window: NSWindow?

    /// Borderless and non-activating on purpose: this is a wall display, not
    /// something to click into. Clicking it must never make it the key window,
    /// because that is what used to make the SDK recreate its windows and
    /// invalidate every reference Greenroom held.
    private static func makeWindow(on screen: NSScreen) -> NSWindow {
        let created = NSWindow(contentRect: screen.frame,
                               styleMask: [.borderless],
                               backing: .buffered,
                               defer: false,
                               screen: screen)
        created.isReleasedWhenClosed = false
        created.backgroundColor = .black
        created.level = .normal
        created.collectionBehavior = [.managed, .fullScreenAuxiliary]
        created.ignoresMouseEvents = true
        return created
    }

    /// The views currently parented, so a refresh that changes nothing does
    /// nothing. This matters: the caller polls every two seconds, and tearing
    /// live SDK-rendered views out of the hierarchy and re-adding them on every
    /// tick would flicker the whole wall. Re-parent only on an actual change;
    /// re-frame always, which is cheap and absorbs screen changes.
    private static var parented: [NSView] = []

    /// Lays the given views out as an even grid filling the screen.
    ///
    /// Callers hand over views they own - the SDK renders into them - so this
    /// only ever adds, removes and frames subviews. It never creates or
    /// destroys the video elements behind them.
    static func show(views: [NSView], on screen: NSScreen) {
        guard !views.isEmpty else { hide(); return }

        let hosting: NSWindow
        if let existing = window, existing.screen === screen {
            hosting = existing
        } else {
            window?.orderOut(nil)
            parented = []
            hosting = makeWindow(on: screen)
            window = hosting
        }
        hosting.setFrame(screen.frame, display: true)

        guard let content = hosting.contentView else { return }

        let unchanged = parented.count == views.count
            && zip(parented, views).allSatisfy { $0 === $1 }
        if !unchanged {
            for view in parented where !views.contains(where: { $0 === view }) {
                view.removeFromSuperview()
            }
            for view in views where view.superview !== content {
                content.addSubview(view)
            }
            parented = views
        }

        layout(views, in: content)
        hosting.orderFrontRegardless()
    }

    /// Near-square grid: columns first, so a class of five reads three over two
    /// rather than a single row of slivers.
    private static func layout(_ views: [NSView], in content: NSView) {
        let columns = max(1, Int(ceil(Double(views.count).squareRoot())))
        let rows = max(1, Int(ceil(Double(views.count) / Double(columns))))
        let cellWidth = content.bounds.width / CGFloat(columns)
        let cellHeight = content.bounds.height / CGFloat(rows)

        for (index, view) in views.enumerated() {
            let column = index % columns
            let row = index / columns
            // Reading order top-left first, expressed in AppKit's
            // bottom-left-origin space.
            let target = NSRect(x: CGFloat(column) * cellWidth,
                                y: content.bounds.height - CGFloat(row + 1) * cellHeight,
                                width: cellWidth,
                                height: cellHeight)
            view.autoresizingMask = []
            if view.frame != target { view.frame = target }
        }
    }

    static var isOpen: Bool { window?.isVisible ?? false }

    /// So SDK window hunting recognises this as ours, the same as the chat and
    /// speaker windows.
    static func owns(_ candidate: NSWindow) -> Bool { candidate == window }

    static func hide() { window?.orderOut(nil) }

    static func close() {
        window?.orderOut(nil)
        window?.contentView?.subviews.forEach { $0.removeFromSuperview() }
        parented = []
        window = nil
    }
}
