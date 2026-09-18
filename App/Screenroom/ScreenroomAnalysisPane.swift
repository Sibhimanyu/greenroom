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
//  The analysis does not care whether a folder holds a class or a
//  presentation. A transcript, filler counts, pace and an agent pass need a
//  recording; notes and a rubric are what a presentation has EXTRA. A class
//  recorded through Start is analysable on exactly the same terms, which is
//  the whole reason this merge was worth doing.
//
import SwiftUI

struct ScreenroomAnalysisPane: View {
    /// The folder the window has selected. Nil while nothing is.
    let folder: URL?
    /// Seeks the window's own player, in milliseconds.
    let seek: (Int) -> Void

    @ObservedObject private var review = ScreenroomReviewController.shared
    @Environment(\.openWindow) private var openWindow
    @State private var tab: Tab = .analysis

    private enum Tab: String, CaseIterable, Identifiable {
        case analysis = "Analysis"
        case notes = "Notes"
        case rubric = "Rubric"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            actions

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case .analysis: analysisTab
            case .notes: notesTab
            case .rubric: rubricTab
            }
        }
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

    // MARK: The one button

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    Task { await review.analyse() }
                } label: {
                    if review.isAnalysing {
                        HStack(spacing: 8) {
                            ProgressView(value: review.progress)
                                .controlSize(.small).frame(width: 48)
                            Text(review.step).lineLimit(1)
                        }
                    } else {
                        Label(review.analysis == nil ? "Analyse" : "Analyse again",
                              systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(folder == nil || review.isAnalysing)
                .help("Transcribes the recording, takes stills, counts the speech, compares the marking against the group, and writes the report.")

                Button {
                    openWindow(id: "screenroom-report")
                } label: {
                    Label("Report", systemImage: "chart.bar.doc.horizontal")
                }
                .disabled(review.analysis == nil && review.notes.isEmpty)
                .help("The full report: the marks, the pace, the fillers and every note.")

                Spacer(minLength: 0)
            }

            if let status = review.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Tabs

    private var analysisTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let analysis = review.analysis {
                    eyebrow(analysis.engine.uppercased())
                    Text(analysis.summary).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    bullets("What worked", analysis.strengths)
                    bullets("What to change", analysis.workOn)
                    bullets("Across the whole thing", analysis.patterns)
                } else {
                    Text("Not analysed yet.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Analyse transcribes the recording on this Mac, counts pace and filler words, and writes the report. It works on a class as well as a presentation.")
                        .font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let metrics = review.metrics, metrics.wordCount > 0 {
                    Divider()
                    eyebrow("SPEECH")
                    ForEach(metrics.sentences, id: \.self) { sentence in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\u{2022}").foregroundStyle(.tertiary)
                            Text(sentence).font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if !review.log.isEmpty && review.isAnalysing {
                    Divider()
                    Text(review.log.suffix(600))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var notesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if review.notes.isEmpty {
                    Text("No notes were taken during this one.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Notes come from recording through Screenroom. A class recorded with Start has none, and everything else still works.")
                        .font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(review.notes) { note in
                    Button {
                        review.seek(to: note)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(note.offsetLabel)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(Brand.text)
                            Text(note.text).font(.callout).foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Play from just before this note.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rubricTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(review.scoring.rubric.criteria) { criterion in
                    criterionRow(criterion)
                }
                HStack {
                    Text("Total").font(.callout.weight(.semibold))
                    Spacer()
                    Text(review.scoring.totalLabel)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(folder == nil)
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

    @ViewBuilder
    private func bullets(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\u{2022}").foregroundStyle(.tertiary)
                        Text(item).font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(Brand.text)
    }
}
