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

    var body: some View {
        // Same enable/disable logic as the main window's buttons: Start
        // only when idle, Stop only when starting or live, Record only
        // with a live OBS session (or to stop an active recording).
        Button(coordinator.isRunning ? "Starting\u{2026}"
               : coordinator.virtualCamActive ? "Session Running" : "Start Session") {
            coordinator.start()
        }
        .disabled(coordinator.isRunning || coordinator.virtualCamActive || coordinator.isStopping)

        Button(coordinator.isStopping ? "Stopping\u{2026}" : "Stop Session") {
            coordinator.stop()
        }
        .disabled(coordinator.isStopping || (!coordinator.isRunning && !coordinator.virtualCamActive))

        Button(coordinator.isRecording ? "Stop Recording" : "Start Recording") {
            coordinator.toggleRecording()
        }
        .disabled(!coordinator.virtualCamActive && !coordinator.isRecording)

        Divider()

        Button("Snap Windows Back") {
            coordinator.snapWindowsBack()
        }

        Button("Open Chat Window") {
            coordinator.joinChatOnly()
        }
        .disabled(coordinator.isConnectingChat || coordinator.meetingNumber.isEmpty)

        Divider()

        Button("Show Greenroom") {
            coordinator.showMainWindow()
        }

        Button("Quit Greenroom") {
            NSApp.terminate(nil)
        }
    }
}
