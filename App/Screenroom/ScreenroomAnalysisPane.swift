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

    enum Pane { case analysis, notes, rubric }

    /// The folder the window has selected. Nil while nothing is.
    let folder: URL?
    let showing: Pane
    /// Seeks the window's own player, in milliseconds.
    let seek: (Int) -> Void

    @ObservedObject private var review = ScreenroomReviewController.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch showing {
            case .analysis: analysis
            case .notes: notes
            case .rubric: rubric
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

    /// A named step and a bar, never a bare spinner - DESIGN.md's waiting rule.
    /// The tail of the tool's own output sits under it, because whisper and an
    /// agent both go quiet for minutes and a still window is indistinguishable
    /// from a hung one.
    private var running: some View {
        VStack(spacing: 14) {
            ProgressView(value: review.progress)
                .progressViewStyle(.linear)
                .frame(maxWidth: 280)
            Text(review.step.isEmpty ? "Working\u{2026}" : review.step)
                .font(.callout.weight(.medium))
            if !review.log.isEmpty {
                Text(review.log.suffix(280))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func analysed(_ analysis: ScreenroomAnalysis) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(analysis.summary)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                bullets("What worked", analysis.strengths)
                bullets("What to change", analysis.workOn)
                bullets("Across the whole thing", analysis.patterns)

                if let metrics = review.metrics, metrics.wordCount > 0 {
                    Divider()
                    eyebrow("SPEECH")
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(metrics.sentences, id: \.self) { sentence in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\u{2022}").foregroundStyle(.tertiary)
                                Text(sentence).font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                Divider()
                HStack(spacing: 10) {
                    Button {
                        openWindow(id: "screenroom-report")
                    } label: {
                        Label("Open the report", systemImage: "chart.bar.doc.horizontal")
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Analyse again") { Task { await review.analyse() } }
                    Spacer(minLength: 0)
                }
                Text(analysis.engine)
                    .font(.caption2).foregroundStyle(.tertiary)
                if let status = review.status {
                    Text(status).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    // MARK: Notes

    @ViewBuilder
    private var notes: some View {
        if review.notes.isEmpty {
            placeholder("text.badge.plus", "No notes on this one",
                        "Notes come from recording through Screenroom, where you type while the person is still speaking. A class recorded with Start has none, and everything else still works.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(review.notes.enumerated()), id: \.element.id) { index, note in
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
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Play from just before this note.")
                        if index < review.notes.count - 1 { Divider().opacity(0.4) }
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: Rubric

    @ViewBuilder
    private var rubric: some View {
        if folder == nil {
            placeholder("checklist", "Nothing selected", "Pick a session on the left.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(review.scoring.rubric.criteria) { criterion in
                        criterionRow(criterion)
                    }
                    Divider()
                    HStack {
                        Text("Total").font(.callout.weight(.semibold))
                        Spacer()
                        Text(review.scoring.totalLabel)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                    }
                }
                .padding(16)
            }
        }
    }

    private func criterionRow(_ criterion: ScreenroomCriterion) -> some View {
        let mark = review.scoring.score(for: criterion)
        return VStack(alignment: .leading, spacing: 6) {
            Text(criterion.title).font(.callout.weight(.medium))
            if !criterion.hint.isEmpty {
                Text(criterion.hint).font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                ForEach(1...max(1, criterion.maxScore), id: \.self) { value in
                    Button {
                        // Pressing the mark it already has clears it: unmarked
                        // is a real state and there has to be a way back to it.
                        review.setScore(mark.score == value ? nil : value, for: criterion)
                    } label: {
                        Text("\(value)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .frame(width: 26, height: 24)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(mark.score == value
                                      ? AnyShapeStyle(Brand.fill)
                                      : AnyShapeStyle(Color(nsColor: .controlBackgroundColor))))
                            .foregroundStyle(mark.score == value ? Color.white : Color.primary)
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            TextField("Why", text: Binding(
                get: { review.scoring.score(for: criterion).comment },
                set: { review.setComment($0, for: criterion) }))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
        }
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
