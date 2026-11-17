//
//  RecordingChrome.swift
//  Greenroom
//
//  What appears on the Mac while a recording is starting or running (phase 4
//  of the Recorditor port, docs/recorditor-integration/controls-port-log.md):
//
//   - the countdown before it starts (a big number on the island at the notch,
//     NotchStatusController.swift)
//   - the floating control bar, Record only (a meeting's controls live on
//     the meeting bar instead)
//   - the border around what is being recorded
//
//  All three are Greenroom windows, and Greenroom's windows are never in the
//  recorded picture: a whole-display capture excludes the whole app, and an
//  app or window capture includes only the shared app's or window's own
//  windows (StageScreenSource). None of these needs to know about the capture.
//
//  `RecordingChrome.update` is driven by the coordinator whenever the
//  recording, paused, Record-view or countdown state changes.
//

import AppKit
import SwiftUI

@MainActor
final class RecordingChrome {
    private let border = RecordingBorderController()
    private let bar = RecordingControlBarController()
    private var wasRecording = false

    func update(coordinator: CoordinatorController, recording: Bool, paused: Bool,
                recordOnly: Bool, countdownValue: Int?) {
        // The countdown lives on the island; the end of a countdown that
        // reached go is announced by the coordinator itself.
        NotchStatusController.shared.setCountdown(countdownValue) { [weak coordinator] in
            coordinator?.cancelRecordingCountdown()
        }

        // The border says "this is being recorded", so it is up only while the
        // file is growing: hidden while paused, back on resume.
        if recording, !paused {
            // Only while what is recorded is on this desktop: the outline is on
            // every Space, and a window on another one left it framing nothing.
            border.show(window: { [weak coordinator] in coordinator?.capturedWindowID }) { [weak coordinator] in
                coordinator?.capturedScreenFrame(onThisDesktop: true)
            }
        } else {
            border.hide()
        }

        // The moment it starts (not on resume), what is recorded comes forward.
        if recording, !wasRecording, recordOnly {
            coordinator.bringRecordedForward()
        }
        wasRecording = recording

        if recording, recordOnly {
            bar.show(coordinator: coordinator)
        } else {
            bar.hide()
        }
    }

    // No outline while only previewing: the dashed one that marked what the
    // preview showed was removed (owner, 2026-11-16: "unnecessary before we
    // actually start the meeting"). The solid one says "being recorded".

    /// The way back to a recording whose main window is hidden: the bar, in front.
    func bringBarForward() { bar.bringForward() }

    func teardown() {
        NotchStatusController.shared.setCountdown(nil); border.hide(); bar.hide()
    }
}

// MARK: - Control bar (Record)

/// A QuickTime-style floating bar for a recording started from the Record
/// view: REC dot and timer, pause or resume, stop. Ported in shape from
/// Recorditor's `RecordingControlBarController` (Recording/RecordingControlBar.swift):
/// a non-activating panel above every app, on every Space, draggable by its
/// background. Look follows DESIGN.md and the meeting pill (material capsule,
/// red for the recording signal, no amber), not Recorditor's black bar, and
/// it carries only what the Record view needs: no source pickers (the Record
/// view has those); phase 5 added the Draw button.
@MainActor
final class RecordingControlBarController {
    static let size = CGSize(width: MeetingBarLayout.recordOnlyWidth, height: MeetingBarLayout.height)
    private static let frameKey = "recordingControlBar.frame"

    private var panel: NSPanel?
    private var moveObserver: NSObjectProtocol?

    func show(coordinator: CoordinatorController) {
        if panel == nil {
            let created = BarPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
            created.isReleasedWhenClosed = false
            created.allowsToolTipsWhenApplicationIsInactive = true
            created.level = .statusBar
            created.isOpaque = false
            created.backgroundColor = .clear
            created.hasShadow = true
            created.hidesOnDeactivate = false
            created.isMovableByWindowBackground = true
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            // A belt: some macOS versions honour it for capture. The real
            // exclusion is the capture filter (see the file header).
            created.sharingType = .none
            let host = FirstMouseHost(rootView: RecordingControlBarView(coordinator: coordinator).tint(Brand.green))
            host.frame = NSRect(origin: .zero, size: Self.size)
            created.contentView = host
            panel = created
            moveObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification, object: created, queue: .main) { [weak created] _ in
                MainActor.assumeIsolated {
                    guard let created else { return }
                    UserDefaults.standard.set(NSStringFromRect(created.frame), forKey: Self.frameKey)
                }
            }
        }
        guard let panel, !panel.isVisible else { return }
        let areas = NSScreen.screens.map(\.visibleFrame)
        let saved = UserDefaults.standard.string(forKey: Self.frameKey).map(NSRectFromString)
        // Default: bottom centre of the screen being recorded (else the main one).
        let home = (coordinator.recordedScreen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(MeetingBarPlacement.restore(saved: saved, size: Self.size, areas: areas, defaultArea: home),
                       display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    func bringForward() { panel?.orderFrontRegardless() }

    private final class BarPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class FirstMouseHost<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

/// Same rules as the meeting bar: one timer (the recording's own, there is no
/// class), Share and Draw are icons, and the one red control is Stop. The dot is the
/// recording signal, not a control.
///   [dot REC 1:29] [pause] | [Share] [pencil] [Notes] | [Stop]
private struct RecordingControlBarView: View {
    @ObservedObject var coordinator: CoordinatorController
    @ObservedObject private var shortcuts = ShortcutStore.shared
    @ObservedObject private var notes = SessionNotes.shared

    private typealias L = MeetingBarLayout

    var body: some View {
        let paused = coordinator.isRecordingPaused
        let bindings = shortcuts.bindings
        HStack(spacing: L.spacing) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                pill(paused: paused, seconds: coordinator.recordingElapsed(at: context.date) ?? 0)
            }
            BarIconButton(symbol: paused ? "play.fill" : "pause.fill", width: L.pause,
                          help: MeetingBarModel.help(paused ? "Resume Recording" : "Pause Recording", .togglePause, bindings),
                          spoken: paused ? "Resume recording" : "Pause recording") { coordinator.togglePauseRecording() }
            BarDivider()
            // What is recorded, your look: the same Present menu as the meeting bar's.
            BarPresentButton(width: L.present) { coordinator.presentMenuEntries() }
            // Draw on the screen being recorded (phase 5).
            BarIconButton(
                symbol: "pencil.and.scribble", width: L.draw, on: coordinator.isDrawing,
                help: MeetingBarModel.help(coordinator.isDrawing ? "Close the drawing tools" : "Draw on the screen",
                                           .toggleDrawing, bindings),
                spoken: coordinator.isDrawing ? "Close drawing tools" : "Draw on the screen") {
                coordinator.toggleDrawing()
            }
            .disabled(!coordinator.canDraw && !coordinator.isDrawing)
            // The notes bar: the same action and window as the menu bar's Show Notes.
            BarLabelledButton(
                symbol: "note.text", title: "Notes", width: L.notes, on: notes.effectiveEnabled,
                help: MeetingBarModel.help(notes.effectiveEnabled ? "Close the notes bar" : "Open the notes bar",
                                           .toggleNotes, bindings),
                spoken: notes.effectiveEnabled ? "Close the notes bar" : "Open the notes bar") {
                notes.toggle()
            }
            BarDivider()
            BarRedButton(title: "Stop", width: L.recordOnlyStop,
                         help: MeetingBarModel.help("Stop and save the recording", .toggleRecording, bindings),
                         spoken: "Stop and save the recording",
                         armed: coordinator.exitAsk == .stopTake,
                         armedHelp: "Stop and save the recording",
                         armedTitle: coordinator.exitAskTitle,
                         armedDetail: coordinator.exitAskDetail) { coordinator.confirmStopTake() }
                .disabled(coordinator.takeBusy)
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .frame(width: RecordingControlBarController.size.width, height: RecordingControlBarController.size.height)
        .greenroomGlass(in: Capsule(), interactive: true)
    }

    private func pill(paused: Bool, seconds: TimeInterval) -> some View {
        let clock = MeetingBarModel.clock(seconds)
        return HStack(spacing: 5) {
            BarRecDot(live: !paused)
            Text(paused ? "Paused" : "REC")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.primary)
            Text(clock)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(paused ? Color.secondary : Color.primary)
        }
        .frame(width: L.recordOnlyPill, height: 32)
        .help(paused ? "Recording paused at \(clock)" : "Recording \(clock)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(paused ? "Recording paused at \(clock)" : "Recording \(clock)")
    }
}

// MARK: - Border

/// A thin outline around the content being recorded: a click-through panel,
/// never in the capture. Ported from Recorditor's `RecordingBorderController`
/// (Recording/RecordingBorderController.swift). Upstream was told a display or
/// a window ID at the start; Greenroom asks the live capture for its current
/// frame every 0.4 s instead (`provider`), so a followed window that moves or
/// resizes, a replacement capture, and a changed display are all followed
/// without anyone calling in. Corners follow the content: square for a whole
/// display, rounded for a window.
@MainActor
final class RecordingBorderController {
    private var panel: NSPanel?
    private var link: CADisplayLink?
    private var ticker: BorderTicker?
    private var rounded = false
    private let dashed: Bool

    init(dashed: Bool = false) { self.dashed = dashed }

    /// `provider` gives the captured area in global CoreGraphics points
    /// (top-left origin), or nil when there is nothing to outline.
    ///
    /// Read on every screen refresh, not on a slow timer: a window dragged
    /// around left a 0.4s timer's outline trailing far behind it (owner,
    /// 2026-11-16). One window-list lookup per frame is cheap.
    ///
    /// `window` is the captured window, when it is one. The outline then sits
    /// directly above that window in the stack instead of above everything, so
    /// a window covering it covers its outline too (owner, 2026-11-16: the
    /// outline showed on top of Greenroom over a Finder window underneath).
    func show(window: @escaping () -> CGWindowID? = { nil }, provider: @escaping () -> CGRect?) {
        guard link == nil else { return }
        apply(provider(), above: window())
        let ticker = BorderTicker { [weak self] in self?.apply(provider(), above: window()) }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let link = screen.displayLink(target: ticker, selector: #selector(BorderTicker.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.ticker = ticker
        self.link = link
    }

    func hide() {
        link?.invalidate()
        link = nil
        ticker = nil
        panel?.orderOut(nil)
    }

    /// Frames since the outline was last put back above its window.
    private var sinceRestack = 0

    private func apply(_ captured: CGRect?, above windowID: CGWindowID?) {
        guard let captured, captured.width > 1, captured.height > 1 else { panel?.orderOut(nil); return }
        // CG coordinates are top-left origin; AppKit's are bottom-left.
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        let frame = NSRect(x: captured.minX, y: primaryHeight - captured.maxY,
                           width: captured.width, height: captured.height)
        let isDisplay = NSScreen.screens.contains { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return false }
            return CGDisplayBounds(id) == captured
        }
        let panel = ensurePanel()
        if rounded == isDisplay {
            rounded = !isDisplay
            panel.contentView = NSHostingView(rootView: RecordingBorderView(rounded: rounded, dashed: dashed))
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if let windowID {
            // In the stack with ordinary windows, just above the captured one.
            // Clicking that app (or Greenroom) re-stacks windows, so it is put
            // back every few frames; ordering into the same place is a no-op.
            if panel.level != .normal { panel.level = .normal; sinceRestack = .max }
            sinceRestack = sinceRestack == .max ? .max : sinceRestack + 1
            if !panel.isVisible || sinceRestack >= 4 {
                panel.order(.above, relativeTo: Int(windowID))
                sinceRestack = 0
            }
        } else {
            // A whole display: nothing covers it, so the outline rides on top.
            if panel.level != .statusBar { panel.level = .statusBar }
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let created = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                              backing: .buffered, defer: false)
        created.isReleasedWhenClosed = false
        created.level = .statusBar
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = false
        created.ignoresMouseEvents = true
        created.hidesOnDeactivate = false
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        created.sharingType = .none
        created.contentView = NSHostingView(rootView: RecordingBorderView(rounded: rounded, dashed: dashed))
        panel = created
        return created
    }
}

/// The display link's target: it needs an Objective-C selector.
private final class BorderTicker: NSObject {
    private let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    @objc func tick() { MainActor.assumeIsolated { action() } }
}

/// Understated: a thin line in the brand tint hugging the recorded area.
/// Dashed and lighter for a preview, so it never reads as "recording".
private struct RecordingBorderView: View {
    let rounded: Bool
    var dashed = false

    var body: some View {
        RoundedRectangle(cornerRadius: rounded ? 12 : 0, style: .continuous)
            .strokeBorder(Brand.green.opacity(dashed ? 0.75 : 0.9),
                          style: StrokeStyle(lineWidth: dashed ? 2 : 3, dash: dashed ? [8, 6] : []))
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}
