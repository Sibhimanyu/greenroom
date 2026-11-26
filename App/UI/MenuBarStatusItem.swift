//
//  MenuBarStatusItem.swift
//  Greenroom
//
//  The menu bar icon and its menu: a plain AppKit NSStatusItem whose menu is
//  drawn by MeetingMenuPanel, not by NSMenu.
//
//  Why not SwiftUI's MenuBarExtra: its status item is owned by SwiftUI and stops
//  answering clicks after the user switches Spaces while the app is inactive,
//  and Greenroom is almost always inactive. Why not `item.menu` either: on this
//  macOS an NSMenu shows nothing while Greenroom is not the active app after a
//  desktop swipe (the same fault as the meeting bar's menus, see
//  MeetingMenuPanel), and activating Greenroom would drag its windows forward.
//  So the button has a target/action; a click builds the entries and
//  MeetingMenuPanel hangs them below the button as a floating non-activating panel.
//
//  The list itself is MenuBarModel (pure, tested); this file gathers the state
//  it needs, turns the items into MenuEntry rows when the icon is clicked and
//  runs the actions. The shortcut hints are only hints: the hotkeys are global
//  (ShortcutRuntime) and swallow the key first. Clicks and Space changes are
//  logged to ~/Library/Logs/Greenroom-menubar.log.
//
import AppKit
import AVFoundation
import Combine
import SwiftUI

/// The SwiftUI window actions, which only exist inside the SwiftUI environment.
/// `MenuBarActionBridge` (a `Commands`, alive for the app's whole life) hands
/// them over so the AppKit menu can call them.
@MainActor
enum SwiftUIActions {
    static var openWindow: OpenWindowAction?
    static var openSettings: OpenSettingsAction?
    static var checkForUpdates: () -> Void = {}
}

/// Lives in `.commands`, which SwiftUI builds at launch and keeps. Its body
/// stores the environment actions; it adds the app menu's "Check for Updates".
struct MenuBarActionBridge: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    let checkForUpdates: () -> Void

    var body: some Commands {
        let _ = capture()
        CommandGroup(after: .appInfo) {
            Button("Check for Updates\u{2026}") { checkForUpdates() }
        }
    }

    private func capture() {
        MainActor.assumeIsolated {
            SwiftUIActions.openWindow = openWindow
            SwiftUIActions.openSettings = openSettings
            SwiftUIActions.checkForUpdates = checkForUpdates
        }
    }
}

@MainActor
final class MenuBarStatusItem: NSObject {

    private static var shared: MenuBarStatusItem?

    /// Creates the item once. The coordinator is made by SwiftUI, which may be
    /// a beat behind the app delegate, so this retries until it exists.
    static func install() {
        guard shared == nil else { return }
        guard let coordinator = CoordinatorController.shared else {
            DispatchQueue.main.async { install() }
            return
        }
        shared = MenuBarStatusItem(coordinator: coordinator)
    }

    private let coordinator: CoordinatorController
    private let item: NSStatusItem
    private let notes = SessionNotes.shared
    private let shortcuts = ShortcutStore.shared
    private var lastSession: MenuBarLastSession?
    private var bag = Set<AnyCancellable>()

    private init(coordinator: CoordinatorController) {
        self.coordinator = coordinator
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.setAccessibilityLabel("Greenroom")
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MenuBarLog.write("Space changed (app active \(NSApp.isActive ? "yes" : "no"))")
        }
        renderLabel()
        loadLastSession()

        // REC keeps the mark as narrow as ever (a wider label got hidden behind
        // the notch mid-class, 2026-11-17), so only Cues changes the label.
        Publishers.CombineLatest3(coordinator.$cuesListening, coordinator.$cuesPaused, coordinator.$cuesOnRail)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.renderLabel() } }
            .store(in: &bag)
        Publishers.CombineLatest(coordinator.$stageLive, coordinator.$recordOnlyActive)
            .map { $0 || $1 }.removeDuplicates()
            .sink { [weak self] _ in self?.loadLastSession() }
            .store(in: &bag)
    }

    // MARK: Label

    /// The mark, a one-colour template image. While Cues listens on the rail
    /// the waveform sits before it in the same image, so the template stays one
    /// image. Never two waveforms: Cues's own item shows when the rail does not.
    private func renderLabel() {
        guard let button = item.button else { return }
        let mark = NSImage(named: "MenuBarMark")
        let image: NSImage?
        if coordinator.cuesListening && coordinator.cuesOnRail, let mark {
            let symbol = coordinator.cuesPaused ? "waveform.slash" : "waveform"
            let wave = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            let gap: CGFloat = 3
            let waveSize = wave?.size ?? .zero
            let size = NSSize(width: waveSize.width + gap + mark.size.width,
                              height: max(waveSize.height, mark.size.height))
            image = NSImage(size: size, flipped: false) { _ in
                wave?.draw(in: NSRect(x: 0, y: (size.height - waveSize.height) / 2,
                                      width: waveSize.width, height: waveSize.height))
                mark.draw(in: NSRect(x: waveSize.width + gap, y: (size.height - mark.size.height) / 2,
                                     width: mark.size.width, height: mark.size.height))
                return true
            }
        } else {
            image = mark
        }
        image?.isTemplate = true
        image?.accessibilityDescription = "Greenroom"
        button.image = image
    }

    // MARK: State in

    private func state() -> MenuBarState {
        var s = MenuBarState()
        s.isStarting = coordinator.phase.isStarting
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
        s.inMeeting = coordinator.zoomChatClient.myUserID != nil
        s.videoStopped = coordinator.videoStopped
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
            let sdk = !coordinator.zoomSDKReady
            let host = !coordinator.zoomHostingReady
            if mode == .create ? (sdk || host) : sdk {
                out.append(MenuBarProblem(fix: .zoomSettings, text: "Zoom: sign in"))
            } else if let attention = coordinator.zoomRouteAttention {
                out.append(MenuBarProblem(fix: .zoomSettings, text: attention))
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

    /// Newest session on disk, as Home's footer reads it. Kept ready, so the
    /// menu never waits on the disk when it opens.
    private func loadLastSession() {
        Task.detached(priority: .utility) { [weak self] in
            guard let newest = ScreenroomLibrary.presentations().first else {
                await MainActor.run { self?.lastSession = nil }
                return
            }
            var length: String?
            if let url = newest.recording,
               let seconds = try? await AVURLAsset(url: url).load(.duration).seconds,
               seconds.isFinite, seconds > 0 {
                length = SessionsFormat.length(seconds)
            }
            let found = MenuBarLastSession(path: newest.folder.path, title: newest.presenter, length: length)
            await MainActor.run { self?.lastSession = found }
        }
    }

    // MARK: Click

    @objc private func clicked() {
        MenuBarLog.write("Icon clicked (app active \(NSApp.isActive ? "yes" : "no"))")
        guard let button = item.button else {
            MenuBarLog.write("Panel failed: the status item has no button")
            return
        }
        let entries = menuEntries()
        if MeetingMenuPanel.show(entries, belowStatusButton: button) {
            MenuBarLog.write("Panel shown or toggled (\(entries.count) entries)")
        } else {
            MenuBarLog.write("Panel failed: the button has no window")
        }
        loadLastSession()
    }

    // MARK: Items as entries

    private func menuEntries() -> [MenuEntry] {
        MenuBarModel.items(state: state(), problems: problems(),
                           lastSession: lastSession, shortcuts: shortcuts.bindings)
            .map(entry(for:))
    }

    private func entry(for item: MenuBarItem) -> MenuEntry {
        switch item.kind {
        case .separator:
            return .separator
        case .status:
            return .header(item.title)
        case .layoutMenu:
            let library = coordinator.layoutLibrary
            var rows: [MenuEntry] = []
            for template in library.templates {
                let id = template.id
                rows.append(.item(template.name, checked: library.activeID == id) { [weak self] in
                    self?.coordinator.layoutLibrary.select(id)
                })
            }
            return .submenu(item.title, rows)
        case .presentMenu:
            // Built each time the menu opens, so the app and window lists are current.
            return .submenu(item.title, coordinator.presentMenuEntries())
        case .action(let action):
            return .item(item.title, shortcut: item.shortcut) { [weak self] in self?.run(action) }
        }
    }

    // MARK: Actions out

    /// openWindow RECREATES the main window when it was closed - ordering front
    /// an existing window (showMainWindow) found nothing and silently did
    /// nothing (reproduced live). The action is the SwiftUI one, handed over by
    /// MenuBarActionBridge; showMainWindow is the fallback before it arrives.
    private func showMain() {
        NSApp.activate(ignoringOtherApps: true)
        coordinator.mainWindowOpenedOnPurpose()
        SwiftUIActions.openWindow?(id: "main")
        coordinator.showMainWindow()
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let open = SwiftUIActions.openSettings {
            open()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
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
        case .showGreenroom, .showMeeting:
            // A live class comes forward as itself (meeting window or control
            // bar); with none, or in the Record view, the main window shows it.
            if !coordinator.bringLiveSessionForward() { showMain() }
        case .openGreenroomWindow: home(coordinator.meetingMode)
        case .checkForUpdates: SwiftUIActions.checkForUpdates()
        case .howItWorks: NSWorkspace.shared.open(AppLinks.safety)
        case .quit: NSApp.terminate(nil)
        case .toggleRecording: coordinator.toggleRecording()
        case .togglePause: coordinator.togglePauseRecording()
        case .toggleNotes: notes.toggle()
        case .snapBack: coordinator.snapWindowsBack()
        case .toggleSpeakerTile: coordinator.toggleSpeakerTile()
        case .toggleDrawing: coordinator.toggleDrawing()
        case .toggleStopVideo: coordinator.toggleStopVideo()
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

/// ~/Library/Logs/Greenroom-menubar.log, one ISO-time line per event, appended.
enum MenuBarLog {
    static func write(_ line: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Greenroom-menubar.log")
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
