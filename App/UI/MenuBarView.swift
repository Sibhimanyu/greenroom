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
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var notes = SessionNotes.shared
    /// Injected from GreenroomApp's Sparkle updater controller - the
    /// menu bar is where users live mid-class, so updates are reachable
    /// here too, not just the app menu.
    var checkForUpdates: () -> Void = {}

    var body: some View {
        // Same enable/disable logic as the main window's buttons: Start
        // only when idle, Stop only when starting or live, Record only
        // with a live session (or to stop an active recording).
        // The ⌥⌘ shortcuts shown here are registered as SYSTEM-WIDE
        // hotkeys (HotkeyManager) - they work while other apps are
        // focused, and macOS swallows the keypress before it could reach
        // these menu items, so the hints below are documentation, not a
        // second trigger.
        Button(coordinator.isRunning ? "Starting\u{2026}"
               : coordinator.stageLive ? "In Session"
               : coordinator.recordOnlyActive ? (coordinator.isRecording ? "Recording" : "Ready to Record")
               : coordinator.meetingMode == .record ? "Get Ready"
               : coordinator.meetingMode == .create ? "Start Meeting" : "Join Meeting") {
            coordinator.start()
        }
        .keyboardShortcut("g", modifiers: [.option, .command])
        .disabled(coordinator.startActionDisabled) // same gating as the main window's Start

        Button(coordinator.isStopping ? "Ending\u{2026}" : "End Session") {
            coordinator.confirmAndStop()
        }
        .keyboardShortcut("x", modifiers: [.option, .command])
        .disabled(coordinator.isStopping || (!coordinator.isRunning && !coordinator.sceneInUse))

        Button(coordinator.isSavingRecording ? "Saving\u{2026}"
                : coordinator.isRecording ? "Stop Recording" : "Start Recording") {
            coordinator.toggleRecording()
        }
        .keyboardShortcut("r", modifiers: [.option, .command])
        .disabled(coordinator.isSavingRecording
                  || (!coordinator.stageLive && !coordinator.isRecording && !coordinator.recordOnlyActive))

        // For the arranged layout, which has no control bar. This session
        // only: the Settings switch stays the default for the next one.
        Button(notes.effectiveEnabled ? "Hide Notes" : "Show Notes") {
            notes.toggle()
        }
        .disabled(!SessionNotes.sessionIsLive(coordinator))

        // The upload runs in the background; this is where its progress
        // lives, rather than a toast the teacher would have to watch.
        if let progress = coordinator.youtubeUploadProgress {
            Text("Uploading to YouTube \u{00B7} \(Int((progress * 100).rounded()))%")
        }

        // Cues: what it is doing, and the per-class off switch. The cards
        // themselves are on the participants panel or the waveform item.
        if coordinator.cuesListening {
            Text(coordinator.cuesPaused
                 ? "Cues is paused \u{2014} you are muted"
                 : CuesStatus.listening(linksFound: coordinator.cuesLinkCount))
            Button("Stop Cues for This Session") {
                coordinator.stopCuesForClass()
            }
        }

        Divider()

        // Hidden, not greyed, in a session that arranges nothing: there is no
        // layout to snap back to and no tile to hide.
        if coordinator.layoutToolsAvailable {
            Button("Snap Windows Back") {
                coordinator.snapWindowsBack()
            }
            .keyboardShortcut("s", modifiers: [.option, .command])

            Button(coordinator.speakerTileQuickHidden ? "Show Speaker Tile" : "Hide Speaker Tile") {
                coordinator.toggleSpeakerTile()
            }
            .keyboardShortcut("z", modifiers: [.option, .command])
            .disabled(!coordinator.canToggleMeeting)

            Divider()
        }

        Button("Show Greenroom") {
            // openWindow RECREATES the window when it was closed -
            // ordering front an existing window (showMainWindow) found
            // nothing and silently did nothing (reproduced live).
            openWindow(id: "main")
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
