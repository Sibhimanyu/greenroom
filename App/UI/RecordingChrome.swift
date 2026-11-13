//
//  RecordingChrome.swift
//  Greenroom
//
//  What appears on the Mac while a recording is starting or running (phase 4
//  of the Recorditor port, docs/recorditor-integration/controls-port-log.md):
//
//   - the countdown before it starts (a big number in the middle of the screen)
//   - the floating control bar, Record view only (a meeting's controls live on
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
    private let countdown = CountdownOverlayController()

    func update(coordinator: CoordinatorController, recording: Bool, paused: Bool,
                recordOnly: Bool, countdownValue: Int?) {
        if let value = countdownValue {
            countdown.show(value: value, on: coordinator.recordedScreen) { [weak coordinator] in
                coordinator?.cancelRecordingCountdown()
            }
        } else {
            countdown.hide()
        }

        // The border says "this is being recorded", so it is up only while the
        // file is growing: hidden while paused, back on resume.
        if recording, !paused {
            border.show { [weak coordinator] in coordinator?.capturedScreenFrame() }
        } else {
            border.hide()
        }

        if recording, recordOnly {
            bar.show(coordinator: coordinator)
        } else {
            bar.hide()
        }
    }

    func teardown() {
        countdown.hide(); border.hide(); bar.hide()
    }
}

// MARK: - Countdown

/// The big 3-2-1 before a recording starts, with Cancel (Esc). Ported from
/// Recorditor's `CountdownOverlay` (RecorderView.swift), but as a window of its
/// own so it shows over whatever is about to be recorded, not over Greenroom's
/// Home. Never takes keyboard focus: Esc is heard by monitors, and the same
/// shortcut that started the recording cancels it too.
@MainActor
final class CountdownOverlayController {
    private var panel: NSPanel?
    private let model = CountdownModel()
    private var monitors: [Any] = []

    func show(value: Int, on screen: NSScreen?, onCancel: @escaping () -> Void) {
        model.value = value
        model.onCancel = onCancel
        if panel == nil {
            let size = NSSize(width: 340, height: 260)
            let created = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
            created.isReleasedWhenClosed = false
            created.level = .statusBar
            created.isOpaque = false
            created.backgroundColor = .clear
            created.hasShadow = true
            created.hidesOnDeactivate = false
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let host = NSHostingView(rootView: CountdownView(model: model).tint(Brand.green))
            host.frame = NSRect(origin: .zero, size: size)
            created.contentView = host
            panel = created
        }
        if let panel, !panel.isVisible {
            let area = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
            panel.setFrameOrigin(NSPoint(x: (area.midX - panel.frame.width / 2).rounded(),
                                         y: (area.midY - panel.frame.height / 2).rounded()))
            panel.orderFrontRegardless()
            installMonitors()
        }
    }

    func hide() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        panel?.orderOut(nil)
    }

    /// Esc cancels. A local monitor hears it while Greenroom is in front; a
    /// global one while another app is (it needs Accessibility, like the
    /// events tracker; without it the Cancel button and the start shortcut
    /// still work).
    private func installMonitors() {
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.model.onCancel?()
            return nil
        }) { monitors.append(local) }
        if AXIsProcessTrusted(),
           let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
               guard event.keyCode == 53 else { return }
               MainActor.assumeIsolated { self?.model.onCancel?() }
           }) { monitors.append(global) }
    }
}

@MainActor
final class CountdownModel: ObservableObject {
    @Published var value = 3
    var onCancel: (() -> Void)?
}

private struct CountdownView: View {
    @ObservedObject var model: CountdownModel

    var body: some View {
        VStack(spacing: 12) {
            Text("\(model.value)")
                .font(.system(size: 120, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .contentTransition(.numericText(countsDown: true))
                .animation(Collapse.animation, value: model.value)
            Text("Recording starts in\u{2026}")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Cancel (Esc)") { model.onCancel?() }
                .buttonStyle(.bordered)
                .help("Stop the countdown. Nothing is recorded.")
                .accessibilityLabel("Cancel recording")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording starts in \(model.value)")
    }
}

// MARK: - Control bar (Record view)

/// A QuickTime-style floating bar for a recording started from the Record
/// view: REC dot and timer, pause or resume, stop. Ported in shape from
/// Recorditor's `RecordingControlBarController` (Recording/RecordingControlBar.swift):
/// a non-activating panel above every app, on every Space, draggable by its
/// background. Look follows DESIGN.md and the meeting pill (material capsule,
/// red for the recording signal, no amber), not Recorditor's black bar, and
/// it carries only what the Record view needs: no source pickers (the Record
/// view has those), no drawing tools (phase 5).
@MainActor
final class RecordingControlBarController {
    static let size = CGSize(width: 232, height: 44)
    private static let frameKey = "recordingControlBar.frame"

    private var panel: NSPanel?
    private var moveObserver: NSObjectProtocol?

    func show(coordinator: CoordinatorController) {
        if panel == nil {
            let created = BarPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
            created.isReleasedWhenClosed = false
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

    private final class BarPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class FirstMouseHost<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

private struct RecordingControlBarView: View {
    @ObservedObject var coordinator: CoordinatorController

    var body: some View {
        let paused = coordinator.isRecordingPaused
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(paused ? Color.secondary : Color.red)
                    .frame(width: 8, height: 8)
                Text(paused ? "PAUSED" : "REC")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(paused ? Color.secondary : Color.red)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(MeetingControlsModel.clock(seconds: coordinator.recordingElapsed(at: context.date) ?? 0))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
            }
            .padding(.leading, 6)
            Spacer(minLength: 0)
            barButton(paused ? "play.fill" : "pause.fill",
                      help: paused ? "Resume recording" : "Pause recording",
                      tint: .primary) { coordinator.togglePauseRecording() }
            barButton("stop.fill", help: "Stop and save the recording", tint: .red) {
                coordinator.stopTake()
            }
            .disabled(coordinator.takeBusy)
        }
        .padding(.horizontal, 8)
        .frame(width: RecordingControlBarController.size.width, height: RecordingControlBarController.size.height)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }

    private func barButton(_ symbol: String, help: String, tint: Color,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
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
    private var timer: Timer?
    private var rounded = false

    /// `provider` gives the captured area in global CoreGraphics points
    /// (top-left origin), or nil when there is nothing to outline.
    func show(provider: @escaping () -> CGRect?) {
        guard timer == nil else { return }
        apply(provider())
        let tick = Timer(timeInterval: 0.4, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                // A tick can land after hide(); only act while this is the live timer.
                guard let self, self.timer === timer else { return }
                self.apply(provider())
            }
        }
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    private func apply(_ captured: CGRect?) {
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
            panel.contentView = NSHostingView(rootView: RecordingBorderView(rounded: rounded))
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
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
        created.contentView = NSHostingView(rootView: RecordingBorderView(rounded: rounded))
        panel = created
        return created
    }
}

/// Understated: a thin line in the brand tint hugging the recorded area.
private struct RecordingBorderView: View {
    let rounded: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: rounded ? 12 : 0, style: .continuous)
            .strokeBorder(Brand.green.opacity(0.9), lineWidth: 3)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}
