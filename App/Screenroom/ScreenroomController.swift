//
//  ScreenroomController.swift
//  Greenroom
//
//  Screenroom: a presentation, the camera watching it, and the notes taken while
//  it happens. See docs/marks-evaluation-plan.md.
//
//  The plan's premise 4 is the one that shapes this file: the evaluator is
//  watching a person, forming a judgement and typing, all at once, and every
//  keystroke spent on anything other than the words is attention taken off
//  the student in front of them. So there is no category to pick, no field to
//  tab into, no timestamp to set. You type, you press Return, and the note is
//  on disk before you have looked back up.
//
//  The one piece of cleverness is where the timestamp comes from, and it is
//  worth the paragraph it costs. A note is stamped at the moment its FIRST
//  character was typed, not when Return was pressed. The moment worth marking
//  is the moment the evaluator noticed something - that is when their hands
//  moved. Everything after that is them finding the words, and a long note is
//  exactly the kind worth writing, so stamping on Return would push the most
//  considered notes the furthest from the thing they describe. Fifteen
//  seconds of typing is fifteen seconds of drift on the note that mattered
//  most.
//
//  One presentation is one folder. It holds presentation.mov, notes.jsonl
//  and the session.json that Greenroom's Sessions window already reads, so a
//  presentation shows up there beside the classes without a line of code in
//  that window.
//
import AVFoundation
import Combine
import Foundation

@MainActor
final class ScreenroomController: ObservableObject {

    // MARK: The presentation

    /// Who is presenting. Names the folder, exactly as the class name does
    /// for a session, and is the one thing that has to be typed before the
    /// tape rolls.
    @Published var presenter: String = ""

    /// Decided when recording starts and held until the presentation is
    /// finished, so a tape stopped and restarted lands in the same folder as
    /// the notes already written.
    @Published private(set) var folder: URL?

    /// This presentation's notes, oldest first. Kept in memory as well as on
    /// disk because the list on screen is the evaluator's only way of seeing
    /// what they have already said.
    @Published private(set) var notes: [ScreenroomNote] = []

    /// Whether the speaker is watching the notes land.
    ///
    /// Deliberately NOT persisted. See ScreenroomSpeakerView: a stored preference
    /// would mean a teacher who once coached a rehearsal is silently still
    /// coaching in an exam three weeks later, and the student would be the
    /// one to find out. Screenroom opens as an evaluation tool every launch.
    @Published var speakerIsWatching = false

    // MARK: The note being typed

    @Published var draft: String = "" {
        didSet { draftChanged(from: oldValue) }
    }

    /// Where the tape was when this draft's first character was typed.
    private var draftAtMs: Int?
    private var draftStartedAt: Date?

    // MARK: Camera

    let recorder: ScreenroomRecorder

    @Published private(set) var cameras: [LocalDeviceResolver.Camera] = []

    /// Where the picture comes from. Remembered between presentations: which
    /// camera points at the front of the room, or which window a remote class
    /// appears in, is a property of the room and the setup rather than of the
    /// student standing up today.
    var source: ScreenroomSourceKind { recorder.source }

    private let defaults: UserDefaults
    private static let cameraKey = "screenroomCameraUID"
    private static let sourceKey = "screenroomSource"
    private var bag: Set<AnyCancellable> = []

    /// One instance, because two windows show the same presentation: the
    /// evaluator's and, when it is asked for, the speaker's. Greenroom
    /// already shares one CoordinatorController across scenes for the same
    /// reason - SwiftUI scenes do not otherwise share view state.
    static let shared = ScreenroomController()

    init(defaults: UserDefaults = .standard) {
        _ = ScreenroomDefaults.migrated
        self.defaults = defaults
        self.recorder = ScreenroomRecorder(source: Self.storedSource(defaults))
        // The window's own state is derived from the recorder's, so it has to
        // redraw when the recorder changes. ObservableObject does not nest.
        recorder.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
    }

    // MARK: Opening and closing the window

    func windowAppeared() {
        cameras = LocalDeviceResolver.availableCameras()
        Task {
            await recorder.startPreview()
            await recorder.refreshScreenTargets()
        }
    }

    /// Points Screenroom at a different camera, window or display, and remembers
    /// it. Nothing happens mid-recording; the recorder refuses too.
    func use(source: ScreenroomSourceKind) {
        Task {
            await recorder.use(source: source)
            Self.store(source, in: defaults)
        }
    }

    func refreshSources() {
        cameras = LocalDeviceResolver.availableCameras()
        Task { await recorder.refreshScreenTargets() }
    }

    /// What the source picker should say it is pointed at right now.
    var sourceLabel: String {
        switch recorder.source {
        case .camera(let uid):
            if let named = cameras.first(where: { $0.id == uid })?.name { return named }
            return cameras.first?.name ?? "Camera"
        case .window(let id):
            return recorder.screenTargets.first { $0.kind == .window && $0.id == id }?.title
                ?? "A window"
        case .display(let id):
            return recorder.screenTargets.first { $0.kind == .display && $0.id == id }?.title
                ?? "Whole screen"
        }
    }

    // MARK: Remembering the source

    /// Stored as a short string rather than a Codable enum so a source that
    /// no longer exists - a camera unplugged, a window closed - degrades to
    /// "the first camera" instead of failing to decode and taking the whole
    /// preference with it.
    private static func storedSource(_ defaults: UserDefaults) -> ScreenroomSourceKind {
        let raw = defaults.string(forKey: sourceKey) ?? ""
        if raw.hasPrefix("display:"), let id = UInt32(raw.dropFirst("display:".count)) {
            return .display(id: id)
        }
        // A window id is not stable across launches - the window will have a
        // different one, or be gone - so a stored window falls back to the
        // camera rather than pointing at whatever now holds that number.
        return .camera(uid: defaults.string(forKey: cameraKey) ?? "")
    }

    private static func store(_ source: ScreenroomSourceKind, in defaults: UserDefaults) {
        switch source {
        case .camera(let uid):
            defaults.set(uid, forKey: cameraKey)
            defaults.set("camera", forKey: sourceKey)
        case .display(let id):
            defaults.set("display:\(id)", forKey: sourceKey)
        case .window:
            // Not remembered, for the reason in storedSource.
            defaults.set("window", forKey: sourceKey)
        }
    }

    func windowDisappeared() {
        // A presentation is not abandoned just because the window was closed -
        // stop the tape properly so the file is finalised and playable.
        if recorder.isRecording { finish() }
        recorder.stopPreview()
    }

    // MARK: The tape

    /// A name is not required.
    ///
    /// It was, and that was one field between a teacher and the Record
    /// button at the moment a student had already started speaking. An
    /// unnamed presentation gets "Presentation - <when>", which is a worse
    /// name than "Priya" and a far better outcome than a missed opening.
    /// Renaming afterwards is one right-click in Sessions.
    var canStart: Bool {
        recorder.isPreviewing && !recorder.isRecording
    }

    /// What this presentation's folder will be called, shown as you type so
    /// the default is something you can see rather than something you find
    /// out about afterwards.
    var folderPreview: String {
        GreenroomScene.sessionFolderName(className: presenter, started: Date(),
                                         fallback: Self.defaultName)
    }

    static let defaultName = "Presentation"

    /// Names the folder and starts recording. Both at once: a presentation
    /// that is being recorded is the only kind Screenroom has, so there is no
    /// separate "new presentation" step to forget.
    func start() {
        guard canStart else { return }
        let started = Date()
        let name = GreenroomScene.sessionFolderName(
            className: presenter, started: started, fallback: Self.defaultName)
        // Never onto an existing one: two presentations inside the same
        // minute share a stamp, and recording into the first one's folder
        // deletes the first one's video.
        let target = GreenroomScene.uniqueSessionFolder(
            named: name, in: GreenroomScene.recordingsDirectory)

        folder = target
        notes = []
        clearDraft()

        // The Sessions window reads this, so a presentation is findable there
        // under the presenter's name rather than as a bare folder date.
        var metadata = SessionMetadata()
        // Only a name somebody chose. An empty title leaves the folder name
        // to speak for itself, which is what Sessions falls back to.
        let typed = GreenroomScene.sanitizedClassName(presenter)
        metadata.title = typed.isEmpty ? nil : typed
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        metadata.save(in: target)

        recorder.startRecording(into: target)
        Analytics.feature("marks_start")
    }

    /// Stops the tape. The folder and the notes stay on screen: the evaluator
    /// has just watched a presentation and the last thing they want is the
    /// record of it disappearing the moment it ends.
    func finish() {
        guard recorder.isRecording else { return }
        commitDraft()
        recorder.stopRecording()
        Analytics.feature("marks_finish", source: "\(notes.count) notes")
    }

    // MARK: Notes

    /// True while a note can be taken - which is only while the tape is
    /// rolling, because a note with nothing to point into is not a note.
    var canTakeNotes: Bool { recorder.isRecording }

    private func draftChanged(from oldValue: String) {
        guard canTakeNotes else { return }
        let wasEmpty = oldValue.trimmingCharacters(in: .whitespaces).isEmpty
        let isEmpty = draft.trimmingCharacters(in: .whitespaces).isEmpty
        if wasEmpty && !isEmpty {
            // The first character of a new note. See the file note: this, not
            // Return, is the moment being marked.
            draftAtMs = recorder.positionMs
            draftStartedAt = Date()
        } else if isEmpty {
            draftAtMs = nil
            draftStartedAt = nil
        }
    }

    /// Commits the note being typed. Bound to Return in the composer.
    func commitDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let folder else { clearDraft(); return }

        let note = ScreenroomNote(atMs: draftAtMs ?? recorder.positionMs,
                                  text: text,
                                  markedAt: draftStartedAt ?? Date())
        notes.append(note)
        ScreenroomNotesFile.append(note, in: folder)
        clearDraft()
    }

    private func clearDraft() {
        draft = ""
        draftAtMs = nil
        draftStartedAt = nil
    }

    // MARK: Readouts

    /// `04:12` - how long the tape has been running. Mono in the UI.
    var elapsedLabel: String {
        let total = max(0, Int(recorder.elapsed))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Where a note typed right now would land, shown live beside the
    /// composer so the stamp is something the evaluator can see rather than
    /// something they have to trust.
    var draftOffsetLabel: String {
        let ms = draftAtMs ?? recorder.positionMs
        let total = max(0, ms / 1000)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
