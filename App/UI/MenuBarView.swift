//
//  MenuBarView.swift
//  Greenroom
//
//  The menu bar dropdown - quick session controls without hunting for the
//  main window: start/stop, and "Snap Windows Back" for after windows get
//  dragged out of the session layout.
//
import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    /// Injected from GreenroomApp's Sparkle updater controller - the
    /// menu bar is where users live mid-class, so updates are reachable
    /// here too, not just the app menu.
    var checkForUpdates: () -> Void = {}

    var body: some View {
        // Same enable/disable logic as the main window's buttons: Start
        // only when idle, Stop only when starting or live, Record only
        // with a live OBS session (or to stop an active recording).
        // The ⌃⌥⌘ shortcuts shown here are registered as SYSTEM-WIDE
        // hotkeys (HotkeyManager) - they work while other apps are
        // focused, and macOS swallows the keypress before it could reach
        // these menu items, so the hints below are documentation, not a
        // second trigger.
        Button(coordinator.isRunning ? "Starting\u{2026}"
               : coordinator.virtualCamActive ? "In Session"
               : coordinator.meetingMode == .create ? "Start Meeting" : "Join Meeting") {
            coordinator.start()
        }
        .keyboardShortcut("g", modifiers: [.control, .option, .command])
        .disabled(coordinator.isRunning || coordinator.virtualCamActive || coordinator.isStopping)

        Button(coordinator.isStopping ? "Ending\u{2026}" : "End Session") {
            coordinator.stop()
        }
        .keyboardShortcut("x", modifiers: [.control, .option, .command])
        .disabled(coordinator.isStopping || (!coordinator.isRunning && !coordinator.virtualCamActive))

        Button(coordinator.isRecording ? "Stop Recording" : "Start Recording") {
            coordinator.toggleRecording()
        }
        .keyboardShortcut("r", modifiers: [.control, .option, .command])
        .disabled(!coordinator.virtualCamActive && !coordinator.isRecording)

        Divider()

        Button("Snap Windows Back") {
            coordinator.snapWindowsBack()
        }
        .keyboardShortcut("s", modifiers: [.control, .option, .command])

        Button("Open Chat Window") {
            coordinator.joinChatOnly()
        }
        .disabled(coordinator.isConnectingChat || coordinator.meetingNumber.isEmpty)

        Divider()

        Button("Show Greenroom") {
            coordinator.showMainWindow()
        }

        Button("Check for Updates\u{2026}", action: checkForUpdates)

        Button("How It Works & Privacy\u{2026}") {
            NSWorkspace.shared.open(AppLinks.safety)
        }

        Button("Quit Greenroom") {
            NSApp.terminate(nil)
        }
    }
}
