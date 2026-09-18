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
