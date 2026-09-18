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

    /// Bumped each time a pass finishes, so the window can open the report
    /// on a NEW analysis without also opening it every time a presentation
    /// that already had one is selected.
    @Published private(set) var analysisRuns = 0

    /// The annotated video is the one thing in Screenroom that re-encodes, so it
    /// is the one thing that takes minutes. Its progress is reported rather
    /// than spun at - DESIGN.md asks that a wait say how much is left.
    @Published private(set) var isExportingVideo = false
    @Published private(set) var videoProgress: Double = 0

    // MARK: Material for a deeper pass

    @Published private(set) var metrics: ScreenroomSpeechMetrics?
    @Published private(set) var frameCount = 0
    @Published private(set) var hasTranscript = false

    /// One run, one step name, one bar. DESIGN.md: name the step, never just
    /// spin - a pass stuck on transcription should look different from one
    /// about to finish.
    @Published private(set) var step = ""
    @Published private(set) var progress: Double = 0

    /// What the outside tools are saying as they say it. whisper prints its
    /// progress and agents go quiet for minutes at a time; a window that
    /// showed nothing until the end would be indistinguishable from one that
    /// had hung.
    @Published private(set) var log = ""

    /// What just happened, in a sentence, under the actions that caused it.
    /// DESIGN.md asks that a result land on the surface the user was already
    /// watching rather than in a log somewhere else.
    @Published fileprivate(set) var status: String?

    let player = AVPlayer()

    /// One instance. The review window and the report window are two views
    /// of one presentation, and SwiftUI scenes do not otherwise share state.
    static let shared = ScreenroomReviewController()

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
        log = ""

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

    /// THE pipeline. One button, one order, no decisions.
    ///
    /// The six controls this replaced - whisper or Apple, prepare or not,
    /// agent or not, which agent, its command, and a separate "read the
    /// notes" - were six ways of asking the same question, which is "make me
    /// a report". Setup is a setting; running is a button.
    ///
    /// Every stage is best-effort and the next one still runs. A Mac with no
    /// whisper still gets stills, a presentation with no recording still gets
    /// a report from the notes alone, and a failed agent still leaves the
    /// on-device pass to write something. The report says which engine wrote
    /// each part, so a degraded run is visible rather than silent.
    func analyse() async {
        guard let selected, !isAnalysing else { return }
        isAnalysing = true
        log = ""
        status = nil
        defer { isAnalysing = false; step = ""; progress = 0 }

        if let recording = selected.recording {
            await transcribe(recording, into: selected.folder)
            await takeStills(recording, into: selected.folder)
        }

        step = "Comparing against the group"
        progress = 0
        recomputeCohort()

        let consistency = cohortFindings.map { "\($0.headline). \($0.detail)" }
        let produced = await write(consistency: consistency, for: selected)

        produced.save(in: selected.folder)
        analysis = produced
        analysisRuns += 1
        status = "\(produced.engine)."
        refreshSelectedRow()
    }

    // MARK: The stages

    private func transcribe(_ recording: URL, into folder: URL) async {
        step = "Transcribing"
        progress = 0
        do {
            _ = try await ScreenroomTranscriber.transcribe(
                recording: recording, into: folder,
                settings: ScreenroomTranscriberSettings.resolved(),
                onProgress: { [weak self] fraction in self?.progress = fraction },
                onOutput: { [weak self] piece in self?.log += piece })
            hasTranscript = true
            metrics = ScreenroomSpeechMetrics.load(in: folder)
        } catch {
            // Not fatal. The notes are still the most valuable thing here,
            // and a report built from them alone is the thing this started as.
            status = error.localizedDescription
        }
    }

    private func takeStills(_ recording: URL, into folder: URL) async {
        step = "Taking stills"
        progress = 0
        do {
            let frames = try await ScreenroomFrames.extract(
                from: recording, into: folder,
                onProgress: { [weak self] done, total in
                    self?.progress = total > 0 ? Double(done) / Double(total) : 0
                })
            frameCount = frames.count
        } catch {
            status = error.localizedDescription
        }
    }

    /// The engine ladder, walked automatically: the agent when one is set up,
    /// Apple's on-device model when it is not, and arithmetic when neither is
    /// available. Never a question put to the teacher mid-presentation.
    private func write(consistency: [String], for presentation: ScreenroomPresentation) async -> ScreenroomAnalysis {
        let settings = ScreenroomAgentSettings.load()
        if settings.enabled, !settings.command.trimmingCharacters(in: .whitespaces).isEmpty {
            step = "Your agent is reading it"
            progress = 0
            let brief = ScreenroomAgent.brief(presenter: presentation.presenter,
                                              notes: notes,
                                              metrics: metrics,
                                              scoring: scoring.markedCount > 0 ? scoring : nil,
                                              frameCount: frameCount,
                                              hasTranscript: hasTranscript)
            ScreenroomAgent.writeBrief(brief, in: presentation.folder)
            do {
                let output = try await ScreenroomAgent.run(
                    settings: settings, brief: brief, in: presentation.folder,
                    onOutput: { [weak self] piece in self?.log += piece })
                ScreenroomAgent.writeReport(output, in: presentation.folder)
                return ScreenroomAgent.analysis(from: output,
                                                engine: settings.kind.label,
                                                consistency: consistency)
            } catch {
                // Falls through to the on-device pass rather than failing the
                // run. A missing CLI should cost the extra detail, not the
                // report.
                status = error.localizedDescription
            }
        }

        step = "Reading the notes"
        progress = 0
        return await ScreenroomAnalyst.analyse(notes: notes,
                                               scoring: scoring.markedCount > 0 ? scoring : nil,
                                               presenter: presentation.presenter,
                                               consistency: consistency)
    }
}

// MARK: - Handing the presentation over as video

extension ScreenroomReviewController {

    /// Writes the recording again with the notes drawn into the picture.
    ///
    /// Reading "at 6:40 you lost the thread" and WATCHING yourself lose the
    /// thread while the sentence appears are not the same feedback, and the
    /// second needs no cross-referencing between a document and a scrubber.
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

    /// Writes the notes as subtitles beside the recording. Seconds rather than
    /// minutes, because nothing is re-encoded.
    func exportSubtitles() async {
        guard let selected, let recording = selected.recording, !notes.isEmpty else { return }
        let duration = (try? await AVURLAsset(url: recording).load(.duration))?.seconds ?? 0
        guard let written = ScreenroomVideoExport.writeSubtitles(
            for: notes, duration: duration, in: selected.folder) else {
            status = "The subtitles could not be written."
            return
        }
        status = "Wrote \(written.lastPathComponent)."
        refreshSelectedRow()
    }
}

extension ScreenroomReviewController {

    /// The report as text, for whichever audience. Built on demand rather
    /// than held, so it can never be stale against the notes on screen.
    func reportMarkdown(for audience: ScreenroomReport.Audience) -> String? {
        guard let selected else { return nil }
        return ScreenroomReport.markdown(presenter: selected.presenter,
                                         presentedAt: selected.presentedAt,
                                         notes: notes,
                                         scoring: scoring.markedCount > 0 ? scoring : nil,
                                         analysis: analysis,
                                         for: audience)
    }

    /// Says what just happened, on whichever surface is watching.
    func report(_ message: String) { status = message }
}
