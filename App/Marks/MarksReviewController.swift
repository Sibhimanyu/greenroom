//
//  MarksReviewController.swift
//  Greenroom
//
//  The second half of Marks: opening a presentation that has already
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
final class MarksReviewController: ObservableObject {

    @Published private(set) var presentations: [MarksPresentation] = []
    @Published private(set) var selected: MarksPresentation?

    @Published private(set) var notes: [MarksNote] = []
    @Published var scoring: MarksScoring = MarksScoring(rubric: MarksRubricStore.current())
    @Published private(set) var analysis: MarksAnalysis?
    @Published private(set) var cohortFindings: [MarksCohort.Finding] = []

    /// What more than one evaluator's notes say about each other. Empty
    /// whenever only one person wrote, which is the normal case.
    @Published private(set) var agreementFindings: [MarksCohort.Finding] = []

    /// The name this Mac signs its notes with. Blank until someone needs it,
    /// which is the moment a second evaluator's notes arrive.
    @Published var evaluatorName: String = MarksIdentity.current() {
        didSet { MarksIdentity.set(evaluatorName) }
    }

    /// Who wrote the notes in the presentation on screen.
    var authors: [String] {
        MarksNotesFile.authors(in: notes, soleAuthor: soleAuthorLabel)
    }

    /// What an unsigned note is called here. The evaluator's own name when
    /// they have given one, so a merged file does not end up with "You" and
    /// their name as two different people.
    private var soleAuthorLabel: String {
        evaluatorName.isEmpty ? MarksNote.soleAuthor : evaluatorName
    }

    @Published private(set) var isAnalysing = false
    @Published private(set) var isCutting = false
    @Published private(set) var cutProgress: (done: Int, total: Int)?

    /// The annotated video is the one thing in Marks that re-encodes, so it
    /// is the one thing that takes minutes. Its progress is reported rather
    /// than spun at - DESIGN.md asks that a wait say how much is left.
    @Published private(set) var isExportingVideo = false
    @Published private(set) var videoProgress: Double = 0

    // MARK: Material for a deeper pass

    @Published private(set) var metrics: MarksSpeechMetrics?
    @Published private(set) var frameCount = 0
    @Published private(set) var hasTranscript = false

    @Published private(set) var isPreparing = false
    @Published private(set) var prepareStep = ""
    @Published private(set) var prepareProgress: Double = 0

    @Published var agentSettings = MarksAgentSettings.load()
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

    /// How much run-up a clip gets before the note it was cut for.
    ///
    /// Fifteen seconds, and not symmetric, because of how the note was
    /// stamped: MarksController marks a note at its FIRST KEYSTROKE, so the
    /// thing being described already happened. The clip has to reach back
    /// past it. Five seconds afterwards is enough to see how it resolved.
    static let clipLeadInMs = 15_000
    static let clipTailMs = 5_000

    init() { refresh() }

    // MARK: Loading

    func refresh() {
        presentations = MarksLibrary.presentations()
        if let selected, let again = presentations.first(where: { $0.folder == selected.folder }) {
            self.selected = again
        } else if selected == nil {
            select(presentations.first)
        }
    }

    func select(_ presentation: MarksPresentation?) {
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
        agreementFindings = MarksAgreement.findings(in: notes, soleAuthor: soleAuthorLabel)
        // An existing rubric is this presentation's own snapshot. A new one
        // starts from whatever the teacher is marking the rest of the cohort
        // on - see MarksRubric for why the snapshot then stops following it.
        scoring = presentation.scoring() ?? MarksScoring(rubric: MarksRubricStore.current())
        analysis = presentation.analysis()
        metrics = MarksSpeechMetrics.load(in: presentation.folder)
        frameCount = MarksFrames.existing(in: presentation.folder).count
        hasTranscript = FileManager.default.fileExists(
            atPath: presentation.folder.appendingPathComponent(MarksTranscriber.transcriptFileName).path)
        agentReport = MarksAgent.existingReport(in: presentation.folder)
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
    func seek(to note: MarksNote) {
        guard player.currentItem != nil else { return }
        let target = max(0, Double(note.atMs - 4_000) / 1000)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    // MARK: Marking

    func setScore(_ value: Int?, for criterion: MarksCriterion) {
        scoring.set(value, for: criterion)
        persistScoring()
    }

    func setComment(_ text: String, for criterion: MarksCriterion) {
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
        MarksRubricStore.save(scoring.rubric)
        recomputeCohort()
        refreshSelectedRow()
    }

    private func refreshSelectedRow() {
        guard let folder = selected?.folder else { return }
        presentations = MarksLibrary.presentations()
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
        var entries = MarksLibrary.cohortEntries()
        // The version on disk may be a keystroke behind what is on screen.
        entries.removeAll { $0.folder == selected.folder }
        let subject = MarksCohort.Entry(folder: selected.folder,
                                        presenter: selected.presenter,
                                        scoring: scoring,
                                        markedAt: scoring.markedAt ?? selected.presentedAt)
        cohortFindings = MarksCohort.findings(for: subject, among: entries + [subject])
    }

    // MARK: The pass

    func analyse() async {
        guard let selected, !isAnalysing else { return }
        isAnalysing = true
        status = nil
        defer { isAnalysing = false }

        let produced = await MarksAnalyst.analyse(
            notes: notes,
            scoring: scoring.markedCount > 0 ? scoring : nil,
            presenter: selected.presenter,
            // Both kinds of consistency travel together into the analysis:
            // how this student was marked against the group, and how the
            // evaluators agreed with each other. Frozen at the moment the
            // report was produced - see MarksAnalysis.
            consistency: (agreementFindings + cohortFindings).map { "\($0.headline). \($0.detail)" })

        produced.save(in: selected.folder)
        analysis = produced
        status = "Read \(notes.count) \(notes.count == 1 ? "note" : "notes") \u{2014} \(produced.engine)."
    }

    // MARK: Output

    func exportReport(for audience: MarksReport.Audience) {
        guard let selected else { return }
        let markdown = MarksReport.markdown(presenter: selected.presenter,
                                            presentedAt: selected.presentedAt,
                                            notes: notes,
                                            scoring: scoring.markedCount > 0 ? scoring : nil,
                                            analysis: analysis,
                                            for: audience)
        guard let written = MarksReport.write(markdown, in: selected.folder) else {
            status = "The report could not be written into the folder."
            return
        }
        status = "Wrote \(written.lastPathComponent)."
        refreshSelectedRow()
    }

    /// Cuts the recording to each note.
    ///
    /// Passthrough, through the exporter the class clips already use, so
    /// twelve clips cost seconds rather than minutes and lose no quality.
    func cutClips() async {
        guard let selected, let recording = selected.recording, !notes.isEmpty, !isCutting else { return }
        isCutting = true
        cutProgress = (0, notes.count)
        defer { isCutting = false; cutProgress = nil }

        let clips = notes.map { note in
            SessionClip(startMs: max(0, note.atMs - Self.clipLeadInMs),
                        endMs: note.atMs + Self.clipTailMs,
                        markedAt: note.markedAt)
        }
        let result = await SessionClipExporter.exportAll(clips, from: recording) { [weak self] done, total in
            self?.cutProgress = (done, total)
        }
        if result.failed.isEmpty {
            status = "Cut \(result.exported.count) \(result.exported.count == 1 ? "clip" : "clips") into the folder."
        } else {
            status = "Cut \(result.exported.count); \(result.failed.count) could not be cut."
        }
    }
}

extension MarksReviewController {

    /// Folds another evaluator's notes into this presentation.
    ///
    /// A file, handed over however people already hand files over. See
    /// MarksAgreement for why there is no transport: notes are files, so a
    /// second evaluator is a second file, and a server would buy an email.
    ///
    /// Merging is a union by id, so the same attachment imported twice adds
    /// nothing the second time.
    func importNotes(from file: URL) {
        guard let selected else { return }
        let incoming = MarksNotesFile.read(from: file)
        guard !incoming.isEmpty else {
            status = "\(file.lastPathComponent) had no notes in it."
            return
        }
        let unsigned = incoming.filter { $0.author == nil }.count
        let added = MarksNotesFile.merge(incoming, into: selected.folder)

        notes = MarksNotesFile.load(in: selected.folder)
        agreementFindings = MarksAgreement.findings(in: notes, soleAuthor: soleAuthorLabel)
        refreshSelectedRow()

        if added == 0 {
            status = "Already had all \(incoming.count) of those notes."
        } else if unsigned > 0 {
            // Worth saying rather than silently folding them in: unsigned
            // notes merge under this Mac's own name, which is wrong if they
            // came from someone else, and the fix is for THEM to set a name
            // before exporting.
            status = "Added \(added) \(added == 1 ? "note" : "notes"). \(unsigned) had no author and will read as yours."
        } else {
            status = "Added \(added) \(added == 1 ? "note" : "notes") from \(MarksNotesFile.authors(in: incoming).joined(separator: ", "))."
        }
    }
}

// MARK: - Handing the presentation over as video

extension MarksReviewController {

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

        let output = selected.folder.appendingPathComponent(MarksVideoExport.annotatedFileName)
        do {
            let written = try await MarksVideoExport.exportAnnotated(
                recording: recording,
                notes: notes,
                presenter: selected.presenter,
                presentedAt: selected.presentedAt,
                // Names only when there is more than one person to tell
                // apart. A name on every card when one person wrote them all
                // is the same word repeated down the whole video.
                showAuthors: authors.count > 1,
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
        guard let written = MarksVideoExport.writeSubtitles(
            for: notes, duration: duration,
            showAuthors: authors.count > 1, in: selected.folder) else {
            status = "The subtitles could not be written."
            return
        }
        status = "Wrote \(written.lastPathComponent). Open the recording in QuickTime or VLC and turn subtitles on."
        refreshSelectedRow()
    }
}

// MARK: - Material, and the agent that reads it

extension MarksReviewController {

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

        prepareStep = "Transcribing on this Mac"
        do {
            let words = try await MarksTranscriber.transcribe(
                recording: recording, into: selected.folder,
                onProgress: { [weak self] fraction in self?.prepareProgress = fraction })
            hasTranscript = !words.isEmpty
            metrics = MarksSpeechMetrics.load(in: selected.folder)
        } catch {
            // Not fatal. Frames are still worth having, and a folder with
            // pictures and no transcript is more use than neither.
            status = error.localizedDescription
        }

        prepareStep = "Taking stills"
        prepareProgress = 0
        do {
            let frames = try await MarksFrames.extract(
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

        let text = MarksAgent.brief(presenter: selected.presenter,
                                    notes: notes,
                                    metrics: metrics,
                                    scoring: scoring.markedCount > 0 ? scoring : nil,
                                    frameCount: frameCount,
                                    hasTranscript: hasTranscript)
        MarksAgent.writeBrief(text, in: selected.folder)

        do {
            let output = try await MarksAgent.run(
                settings: agentSettings, brief: text, in: selected.folder,
                onOutput: { [weak self] piece in self?.agentLog += piece })
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                status = "The agent finished but printed nothing."
                return
            }
            MarksAgent.writeReport(trimmed, in: selected.folder)
            agentReport = trimmed
            status = "Wrote \(MarksAgent.reportFileName)."
            refreshSelectedRow()
        } catch {
            status = error.localizedDescription
        }
    }

    func saveAgentSettings() { agentSettings.save() }
}
