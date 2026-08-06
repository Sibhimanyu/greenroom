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
        Button(coordinator.isRunning ? "Starting\u{2026}" : "Start Session") {
            coordinator.start()
        }
        .disabled(coordinator.isRunning)

        Button("Stop Session") {
            coordinator.stop()
        }

        Button(coordinator.isRecording ? "Stop Recording" : "Start Recording") {
            coordinator.toggleRecording()
        }

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
