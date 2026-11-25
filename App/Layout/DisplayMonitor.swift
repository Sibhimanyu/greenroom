//
//  DisplayMonitor.swift
//  Greenroom
//
//  One place that hears about displays coming and going, so nothing else has
//  to. Plugging an HDMI cable in or pulling it out fires a burst of events
//  over a second or two (the display goes, then the arrangement is rebuilt,
//  then the Spaces follow); acting on each one tears things down while macOS
//  is still deciding. This waits for the burst to end - `settleSeconds` with
//  nothing new - and then says so once.
//
//  Two sources, because neither is complete alone: the CoreGraphics
//  reconfiguration callback fires for displays NSScreen does not list yet
//  (mirroring, a display asleep), and NSApplication's notification fires
//  after AppKit's own screen list is current, which is what window placement
//  reads.
//
import AppKit
import CoreGraphics

@MainActor
final class DisplayMonitor {
    static let shared = DisplayMonitor()

    /// What changed in one settled burst.
    struct Change {
        let before: [String]            // display UUIDs
        let after: [String]
        var displaySetChanged: Bool { Set(before) != Set(after) }
        var added: [String] { after.filter { !before.contains($0) } }
        var removed: [String] { before.filter { !after.contains($0) } }
    }

    /// Quiet time that counts as "the displays have settled".
    nonisolated static let settleSeconds: TimeInterval = 1.0

    private var started = false
    private var handlers: [(Change) -> Void] = []
    private var settleTask: Task<Void, Never>?
    private var lastEvent = Date.distantPast
    /// A reconfiguration has begun and its "done" has not arrived.
    private(set) var reconfiguring = false
    private var known: [String] = []

    /// Called on the main thread once per settled burst.
    func onChange(_ handler: @escaping (Change) -> Void) {
        handlers.append(handler)
        start()
    }

    private func start() {
        guard !started else { return }
        started = true
        known = Self.connectedUUIDs()
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            let beginning = flags.contains(.beginConfigurationFlag)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { DisplayMonitor.shared.noteEvent(beginning: beginning) }
            }
        }, nil)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DisplayMonitor.shared.noteEvent(beginning: false) }
        }
    }

    private func noteEvent(beginning: Bool) {
        lastEvent = Date()
        if beginning { reconfiguring = true }
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.settleSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.reconfiguring = false
            let now = Self.connectedUUIDs()
            let change = Change(before: self.known, after: now)
            self.known = now
            for handler in self.handlers { handler(change) }
        }
    }

    /// Waits until no display event has arrived for `quietFor` seconds, up to
    /// `timeout`. Returns true when it was quiet, false when it gave up. Used
    /// before the two calls the Zoom SDK is touchiest about - installing the
    /// picture and starting the meeting - so neither lands in the middle of
    /// a cable being pulled.
    func awaitQuiet(quietFor: TimeInterval = 1.5, timeout: TimeInterval = 6) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !reconfiguring, Date().timeIntervalSince(lastEvent) >= quietFor { return true }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return false
    }

    // MARK: Reading the displays

    static func connectedUUIDs() -> [String] {
        DisplayResolver.connectedDisplays().map(\.id)
    }

    static func connectedForCapture() -> [DisplayPlan.Display] {
        DisplayResolver.connectedDisplays().map {
            DisplayPlan.Display(uuid: $0.id, pixelSize: CGSize(width: $0.pixelWidth, height: $0.pixelHeight))
        }
    }

    static func describe(_ uuids: [String]) -> String {
        let names = uuids.compactMap { DisplayResolver.screen(forUUID: $0)?.localizedName }
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }

    // MARK: Windows

    private var rescueTask: Task<Void, Never>?

    /// After a display change: once the displays have been quiet for
    /// `StrandedWindowRule.settleSeconds` (a newer change starts the wait again),
    /// moves any window of ours whose frame is on no listed screen onto one that
    /// is there (R45.7). A window on a screen still listed is never moved, however
    /// little of it shows: AirPlay renegotiating reports "settings changed" with
    /// both screens listed and their areas briefly wrong.
    func scheduleRescue(log: @escaping (String) -> Void) {
        rescueTask?.cancel()
        rescueTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(StrandedWindowRule.settleSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.reconfiguring else { return }
            Self.rescueStrandedWindows(log: log)
        }
    }

    /// Moves now any window of ours that is on no listed screen. Windows meant
    /// to fill a display (the full-screen participants panel, status-bar level
    /// windows) are left to the loops that own them.
    @discardableResult
    static func rescueStrandedWindows(log: (String) -> Void) -> Int {
        let screens = NSScreen.screens.map {
            StrandedWindowRule.Screen(name: $0.localizedName, frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        guard !screens.isEmpty else { return 0 }
        let preferred = DisplayResolver.mainDisplayScreen().map {
            StrandedWindowRule.Screen(name: $0.localizedName, frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        var moved = 0
        for window in NSApp.windows where window.isVisible && !window.isMiniaturized {
            if window.styleMask.contains(.fullScreen) { continue }
            if window.level.rawValue >= NSWindow.Level.statusBar.rawValue { continue }
            guard let target = StrandedWindowRule.rescuedFrame(for: window.frame, screens: screens, preferred: preferred) else { continue }
            let before = window.frame
            window.setFrame(target, display: true)
            moved += 1
            log(StrandedWindowRule.logLine(windowTitle: window.title, frame: before, movedTo: target,
                                           onto: (preferred ?? screens[0]).name, screens: screens))
        }
        return moved
    }
}
