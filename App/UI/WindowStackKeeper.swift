//
//  WindowStackKeeper.swift
//  Greenroom
//
//  Keeps Greenroom's windows stacked as the owner left them when they switch
//  desktops and come back (R45.6). The rules are WindowStackRules (pure); this
//  is the AppKit half: read the order, remember it, put it back.
//
//  The order is read from CGWindowList (front to back, the desktop in view,
//  our process, ordinary level) after the owner acts (a mouse-up or a key
//  window change in Greenroom), when Greenroom stops being the active app,
//  and once a second. A desktop switch freezes the memory for a second; within
//  it the order is compared with the remembered one and put back with
//  `order(_:relativeTo:)`, which neither activates Greenroom nor takes key.
//  A click or key press after coming back is the owner's and wins.
//
import AppKit

@MainActor
final class WindowStackKeeper {
    static let shared = WindowStackKeeper()

    private var memory = WindowStackMemory()
    /// The last order each window was seen in, kept after it is hidden, so it
    /// can come back to its place.
    private var lastOrderWith: [Int: [Int]] = [:]
    private var started = false
    private var frozenUntil = Date.distantPast
    private var ownerActedSinceSwitch = false
    private var switchID = 0
    private var observers: [NSObjectProtocol] = []
    private var monitors: [Any] = []
    private var timer: Timer?
    private var log: (String) -> Void = { _ in }

    func start(log: @escaping (String) -> Void) {
        guard !started else { return }
        started = true
        self.log = log
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WindowStackKeeper.shared.desktopChanged() }
        })
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSApplication.willResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { WindowStackKeeper.shared.rememberSoon() }
            })
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown], handler: { event in
            MainActor.assumeIsolated { WindowStackKeeper.shared.ownerActed(event.type) }
            return event
        }) { monitors.append(monitor) }
        let tick = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { WindowStackKeeper.shared.remember() }
        }
        tick.tolerance = 0.3
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
        remember()
    }

    // MARK: Reading and remembering

    /// Greenroom's ordinary-level windows on the desktop in view, front to back.
    private static func currentOrder() -> [Int] {
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let ours = Set(NSApp.windows.filter { $0.isVisible && $0.level == .normal }.map(\.windowNumber))
        return info.compactMap { entry in
            guard entry[kCGWindowOwnerPID as String] as? Int == pid,
                  entry[kCGWindowLayer as String] as? Int == 0,
                  let number = entry[kCGWindowNumber as String] as? Int, ours.contains(number) else { return nil }
            return number
        }
    }

    private func remember() {
        guard Date() >= frozenUntil else { return }
        let order = Self.currentOrder()
        memory.remember(order)
        if order.count >= 2 { for window in order { lastOrderWith[window] = order } }
    }

    /// After AppKit has finished the key change or the click.
    private func rememberSoon() {
        DispatchQueue.main.async { MainActor.assumeIsolated { WindowStackKeeper.shared.remember() } }
    }

    private func ownerActed(_ type: NSEvent.EventType) {
        if Date() < frozenUntil { ownerActedSinceSwitch = true }
        if type == .leftMouseUp { rememberSoon() }
    }

    // MARK: A desktop switch

    private func desktopChanged() {
        switchID += 1
        let id = switchID
        ownerActedSinceSwitch = false
        frozenUntil = Date().addingTimeInterval(WindowStackRules.freezeSeconds)
        for delay in WindowStackRules.restoreDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { WindowStackKeeper.shared.restore(switchID: id) }
            }
        }
    }

    private func restore(switchID id: Int) {
        guard id == switchID, WindowStackRules.shouldRestore(ownerActedSinceSwitch: ownerActedSinceSwitch) else { return }
        let current = Self.currentOrder()
        guard let saved = memory.saved(for: current) else { return }
        let moves = WindowStackRules.restoreMoves(saved: saved, current: current)
        guard !moves.isEmpty else { return }
        for move in moves {
            NSApp.window(withWindowNumber: move.window)?.order(.above, relativeTo: move.above)
        }
        let names = moves.compactMap { move -> String? in
            guard let window = NSApp.window(withWindowNumber: move.window),
                  let under = NSApp.window(withWindowNumber: move.above) else { return nil }
            return "\(Self.name(window)) above \(Self.name(under))"
        }
        log("Back on this desktop: window order put back as you left it (\(names.joined(separator: ", "))).")
    }

    private static func name(_ window: NSWindow) -> String {
        window.title.isEmpty ? "a Greenroom window" : "\u{201C}\(window.title)\u{201D}"
    }

    // MARK: A window we hid comes back

    /// Shows `window` again at its old place in the stack: above the window that
    /// was under it, if that is still up; else at the front. Never activates.
    func showInPlace(_ window: NSWindow) {
        let current = Self.currentOrder()
        let saved = lastOrderWith[window.windowNumber] ?? []
        switch WindowStackRules.slot(for: window.windowNumber, saved: saved, visibleNow: current) {
        case .above(let under): window.order(.above, relativeTo: under)
        case .front: window.orderFrontRegardless()
        }
    }
}
