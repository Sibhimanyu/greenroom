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
    /// Where the shortcut hints come from: the same bindings Settings edits and
    /// the hotkeys are registered from, so they never disagree.
    @ObservedObject private var shortcuts = ShortcutStore.shared
    /// Injected from GreenroomApp's Sparkle updater controller - the
    /// menu bar is where users live mid-class, so updates are reachable
    /// here too, not just the app menu.
    var checkForUpdates: () -> Void = {}

    var body: some View {
        // Same enable/disable logic as the main window's buttons: Start
        // only when idle, Stop only when starting or live, Record only
        // with a live session (or to stop an active recording).
        // The shortcuts shown here are registered as SYSTEM-WIDE
        // hotkeys (ShortcutRuntime) - they work while other apps are
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
        .shortcutHint(shortcuts.combo(for: .startClass))
        .disabled(coordinator.startActionDisabled) // same gating as the main window's Start

        Button(coordinator.isStopping ? "Ending\u{2026}" : "End Session") {
            coordinator.confirmAndStop()
        }
        .shortcutHint(shortcuts.combo(for: .endSession))
        .disabled(coordinator.isStopping || (!coordinator.isRunning && !coordinator.sceneInUse))

        Button(coordinator.isSavingRecording ? "Saving\u{2026}"
                : coordinator.isRecording ? "Stop Recording" : "Start Recording") {
            coordinator.toggleRecording()
        }
        .shortcutHint(shortcuts.combo(for: .toggleRecording))
        .disabled(coordinator.isSavingRecording
                  || (!coordinator.stageLive && !coordinator.isRecording && !coordinator.recordOnlyActive))

        // Pauses the file only; the meeting carries on.
        Button(coordinator.isRecordingPaused ? "Resume Recording" : "Pause Recording") {
            coordinator.togglePauseRecording()
        }
        .shortcutHint(shortcuts.combo(for: .togglePause))
        .disabled(!coordinator.isRecording || coordinator.isSavingRecording)

        // For the arranged layout, which has no control bar. This session
        // only: the Settings switch stays the default for the next one.
        Button(notes.effectiveEnabled ? "Hide Notes" : "Show Notes") {
            notes.toggle()
        }
        .shortcutHint(shortcuts.combo(for: .toggleNotes))
        .disabled(!SessionNotes.sessionIsLive(coordinator))

        // Which layout Start uses. Greyed while a class is live: that class keeps
        // the layout it started with.
        Menu("Layout: \(coordinator.layoutChoiceName)") {
            LayoutChoiceItems()
        }
        .disabled(coordinator.layoutChoiceLocked)

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
            .shortcutHint(shortcuts.combo(for: .snapBack))

            Button(coordinator.speakerTileQuickHidden ? "Show Speaker Tile" : "Hide Speaker Tile") {
                coordinator.toggleSpeakerTile()
            }
            .shortcutHint(shortcuts.combo(for: .toggleMeeting))
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
        .shortcutHint(shortcuts.combo(for: .openGreenroom))

        Button("Check for Updates\u{2026}", action: checkForUpdates)

        Button("How It Works & Privacy\u{2026}") {
            NSWorkspace.shared.open(AppLinks.safety)
        }

        Button("Quit Greenroom") {
            NSApp.terminate(nil)
        }
    }
}

// MARK: - Shortcut hints

private extension View {
    /// Draws a menu item's shortcut from a binding. Nil, or a key a menu cannot
    /// draw (function keys, the keypad), draws nothing; the hotkey still works.
    @ViewBuilder
    func shortcutHint(_ combo: KeyCombo?) -> some View {
        if let combo, let key = combo.menuKey?.keyEquivalent {
            keyboardShortcut(key, modifiers: combo.eventModifiers)
        } else {
            self
        }
    }
}

private extension KeyCombo {
    var eventModifiers: EventModifiers {
        var m: EventModifiers = []
        if modifiers & KeyCombo.command != 0 { m.insert(.command) }
        if modifiers & KeyCombo.option != 0 { m.insert(.option) }
        if modifiers & KeyCombo.control != 0 { m.insert(.control) }
        if modifiers & KeyCombo.shift != 0 { m.insert(.shift) }
        return m
    }
}

private extension String {
    var keyEquivalent: KeyEquivalent? {
        switch self {
        case "space": return .space
        case "return": return .return
        case "tab": return .tab
        case "escape": return .escape
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "up": return .upArrow
        case "down": return .downArrow
        default: return count == 1 ? KeyEquivalent(Character(self)) : nil
        }
    }
}
