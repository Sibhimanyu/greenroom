//
//  ShortcutRuntime.swift
//  Greenroom
//
//  Turns the bindings in ShortcutStore into system-wide hotkeys, and runs the
//  action when one is pressed. Re-registers by itself whenever the bindings or
//  the layout library change, so a change in Settings works at once, with no
//  relaunch.
//
//  Each action resolves the coordinator at press time and guards on session
//  state, mirroring the buttons' enabled states: a shortcut that does not apply
//  right now does nothing.
//
import AppKit
import Combine

@MainActor
final class ShortcutRuntime {

    static let shared = ShortcutRuntime()

    private var cancellables = Set<AnyCancellable>()
    private var attached = false
    /// Ids already reported as taken, so an edit elsewhere does not repeat the line.
    private var reported: Set<String> = []
    private var layouts: [ShortcutLayoutRef] = []

    func start() {
        let store = ShortcutStore.shared
        // Published fires before the value lands, so each is read a turn later.
        store.$bindings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        store.$recordingSlot
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        attachToCoordinator()
        // The coordinator can be built a beat after launch.
        DispatchQueue.main.async { [weak self] in self?.attachToCoordinator() }
        refresh()
    }

    /// "Use layout" rows follow the library: a new layout gets a row, a renamed one
    /// a new title, and a deleted one loses its binding. Only those changes are
    /// watched; dragging a piece in the editor changes the library dozens of times
    /// a second and must not re-register every key each time.
    private func attachToCoordinator() {
        guard !attached, let coordinator = CoordinatorController.shared else { return }
        attached = true
        coordinator.$layoutLibrary
            .map { $0.templates.map { ShortcutLayoutRef(id: $0.id, name: $0.name) } }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] refs in
                guard let self else { return }
                self.layouts = refs
                ShortcutStore.shared.prune(keepingTemplates: Set(refs.map(\.id)))
                self.refresh()
            }
            .store(in: &cancellables)
    }

    /// Registers what the store says, or nothing while a recorder is listening.
    func refresh() {
        let store = ShortcutStore.shared
        guard store.recordingSlot == nil else {
            HotkeyManager.shared.unregisterAll()
            return
        }
        let slots = ShortcutCatalog.slots(layouts: layouts)
        let resolved = store.bindings.resolved(among: slots)
        let hotkeys = resolved.map { entry in
            HotkeyManager.Hotkey(id: entry.slot.id, keyCode: entry.combo.keyCode,
                                 modifiers: entry.combo.modifiers) {
                ShortcutRuntime.perform(entry.slot)
            }
        }
        let failed = Set(HotkeyManager.shared.replaceAll(hotkeys))
        store.setUnavailable(failed)

        // Another running app already owning a combination is the one way these
        // silently do nothing, so say it in the log as well as on the row.
        let fresh = failed.subtracting(reported)
        if !fresh.isEmpty {
            let labels = resolved.filter { fresh.contains($0.slot.id) }.map(\.combo.glyphs).sorted()
            CoordinatorController.shared?.reportUnavailableShortcuts(labels)
        }
        reported = failed
    }

    // MARK: - Actions

    static func perform(_ slot: ShortcutSlot) {
        guard let c = CoordinatorController.shared else { return }
        switch slot {
        case .layout(let id):
            c.useLayout(id)
        case .action(let action):
            switch action {
            case .startClass:
                c.start() // guards itself when busy/live
            case .endSession:
                guard c.isRunning || c.sceneInUse else { return }
                c.confirmAndStop() // destructive - always confirms
            case .toggleRecording:
                guard !c.isSavingRecording, c.stageLive || c.isRecording else { return }
                c.toggleRecording()
            case .clip1: c.markClip(minutes: 1)
            case .clip2: c.markClip(minutes: 2)
            case .clip5: c.markClip(minutes: 5)
            case .snapBack:
                c.snapWindowsBack()
            case .toggleMeeting:
                // Gated in the action: needs a placed Meeting piece in the layout.
                c.toggleSpeakerTile()
            case .toggleMic:
                guard let controls = c.meetingControls, controls.inMeeting else { return }
                controls.toggleMute()
                ToastController.show(controls.muted ? "Microphone muted" : "Microphone on", kind: .success)
            case .toggleCamera:
                guard let controls = c.meetingControls, controls.inMeeting else { return }
                controls.toggleCamera()
                ToastController.show(controls.cameraOn ? "Camera on" : "Camera off", kind: .success)
            case .toggleChat:
                guard let controls = c.meetingControls, controls.inMeeting else { return }
                controls.toggleChat()
            case .toggleNotes:
                guard SessionNotes.sessionIsLive(c) else { return }
                SessionNotes.shared.toggle()
            case .showMeetingWindow:
                c.openMeetingWindow() // custom-UI meetings only; guards itself
            case .toggleMeetingBar:
                MeetingControlBarController.toggleCollapsed() // only while the bar is on screen
            case .switchGalleryOrSpeaker:
                ParticipantGridWindowController.toggleGalleryOrSpeaker()
            case .openGreenroom:
                c.bringMainWindowForward()
            case .openSessions:
                c.mainPage = .sessions
                c.bringMainWindowForward()
            }
        }
    }
}
