//
//  ScreenroomReviewWindow.swift
//  Greenroom
//
//  Afterwards: the recording, the notes that point into it, the rubric, and
//  the report that comes out.
//
//  Three columns, in the order the work happens: which presentation (left),
//  the presentation itself (middle), what you are writing about it (right).
//  The right column is the same fixed 320pt as the live window's notes and
//  the Classroom Console's Live Queue, so nothing in this app has to be
//  re-learned.
//
//  Clicking a note seeks the recording to it. That is the single interaction
//  the whole timestamped-note design exists to make possible, so it is one
//  click from anywhere in the list, with no mode to enter first.
//
import AVKit
import AppKit
import SwiftUI

struct ScreenroomReviewWindow: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var review = ScreenroomReviewController.shared
    @State private var tab: Tab = .notes

    private enum Tab: String, CaseIterable {
        case notes = "Notes"
        case rubric = "Rubric"
    }

    private static let columnWidth: CGFloat = 320
    private static let sidebarWidth: CGFloat = 220

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: Self.sidebarWidth)
            Divider()
            stage
            Divider()
            column
                .frame(width: Self.columnWidth)
        }
        .frame(minWidth: 1_060, minHeight: 620)
        .tint(Brand.green)
        .onAppear { review.refresh() }
        // The report is the point of pressing the button, so it opens itself.
        // Watching a counter rather than `analysis` so that merely selecting a
        // presentation that already has one does not throw a window at you.
        .onChange(of: review.analysisRuns) { _, _ in
            openWindow(id: "screenroom-report")
        }
    }

    // MARK: Which presentation

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                eyebrow("PRESENTATIONS")
                Spacer()
                Button {
                    review.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Look again for presentations on disk.")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            if review.presentations.isEmpty {
                VStack(spacing: 6) {
                    Text("Nothing recorded yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Screenroom lists every folder in Documents/Greenroom that has notes in it.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(
                    get: { review.selected?.folder },
                    set: { folder in
                        review.select(review.presentations.first { $0.folder == folder })
                    })) {
                    ForEach(review.presentations) { presentation in
                        row(presentation).tag(presentation.folder)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func row(_ presentation: ScreenroomPresentation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(presentation.presenter)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(presentation.dateLabel)
                Text("\u{00B7}")
                Text("\(presentation.noteCount) \(presentation.noteCount == 1 ? "note" : "notes")")
                if !presentation.hasRecording {
                    Text("\u{00B7} no video")
                }
                if presentation.hasReport {
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(Brand.text)
                        .help("A report has been written for this one.")
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    // MARK: The recording

    private var stage: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.black)
                if review.selected?.hasRecording == true {
                    VideoPlayer(player: review.player)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "video.slash")
                            .font(.title)
                            .foregroundStyle(.tertiary)
                        Text(review.selected == nil
                             ? "Pick a presentation."
                             : "This one has notes but no recording.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if review.selected != nil {
                            Text("The notes still work; only the seeking does not.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            actions
        }
        .padding(20)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    Task { await review.analyse() }
                } label: {
                    if review.isAnalysing {
                        HStack(spacing: 8) {
                            ProgressView(value: review.progress)
                                .controlSize(.small).frame(width: 54)
                            Text(review.step)
                        }
                    } else {
                        Label(review.analysis == nil ? "Analyse" : "Analyse again",
                              systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(review.selected == nil || review.isAnalysing)
                .help("Transcribes the recording, takes stills, counts the speech, compares the marking against the group, and writes the report.")

                Button {
                    openWindow(id: "screenroom-report")
                } label: {
                    Label("Open the report", systemImage: "chart.bar.doc.horizontal")
                }
                .disabled(review.selected == nil)
                .help("The full report: the marks, the pace, the fillers and every note, in one place.")

                Spacer(minLength: 0)

                if let folder = review.selected?.folder {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Show this presentation's folder in the Finder.")
                }
            }

            if let status = review.status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !ScreenroomAnalyst.modelAvailability.available,
                      let reason = ScreenroomAnalyst.modelAvailability.reason {
                Text("Written feedback needs Apple Intelligence \u{2014} \(reason). The report still lists everything the notes recorded.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Notes and rubric

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            switch tab {
            case .notes: notesTab
            case .rubric: rubricTab
            }
        }
    }

    private var notesTab: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let analysis = review.analysis {
                    analysisBlock(analysis)
                    Divider()
                }
                if review.notes.isEmpty {
                    Text("No notes in this presentation.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
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
                            Text(note.text)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Play the recording from just before this note.")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private func analysisBlock(_ analysis: ScreenroomAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            eyebrow(analysis.engine.uppercased())
            Text(analysis.summary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            bullets("What went well", analysis.strengths)
            bullets("What to work on", analysis.workOn)
            bullets("Across the whole thing", analysis.patterns)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func bullets(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\u{2022}").foregroundStyle(.tertiary)
                        Text(item)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var rubricTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(review.scoring.rubric.criteria) { criterion in
                    criterionRow(criterion)
                }

                HStack {
                    Text("Total")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text(review.scoring.totalLabel)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                }

                if !review.cohortFindings.isEmpty {
                    Divider()
                    consistencyBlock
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .disabled(review.selected == nil)
    }

    private func criterionRow(_ criterion: ScreenroomCriterion) -> some View {
        let mark = review.scoring.score(for: criterion)
        return VStack(alignment: .leading, spacing: 6) {
            Text(criterion.title)
                .font(.callout.weight(.medium))
            if !criterion.hint.isEmpty {
                Text(criterion.hint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                ForEach(1...max(1, criterion.maxScore), id: \.self) { value in
                    Button {
                        // Pressing the mark it already has clears it. An
                        // unmarked line is a real state - see ScreenroomScore - and
                        // there has to be a way back to it.
                        review.setScore(mark.score == value ? nil : value, for: criterion)
                    } label: {
                        Text("\(value)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .frame(width: 26, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(mark.score == value
                                          ? AnyShapeStyle(Brand.green)
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

    private var consistencyBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            eyebrow("CONSISTENCY")
            Text("How this marking sits against the rest of the group. Yours to read, not the speaker's.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(review.cohortFindings) { finding in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: finding.weight == .check
                          ? "exclamationmark.circle.fill" : "equal.circle")
                        .font(.caption)
                        .foregroundStyle(finding.weight == .check
                                         ? AnyShapeStyle(Color.orange)
                                         : AnyShapeStyle(.tertiary))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(finding.headline)
                            .font(.caption.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(finding.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.tertiary)
    }
}
