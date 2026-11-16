import AppKit

/// The Control bar's People button, as a small window of its own beside the bar
/// rather than the whole Meeting window (owner, 2026-11-16: "can also bring it
/// as a popup instead of triggering the entire zoom window"). It is the same
/// Participants panel the window has, fed by the same roster; once the Meeting
/// window is in view again it folds into the window's People panel, like the
/// chat pop-out, so the list is never in two places.
@MainActor
enum PeoplePopOutController {
    private static var window: NSWindow?
    /// The list the meeting window's grid feeds while the pop-out is open.
    private(set) static var view: MeetingPeopleView?

    static let size = NSSize(width: 320, height: 440)

    /// Opens beside the bar (`anchor`, AppKit coordinates), on the desktop in view.
    static func show(near anchor: NSRect?) {
        if window == nil {
            let people = MeetingPeopleView(frame: NSRect(origin: .zero, size: size))
            people.autoresizingMask = [.width, .height]
            let container = NSView(frame: NSRect(origin: .zero, size: size))
            container.wantsLayer = true
            container.layer?.backgroundColor = MeetingTheme.windowNS.cgColor
            container.addSubview(people)
            let made = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            made.title = "Participants"
            made.contentView = container
            made.appearance = NSAppearance(named: .darkAqua)
            made.backgroundColor = MeetingTheme.windowNS
            made.minSize = NSSize(width: 260, height: 260)
            made.isReleasedWhenClosed = false
            made.collectionBehavior = [.moveToActiveSpace]
            made.setFrame(frame(near: anchor, size: made.frame.size), display: false)
            window = made
            view = people
        }
        window?.orderFrontRegardless()
        ParticipantGridWindowController.refreshNow() // rows now, not on the next tick
    }

    static var isOpen: Bool { window?.isVisible ?? false }
    static var isOpenHere: Bool { isOpen && (window?.isOnActiveSpace ?? false) }

    /// Left on another desktop, it comes to this one.
    static func reveal() {
        guard let window else { return }
        if MeetingSurfaces.comesHereFirst(visible: window.isVisible, onActiveSpace: window.isOnActiveSpace) {
            window.orderOut(nil)
        }
        window.orderFrontRegardless()
    }

    static func close() {
        window?.close()
        window = nil
        view = nil
    }

    static func owns(_ candidate: NSWindow) -> Bool { candidate == window }

    /// Under the bar's right end when the bar is in the top half of its screen,
    /// above it otherwise; kept on the screen. Centred with no bar to go by.
    private static func frame(near anchor: NSRect?, size: NSSize) -> NSRect {
        guard let anchor,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main else {
            let area = NSScreen.main?.visibleFrame ?? .zero
            return NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                          width: size.width, height: size.height)
        }
        return PeoplePopOutPlacement.frame(size: size, bar: anchor, area: screen.visibleFrame)
    }
}
