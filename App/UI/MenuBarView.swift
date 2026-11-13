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
import AVFoundation

struct MenuBarView: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var notes = SessionNotes.shared
    /// Where the shortcut hints come from: the same bindings Settings edits and
    /// the hotkeys are registered from, so they never disagree.
    @ObservedObject private var shortcuts = ShortcutStore.shared
    /// Injected from GreenroomApp's Sparkle updater controller - the
    /// menu bar is where users live mid-class, so updates are reachable
    /// here too, not just the app menu.
    var checkForUpdates: () -> Void = {}

    @State private var lastSession: MenuBarLastSession?
    /// Bumped once a second while a session runs, so the elapsed times in the
    /// header are redrawn if the menu is open. They are always current on open.
    @State private var tick = 0
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        // The list comes from MenuBarModel (pure, unit-tested); this view only
        // draws it and runs the actions. The shortcuts shown are registered as
        // SYSTEM-WIDE hotkeys (ShortcutRuntime): macOS swallows the keypress
        // before it could reach these items, so the hints are documentation,
        // not a second trigger.
        let _ = tick
        let items = MenuBarModel.items(state: state(), problems: problems(),
                                       lastSession: lastSession, shortcuts: shortcuts.bindings)
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            row(item)
        }
        .onAppear { loadLastSession() }
        .onReceive(ticker) { _ in if coordinator.isRunning || coordinator.sceneInUse { tick &+= 1 } }
        .onChange(of: coordinator.sceneInUse) { _, _ in loadLastSession() }
    }

    // MARK: Drawing one item

    @ViewBuilder
    private func row(_ item: MenuBarItem) -> some View {
        switch item.kind {
        case .separator:
            Divider()
        case .status:
            if let symbol = item.symbol {
                Label(item.title, systemImage: symbol)
                    .foregroundStyle(item.attention ? Brand.net : Color.primary)
            } else {
                Text(item.title)
            }
        case .layoutMenu:
            Menu {
                LayoutChoiceItems()
            } label: {
                Label(item.title, systemImage: item.symbol ?? "rectangle.3.group")
            }
        case .action(let action):
            Button(role: item.destructive ? .destructive : nil) {
                run(action)
            } label: {
                if let symbol = item.symbol {
                    Label(item.title, systemImage: symbol)
                } else {
                    Text(item.title)
                }
            }
            .shortcutHint(item.shortcut)
        }
    }

    // MARK: State in

    private func state() -> MenuBarState {
        var s = MenuBarState()
        s.isStarting = coordinator.isRunning && !coordinator.stageLive
        s.isLive = coordinator.sceneInUse
        s.isStopping = coordinator.isStopping
        s.className = coordinator.className
        s.sessionElapsed = coordinator.sessionStartedAt.map { max(0, Date().timeIntervalSince($0)) }
        s.isRecording = coordinator.isRecording
        s.isPaused = coordinator.isRecordingPaused
        s.isSavingRecording = coordinator.isSavingRecording
        s.recordingElapsed = coordinator.recordingElapsed()
        s.notesShown = notes.effectiveEnabled
        s.layoutToolsAvailable = coordinator.layoutToolsAvailable
        s.speakerTileHidden = coordinator.speakerTileQuickHidden
        s.canToggleSpeakerTile = coordinator.canToggleMeeting
        s.canDraw = coordinator.canDraw
        s.isDrawing = coordinator.isDrawing
        s.layoutName = coordinator.layoutChoiceName
        s.layoutLocked = coordinator.layoutChoiceLocked
        s.uploadProgress = coordinator.youtubeUploadProgress
        s.cuesListening = coordinator.cuesListening
        s.cuesPaused = coordinator.cuesPaused
        s.cuesStatusText = coordinator.cuesPaused
            ? "Cues is paused \u{2014} you are muted"
            : CuesStatus.listening(linksFound: coordinator.cuesLinkCount)
        return s
    }

    /// The same four checks as Home's readiness pills, for the mode Home is
    /// in, so the menu and Home never disagree about what is wrong.
    private func problems() -> [MenuBarProblem] {
        var out: [MenuBarProblem] = []
        let mode = coordinator.meetingMode
        if mode != .record {
            let sdk = coordinator.sdkClientID.isEmpty || coordinator.sdkClientSecret.isEmpty
            let host = coordinator.s2sAccountID.isEmpty || coordinator.s2sClientID.isEmpty
                || coordinator.s2sClientSecret.isEmpty
            if mode == .create ? (sdk || host) : sdk {
                out.append(MenuBarProblem(fix: .zoomSettings, text: "Zoom: add credentials"))
            }
        }
        if !coordinator.cameraIsOff {
            let a = AVCaptureDevice.authorizationStatus(for: .video)
            if a == .denied || a == .restricted {
                out.append(MenuBarProblem(fix: .cameraPrivacy, text: "Camera: not allowed"))
            }
        }
        let m = AVCaptureDevice.authorizationStatus(for: .audio)
        if m == .denied || m == .restricted {
            out.append(MenuBarProblem(fix: .micPrivacy, text: "Mic: not allowed"))
        }
        if coordinator.shareTarget.kind.capturesScreen, !StageCompositor.screenRecordingGranted {
            out.append(MenuBarProblem(fix: .screenPrivacy, text: "Screen: permission needed"))
        }
        return out
    }

    /// Newest session on disk, as Home's footer reads it.
    private func loadLastSession() {
        Task.detached(priority: .utility) {
            guard let newest = ScreenroomLibrary.presentations().first else {
                await MainActor.run { lastSession = nil }
                return
            }
            var length: String?
            if let url = newest.recording,
               let seconds = try? await AVURLAsset(url: url).load(.duration).seconds,
               seconds.isFinite, seconds > 0 {
                length = SessionsFormat.length(seconds)
            }
            let found = MenuBarLastSession(path: newest.folder.path, title: newest.presenter, length: length)
            await MainActor.run { lastSession = found }
        }
    }

    // MARK: Actions out

    /// openWindow RECREATES the main window when it was closed - ordering front
    /// an existing window (showMainWindow) found nothing and silently did
    /// nothing (reproduced live).
    private func showMain() {
        openWindow(id: "main")
        coordinator.showMainWindow()
    }

    private func home(_ mode: MeetingMode) {
        coordinator.meetingMode = mode
        coordinator.mainPage = .home
        showMain()
    }

    private func run(_ action: MenuBarAction) {
        switch action {
        case .newMeeting:
            // The same click as Home's button in New mode. Without credentials
            // Start refuses, so go where the fix is instead of doing nothing.
            coordinator.meetingMode = .create
            if coordinator.startActionDisabled { home(.create) } else { coordinator.start() }
        case .joinMeeting: home(.join)
        // Never starts silently: Home's Record mode, where its button gets ready.
        case .record: home(.record)
        case .sessions:
            coordinator.mainPage = .sessions
            showMain()
        case .openLastSession:
            if let last = lastSession { coordinator.mainPage = .detail(last.path) }
            showMain()
        case .settings:
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        case .showGreenroom, .showMeeting:
            // A live class comes forward as itself (meeting window or control
            // bar); with none, or in the Record view, the main window shows it.
            if !coordinator.bringLiveSessionForward() { showMain() }
        case .checkForUpdates: checkForUpdates()
        case .howItWorks: NSWorkspace.shared.open(AppLinks.safety)
        case .quit: NSApp.terminate(nil)
        case .toggleRecording: coordinator.toggleRecording()
        case .togglePause: coordinator.togglePauseRecording()
        case .toggleNotes: notes.toggle()
        case .snapBack: coordinator.snapWindowsBack()
        case .toggleSpeakerTile: coordinator.toggleSpeakerTile()
        case .toggleDrawing: coordinator.toggleDrawing()
        case .endSession: coordinator.confirmAndStop()
        case .stopCues: coordinator.stopCuesForClass()
        case .fix(let fix):
            switch fix {
            case .zoomSettings:
                openSettings()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .showSettingsTab, object: "zoom")
                }
            case .cameraPrivacy: openPrivacy("Privacy_Camera")
            case .micPrivacy: openPrivacy("Privacy_Microphone")
            case .screenPrivacy: openPrivacy("Privacy_ScreenCapture")
            }
        }
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
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
