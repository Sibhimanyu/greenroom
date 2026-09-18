//
//  ScreenroomReviewController.swift
//  Greenroom
//
//  The second half of Screenroom: opening a presentation that has already
//  happened, marking it, running the pass over the notes, and producing the
//  report.
//
//  Everything it holds comes off disk and goes straight back to disk. There is
//  no unsaved state to lose and no Save button to forget: a score is written
//  the moment it is given, because the alternative is a teacher who marked
//  twelve students and closed the window.
//
import AVFoundation
import Combine
import Foundation

@MainActor
final class ScreenroomReviewController: ObservableObject {

    @Published private(set) var presentations: [ScreenroomPresentation] = []
    @Published private(set) var selected: ScreenroomPresentation?

    @Published private(set) var notes: [ScreenroomNote] = []
    @Published var scoring: ScreenroomScoring = ScreenroomScoring(rubric: ScreenroomRubricStore.current())
    @Published private(set) var analysis: ScreenroomAnalysis?
    @Published private(set) var cohortFindings: [ScreenroomCohort.Finding] = []

    @Published private(set) var isAnalysing = false

    /// The annotated video is the one thing in Screenroom that re-encodes, so it
    /// is the one thing that takes minutes. Its progress is reported rather
    /// than spun at - DESIGN.md asks that a wait say how much is left.
    @Published private(set) var isExportingVideo = false
    @Published private(set) var videoProgress: Double = 0

    // MARK: Material for a deeper pass

    @Published private(set) var metrics: ScreenroomSpeechMetrics?
    @Published private(set) var frameCount = 0
    @Published private(set) var hasTranscript = false

    @Published private(set) var isPreparing = false
    @Published private(set) var prepareStep = ""
    @Published private(set) var prepareProgress: Double = 0

    @Published var transcriberSettings = ScreenroomTranscriberSettings.load()
    @Published private(set) var whisperReady = ScreenroomWhisper.resolvedBinary != nil
                                               && ScreenroomWhisper.findModel() != nil
    @Published var agentSettings = ScreenroomAgentSettings.load()
    @Published private(set) var isRunningAgent = false
    /// What the agent is saying as it says it. Agents take minutes and go
    /// quiet while they think; a window that showed nothing until the end
    /// would be indistinguishable from one that had hung.
    @Published private(set) var agentLog = ""
    @Published private(set) var agentReport: String?

    /// What just happened, in a sentence, under the actions that caused it.
    /// DESIGN.md asks that a result land on the surface the user was already
    /// watching rather than in a log somewhere else.
    @Published private(set) var status: String?

    let player = AVPlayer()

    init() {
        _ = ScreenroomDefaults.migrated
        refresh()
    }

    // MARK: Loading

    func refresh() {
        presentations = ScreenroomLibrary.presentations()
        if let selected, let again = presentations.first(where: { $0.folder == selected.folder }) {
            self.selected = again
        } else if selected == nil {
            select(presentations.first)
        }
    }

    func select(_ presentation: ScreenroomPresentation?) {
        selected = presentation
        status = nil
        guard let presentation else {
            notes = []
            analysis = nil
            cohortFindings = []
            player.replaceCurrentItem(with: nil)
            return
        }

        notes = presentation.notes()
        // An existing rubric is this presentation's own snapshot. A new one
        // starts from whatever the teacher is marking the rest of the cohort
        // on - see ScreenroomRubric for why the snapshot then stops following it.
        scoring = presentation.scoring() ?? ScreenroomScoring(rubric: ScreenroomRubricStore.current())
        analysis = presentation.analysis()
        metrics = ScreenroomSpeechMetrics.load(in: presentation.folder)
        frameCount = ScreenroomFrames.existing(in: presentation.folder).count
        hasTranscript = FileManager.default.fileExists(
            atPath: presentation.folder.appendingPathComponent(ScreenroomTranscriber.transcriptFileName).path)
        agentReport = ScreenroomAgent.existingReport(in: presentation.folder)
        agentLog = ""

        if let recording = presentation.recording {
            player.replaceCurrentItem(with: AVPlayerItem(url: recording))
        } else {
            player.replaceCurrentItem(with: nil)
        }
        recomputeCohort()
    }

    // MARK: The player

    /// Jumps the recording to a note. The whole reason the offsets are exact.
    ///
    /// Lands slightly BEFORE the note for the same reason clips do: the note
    /// was stamped when the evaluator started typing, so the moment it
    /// describes is just behind it.
    func seek(to note: ScreenroomNote) {
        guard player.currentItem != nil else { return }
        let target = max(0, Double(note.atMs - 4_000) / 1000)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    // MARK: Marking

    func setScore(_ value: Int?, for criterion: ScreenroomCriterion) {
        scoring.set(value, for: criterion)
        persistScoring()
    }

    func setComment(_ text: String, for criterion: ScreenroomCriterion) {
        scoring.setComment(text, for: criterion)
        persistScoring()
    }

    /// Written on every keystroke's worth of change. The file is a couple of
    /// hundred bytes and the alternative is losing an afternoon's marking to a
    /// closed window.
    private func persistScoring() {
        guard let folder = selected?.folder else { return }
        scoring.save(in: folder)
        // The rubric the teacher is actually using, for the next student.
        ScreenroomRubricStore.save(scoring.rubric)
        recomputeCohort()
        refreshSelectedRow()
    }

    private func refreshSelectedRow() {
        guard let folder = selected?.folder else { return }
        presentations = ScreenroomLibrary.presentations()
        selected = presentations.first { $0.folder == folder } ?? selected
    }

    // MARK: Consistency

    /// Recomputed locally rather than stored, because it is a statement about
    /// the cohort as it stands right now and the cohort grows all term. What
    /// gets frozen is the copy written into analysis.json at the moment a
    /// report was produced.
    func recomputeCohort() {
        guard let selected, scoring.markedCount > 0 else {
            cohortFindings = []
            return
        }
        var entries = ScreenroomLibrary.cohortEntries()
        // The version on disk may be a keystroke behind what is on screen.
        entries.removeAll { $0.folder == selected.folder }
        let subject = ScreenroomCohort.Entry(folder: selected.folder,
                                        presenter: selected.presenter,
                                        scoring: scoring,
                                        markedAt: scoring.markedAt ?? selected.presentedAt)
        cohortFindings = ScreenroomCohort.findings(for: subject, among: entries + [subject])
    }

    // MARK: The pass

    func analyse() async {
        guard let selected, !isAnalysing else { return }
        isAnalysing = true
        status = nil
        defer { isAnalysing = false }

        let produced = await ScreenroomAnalyst.analyse(
            notes: notes,
            scoring: scoring.markedCount > 0 ? scoring : nil,
            presenter: selected.presenter,
            // Frozen at the moment the report was produced, not recomputed
            // on read - see ScreenroomAnalysis.
            consistency: cohortFindings.map { "\($0.headline). \($0.detail)" })

        produced.save(in: selected.folder)
        analysis = produced
        status = "Read \(notes.count) \(notes.count == 1 ? "note" : "notes") \u{2014} \(produced.engine)."
    }

    // MARK: Output

    func exportReport(for audience: ScreenroomReport.Audience) {
        guard let selected else { return }
        let markdown = ScreenroomReport.markdown(presenter: selected.presenter,
                                            presentedAt: selected.presentedAt,
                                            notes: notes,
                                            scoring: scoring.markedCount > 0 ? scoring : nil,
                                            analysis: analysis,
                                            for: audience)
        guard let written = ScreenroomReport.write(markdown, in: selected.folder) else {
            status = "The report could not be written into the folder."
            return
        }
        status = "Wrote \(written.lastPathComponent)."
        refreshSelectedRow()
    }

}

// MARK: - Handing the presentation over as video

extension ScreenroomReviewController {

    /// Writes the recording again with the notes drawn into the picture.
    ///
    /// The point of this over report.md: reading "at 6:40 you lost the
    /// thread" and WATCHING yourself lose the thread while the sentence
    /// appears are not the same feedback, and the second needs no
    /// cross-referencing between a document and a scrubber.
    func exportAnnotatedVideo() async {
        guard let selected, let recording = selected.recording,
              !notes.isEmpty, !isExportingVideo else { return }
        isExportingVideo = true
        videoProgress = 0
        status = "Rendering the notes into the video\u{2026}"
        defer { isExportingVideo = false; videoProgress = 0 }

        let output = selected.folder.appendingPathComponent(ScreenroomVideoExport.annotatedFileName)
        do {
            let written = try await ScreenroomVideoExport.exportAnnotated(
                recording: recording,
                notes: notes,
                presenter: selected.presenter,
                presentedAt: selected.presentedAt,
                to: output,
                onProgress: { [weak self] progress in self?.videoProgress = progress })
            status = "Wrote \(written.lastPathComponent)."
            refreshSelectedRow()
        } catch {
            status = error.localizedDescription
        }
    }

    /// Writes the notes as subtitles beside the recording.
    ///
    /// Seconds rather than minutes, because nothing is re-encoded, and every
    /// player can turn them off. YouTube takes the file directly. The cost is
    /// that it is a second file to keep next to the first.
    func exportSubtitles() async {
        guard let selected, let recording = selected.recording, !notes.isEmpty else { return }
        let duration = (try? await AVURLAsset(url: recording).load(.duration))?.seconds ?? 0
        guard let written = ScreenroomVideoExport.writeSubtitles(
            for: notes, duration: duration,
            in: selected.folder) else {
            status = "The subtitles could not be written."
            return
        }
        status = "Wrote \(written.lastPathComponent). Open the recording in QuickTime or VLC and turn subtitles on."
        refreshSelectedRow()
    }
}

// MARK: - Material, and the agent that reads it

extension ScreenroomReviewController {

    /// Transcribes the recording and pulls stills out of it.
    ///
    /// Both are inputs to a deeper pass and neither is cheap, so they are one
    /// button rather than two: a teacher pressing "prepare" is not making a
    /// choice between them, and the failure of one should not silently leave
    /// the other undone.
    func prepareMaterial() async {
        guard let selected, let recording = selected.recording, !isPreparing else { return }
        isPreparing = true
        prepareProgress = 0
        status = nil
        defer { isPreparing = false; prepareStep = ""; prepareProgress = 0 }

        prepareStep = transcriberSettings.engine == .whisper
            ? "Transcribing with whisper"
            : "Transcribing with Apple"
        do {
            let words = try await ScreenroomTranscriber.transcribe(
                recording: recording, into: selected.folder,
                settings: transcriberSettings,
                onProgress: { [weak self] fraction in self?.prepareProgress = fraction },
                onOutput: { [weak self] piece in
                    // whisper prints its progress on stderr; showing the tail
                    // of it is the difference between a five-minute wait and
                    // a five-minute wait that looks like a hang.
                    self?.prepareStep = piece.split(separator: "\n").last.map(String.init)
                        ?? "Transcribing"
                })
            hasTranscript = !words.isEmpty
            metrics = ScreenroomSpeechMetrics.load(in: selected.folder)
        } catch {
            // Not fatal. Frames are still worth having, and a folder with
            // pictures and no transcript is more use than neither.
            status = error.localizedDescription
        }

        prepareStep = "Taking stills"
        prepareProgress = 0
        do {
            let frames = try await ScreenroomFrames.extract(
                from: recording, into: selected.folder,
                onProgress: { [weak self] done, total in
                    self?.prepareProgress = total > 0 ? Double(done) / Double(total) : 0
                })
            frameCount = frames.count
        } catch {
            status = error.localizedDescription
        }

        if status == nil {
            status = "Ready: \(hasTranscript ? "transcript" : "no transcript"), \(frameCount) stills."
        }
        refreshSelectedRow()
    }

    /// Writes the brief and hands it to the configured agent.
    func runAgent() async {
        guard let selected, !isRunningAgent else { return }
        isRunningAgent = true
        agentLog = ""
        status = nil
        defer { isRunningAgent = false }

        let text = ScreenroomAgent.brief(presenter: selected.presenter,
                                    notes: notes,
                                    metrics: metrics,
                                    scoring: scoring.markedCount > 0 ? scoring : nil,
                                    frameCount: frameCount,
                                    hasTranscript: hasTranscript)
        ScreenroomAgent.writeBrief(text, in: selected.folder)

        do {
            let output = try await ScreenroomAgent.run(
                settings: agentSettings, brief: text, in: selected.folder,
                onOutput: { [weak self] piece in self?.agentLog += piece })
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                status = "The agent finished but printed nothing."
                return
            }
            ScreenroomAgent.writeReport(trimmed, in: selected.folder)
            agentReport = trimmed
            status = "Wrote \(ScreenroomAgent.reportFileName)."
            refreshSelectedRow()
        } catch {
            status = error.localizedDescription
        }
    }

    func saveAgentSettings() { agentSettings.save() }

    func saveTranscriberSettings() {
        transcriberSettings.save()
        whisperReady = ScreenroomWhisper.resolvedBinary != nil && ScreenroomWhisper.findModel() != nil
    }

    /// The one line that fetches a model, for the teacher to paste.
    var whisperDownloadCommand: String { ScreenroomWhisper.downloadCommand }
}
