//
//  ScreenroomAnalysisPane.swift
//  Greenroom
//
//  Screenroom's half of the Sessions window.
//
//  There used to be two windows listing the same folders: Sessions, which had
//  the player, the clips, the YouTube links, rename and delete; and Past
//  Presentations, which had the notes, the rubric and the report. Two lists of
//  ~/Documents/Greenroom is one too many, and the split was an accident of the
//  order things were built rather than a distinction a teacher would draw.
//
//  So the analysis moved into Sessions, and the second window went. This is
//  the piece that moved. It brings its own state through the shared
//  controller and borrows the window's player, so a note seeks the picture
//  that is already on screen rather than a second one nobody can see.
//
//  It shows ONE pane at a time, chosen by the window's own tab bar. It used
//  to own a second segmented control of its own, which put two pickers one
//  under the other with the word "Analysis" in both - that reads as a bug
//  rather than as a hierarchy, and the fix was to flatten rather than to
//  restyle.
//
//  The analysis does not care whether a folder holds a class or a
//  presentation. A transcript, filler counts, pace and an agent pass need a
//  recording; notes and a rubric are what a presentation has EXTRA. A class
//  recorded through Start is analysable on exactly the same terms, which is
//  the whole reason this merge was worth doing.
//
import SwiftUI

struct ScreenroomAnalysisPane: View {

    enum Pane { case analysis, notes }

    /// The folder the window has selected. Nil while nothing is.
    let folder: URL?
    let showing: Pane
    /// Seeks the window's own player, in milliseconds.
    let seek: (Int) -> Void
    /// Where that player currently is, in milliseconds.
    let position: () -> Int

    @ObservedObject private var review = ScreenroomReviewController.shared
    @Environment(\.openWindow) private var openWindow
    @State private var draft = ""
    /// Where the player was when this note's FIRST character was typed.
    ///
    /// Read at Return, it drifted: the recording keeps playing while the
    /// sentence is written, so a note about something at 3:12 landed at 3:31.
    /// Frozen at the first keystroke it is right either way - paused, it is
    /// the same number; playing, it is the moment you reacted. Same rule the
    /// live window follows, now for the same reason.
    @State private var draftAtMs: Int?
    @FocusState private var composerFocused: Bool

    var body: some View {
        Group {
            switch showing {
            case .analysis: analysis
            case .notes: notes
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { adopt() }
        .onChange(of: folder) { _, _ in adopt() }
    }

    /// Hands the controller this folder and this window's player. Both on
    /// appear and on change, because the pane can be built with a selection
    /// already made.
    private func adopt() {
        review.externalSeek = seek
        review.currentPosition = position
        review.select(folder: folder)
    }

    // MARK: Analysis

    @ViewBuilder
    private var analysis: some View {
        if review.isAnalysing {
            running
        } else if let analysis = review.analysis {
            analysed(analysis)
        } else {
            notYet
        }
    }

    /// The empty state fills the pane instead of hugging the top of it.
    ///
    /// The first version put a sentence and a greyed-out paragraph at the top
    /// of a thousand points of nothing, which reads as a page that failed to
    /// load. A centred state with its action in it reads as a page waiting
    /// for you.
    private var notYet: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.and.person.filled")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text("Not analysed yet")
                    .font(.title3.weight(.medium))
                Text("Transcribes the recording on this Mac, counts pace and filler words, compares the marking against the group, and writes the report. It works on a class as well as a presentation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }
            Button {
                Task { await review.analyse() }
            } label: {
                Label("Analyse", systemImage: "sparkles").frame(minWidth: 96)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(folder == nil)
            if let status = review.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    /// What a wait should say.
    ///
    /// The first version was a determinate bar and a step name. On the agent
    /// step the bar sat at zero for two minutes, because an agent reports
    /// nothing until it answers - and a bar that does not move is not a
    /// progress bar, it is a picture of a hang. Reported as exactly that.
    ///
    /// So: a bar only where something can fill it, a spinner where nothing
    /// can, and three things that are always true either way - which step of
    /// how many, how long it has been going, and the last complete line the
    /// tool itself printed. Plus a way out.
    private var running: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                if review.isDeterminate {
                    ProgressView(value: review.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 280)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                }

                Text(review.step.isEmpty ? "Working\u{2026}" : review.step)
                    .font(.title3.weight(.medium))

                HStack(spacing: 6) {
                    if review.stepCount > 0 {
                        Text("Step \(review.stepIndex) of \(review.stepCount)")
                        Text("\u{00B7}")
                    }
                    Text(Self.clock(review.elapsed))
                        .monospacedDigit()
                    if review.isDeterminate, review.progress > 0 {
                        Text("\u{00B7}")
                        Text("\(Int(review.progress * 100))%").monospacedDigit()
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
            }

            if !review.log.isEmpty {
                // The tool's own words, and only whole lines of them. This
                // used to be the last 280 CHARACTERS of stdout, which is the
                // answer being written - so it showed half-sentences of the
                // report itself and read as corruption.
                Text(review.log)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .truncationMode(.head)
                    .frame(maxWidth: 460)
                    .textSelection(.enabled)
            }

            Button("Stop", role: .destructive) { review.cancel() }
                .controlSize(.small)
                .disabled(!review.isCancellable)
                .help("Stops the run and closes whatever it started.")

            if review.elapsed > 180 {
                // Said only once it is genuinely long, so it reads as help
                // rather than as an excuse offered up front.
                Text("Longer than three minutes usually means a big recording or a busy agent. Stopping is safe \u{2014} nothing is written until it finishes.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s < 60 ? "\(s)s" : String(format: "%dm %02ds", s / 60, s % 60)
    }

    /// The analysed state, deliberately small.
    ///
    /// It used to print the whole summary at 15pt into a pane a few hundred
    /// points tall, which is a five-line paragraph becoming a fourteen-line
    /// wall you scroll. Reported as exactly that. A paragraph is the report's
    /// job; this pane's job is to say whether the thing has been analysed,
    /// give the few numbers worth a glance, and get out of the way.
    ///
    /// So: the numbers, the shortest useful list, and the door to the rest.
    private func analysed(_ analysis: ScreenroomAnalysis) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headline

                if !analysis.workOn.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        eyebrow("TO CHANGE")
                        // Two lines each, three at most. The full sentences,
                        // the reasoning and the marks are in the report.
                        ForEach(analysis.workOn.prefix(3), id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Circle().fill(Brand.fill).frame(width: 4, height: 4)
                                    .offset(y: -3)
                                Text(item).font(.callout).lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        openWindow(id: "screenroom-report")
                    } label: {
                        Label("Open the full report", systemImage: "chart.bar.doc.horizontal")
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Analyse again") { Task { await review.analyse() } }
                        .controlSize(.regular)
                    Spacer(minLength: 0)
                }

                Text(analysis.engine)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    /// The four numbers, small. The report has the same four at four times
    /// the size, which is the difference between a glance and a document.
    private var headline: some View {
        HStack(spacing: 8) {
            if review.scoring.markedCount > 0 {
                stat(review.scoring.totalLabel, "MARKS")
            }
            if let m = review.metrics, m.wordCount > 0 {
                stat("\(Int(m.wordsPerMinute.rounded()))", "WORDS/MIN")
                stat(m.verbatim ? String(format: "%.1f", m.fillersPerMinute) : "\u{2014}",
                     "FILLERS/MIN")
            }
            stat("\(review.notes.count)", review.notes.count == 1 ? "NOTE" : "NOTES")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: Notes

    private var notes: some View {
        VStack(spacing: 0) {
            if review.notes.isEmpty {
                placeholder("text.badge.plus", "No notes yet",
                            "Type while the person is still speaking in Screenroom, or add them here while you watch it back \u{2014} each one lands wherever the player is.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(review.notes.enumerated()), id: \.element.id) { index, note in
                            noteRow(note)
                            if index < review.notes.count - 1 { Divider().opacity(0.4) }
                        }
                    }
                    .padding(16)
                }
            }
            Divider()
            composer
        }
    }

    private func noteRow(_ note: ScreenroomNote) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                review.seek(to: note)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(note.offsetLabel)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Brand.text)
                        .frame(width: 42, alignment: .leading)
                    Text(note.text).font(.callout).foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Play from just before this note.")

            Button {
                review.deleteNote(note)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Delete this note.")
        }
        .padding(.vertical, 9)
    }

    /// Adding a note while watching it back.
    ///
    /// The whole reason this exists: a class recorded through Start has no
    /// notes at all, and a presentation often ends with fewer than the
    /// evaluator meant to take, because typing while somebody is speaking is
    /// the hardest part of the job. Watching it back is the second pass, and
    /// the second pass needs somewhere to write.
    ///
    /// Stamped at the PLAYER's position, not at the first keystroke. The live
    /// window corrects for the evaluator being behind the moment; here the
    /// recording has been scrubbed to the moment deliberately, so the
    /// playhead is already the answer.
    private var composer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Self.stamp(draftAtMs ?? review.notePosition))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(draft.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Brand.text))
                .frame(width: 42, alignment: .leading)

            TextField(folder == nil ? "Pick a session" : "Add a note here", text: $draft, axis: .vertical)
                .onChange(of: draft) { old, new in
                    let wasEmpty = old.trimmingCharacters(in: .whitespaces).isEmpty
                    let isEmpty = new.trimmingCharacters(in: .whitespaces).isEmpty
                    if wasEmpty && !isEmpty {
                        draftAtMs = review.notePosition
                    } else if isEmpty {
                        draftAtMs = nil
                    }
                }
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(1...4)
                .focused($composerFocused)
                .disabled(folder == nil)
                .onSubmit { commit() }

            Button("Add") { commit() }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func commit() {
        review.addNote(draft, at: draftAtMs)
        draft = ""
        draftAtMs = nil
        composerFocused = true
    }

    static func stamp(_ ms: Int) -> String {
        let total = max(0, ms / 1000)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Furniture

    /// One shape for every "there is nothing here", centred rather than
    /// stacked at the top of a tall empty pane.
    private func placeholder(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.medium))
            Text(detail)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    @ViewBuilder
    private func bullets(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                eyebrow(title.uppercased())
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle().fill(Brand.fill).frame(width: 4, height: 4).offset(y: -3)
                        Text(item).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(0.6)
            .foregroundStyle(Brand.text)
    }
}
