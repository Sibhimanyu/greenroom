//
//  MarksController.swift
//  Greenroom
//
//  Marks: a presentation, the camera watching it, and the notes taken while
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
final class MarksController: ObservableObject {

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
    @Published private(set) var notes: [MarksNote] = []

    // MARK: The note being typed

    @Published var draft: String = "" {
        didSet { draftChanged(from: oldValue) }
    }

    /// Where the tape was when this draft's first character was typed.
    private var draftAtMs: Int?
    private var draftStartedAt: Date?

    // MARK: Camera

    let recorder = MarksRecorder()

    /// Remembered between presentations: which camera is pointed at the front
    /// of the room is a property of the room, not of the student.
    @Published var cameraUID: String {
        didSet {
            defaults.set(cameraUID, forKey: Self.cameraKey)
            recorder.useCamera(uid: cameraUID)
        }
    }

    @Published private(set) var cameras: [LocalDeviceResolver.Camera] = []

    private let defaults: UserDefaults
    private static let cameraKey = "marksCameraUID"
    private var bag: Set<AnyCancellable> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.cameraUID = defaults.string(forKey: Self.cameraKey) ?? ""
        // The window's own state is derived from the recorder's, so it has to
        // redraw when the recorder changes. ObservableObject does not nest.
        recorder.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
    }

    // MARK: Opening and closing the window

    func windowAppeared() {
        cameras = LocalDeviceResolver.availableCameras()
        if cameraUID.isEmpty { cameraUID = cameras.first?.id ?? "" }
        recorder.startPreview(cameraUID: cameraUID.isEmpty ? nil : cameraUID)
    }

    func windowDisappeared() {
        // A presentation is not abandoned just because the window was closed -
        // stop the tape properly so the file is finalised and playable.
        if recorder.isRecording { finish() }
        recorder.stopPreview()
    }

    // MARK: The tape

    var canStart: Bool {
        recorder.isPreviewing && !recorder.isRecording
            && !presenter.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Names the folder and starts recording. Both at once: a presentation
    /// that is being recorded is the only kind Marks has, so there is no
    /// separate "new presentation" step to forget.
    func start() {
        guard canStart else { return }
        let started = Date()
        let name = GreenroomScene.sessionFolderName(
            className: presenter, started: started)
        let target = GreenroomScene.recordingsDirectory
            .appendingPathComponent(name, isDirectory: true)

        folder = target
        notes = []
        clearDraft()

        // The Sessions window reads this, so a presentation is findable there
        // under the presenter's name rather than as a bare folder date.
        var metadata = SessionMetadata()
        metadata.title = GreenroomScene.sanitizedClassName(presenter)
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

        let note = MarksNote(atMs: draftAtMs ?? recorder.positionMs,
                             text: text,
                             markedAt: draftStartedAt ?? Date())
        notes.append(note)
        MarksNotesFile.append(note, in: folder)
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
