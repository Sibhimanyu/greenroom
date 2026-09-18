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
        /// The deeper pass: material, and whatever agent the teacher already
        /// runs. Third rather than first because it is the one that costs
        /// money and minutes, and the two before it are enough on their own.
        case deep = "Deep"
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
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Reading the notes\u{2026}")
                        }
                    } else {
                        Label("Read the notes", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(review.notes.isEmpty || review.isAnalysing)
                .help(ScreenroomAnalyst.modelAvailability.available
                      ? "Turns the notes into feedback for the speaker, on this Mac."
                      : "Apple Intelligence is unavailable, so this counts what is in the notes instead of writing about them.")

                Button {
                    openWindow(id: "screenroom-report")
                } label: {
                    Label("Open the report", systemImage: "chart.bar.doc.horizontal")
                }
                .disabled(review.selected == nil)
                .help("The full report: the marks, the pace, the fillers and every note, in one place.")

                // One Export menu rather than a button per output. The
                // evaluator is answering one question - how am I handing this
                // over - and the four answers differ in form, not in kind.
                Menu {
                    Section("Written") {
                        Button("Report for the speaker\u{2026}") { review.exportReport(for: .speaker) }
                        Button("Report for me, with the consistency check\u{2026}") { review.exportReport(for: .evaluator) }
                    }
                    Section("Video") {
                        Button("Video with the notes written on it\u{2026}") {
                            Task { await review.exportAnnotatedVideo() }
                        }
                        .disabled(review.selected?.hasRecording != true)
                        Button("Subtitles beside the recording\u{2026}") {
                            Task { await review.exportSubtitles() }
                        }
                        .disabled(review.selected?.hasRecording != true)
                    }
                } label: {
                    if review.isExportingVideo {
                        Text("Rendering \(Int(review.videoProgress * 100))%\u{2026}")
                    } else {
                        Label("Export", systemImage: "square.and.arrow.down")
                    }
                }
                .menuStyle(.button)
                .fixedSize()
                .disabled(review.selected == nil || review.notes.isEmpty || review.isExportingVideo)

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
            case .deep: deepTab
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

    // MARK: The deeper pass

    private var deepTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                materialBlock
                Divider()
                agentBlock
                if let report = review.agentReport {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        eyebrow("AGENT REPORT")
                        Text(report)
                            .font(.caption)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if !review.agentLog.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        eyebrow("RUNNING")
                        Text(review.agentLog.suffix(2_000))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .disabled(review.selected == nil)
    }

    /// What an agent would have to read. Shown as facts rather than as
    /// checkboxes: the teacher is deciding whether there is enough here to be
    /// worth paying for a pass, and "no transcript" is the answer to that.
    private var materialBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            eyebrow("MATERIAL")
            materialRow("Notes", "\(review.notes.count)", review.notes.isEmpty)
            materialRow("Transcript", review.hasTranscript ? "yes" : "not yet", !review.hasTranscript)
            materialRow("Stills", review.frameCount == 0 ? "none" : "\(review.frameCount)", review.frameCount == 0)
            if let metrics = review.metrics {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(metrics.sentences, id: \.self) { sentence in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\u{2022}").foregroundStyle(.tertiary)
                            Text(sentence)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
            }

            // Which transcriber, shown before the button rather than in a
            // preference pane, because the choice changes what the numbers
            // above it are worth.
            Picker("", selection: Binding(
                get: { review.transcriberSettings.engine },
                set: { review.transcriberSettings.engine = $0; review.saveTranscriberSettings() })) {
                ForEach(ScreenroomTranscriberSettings.Engine.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if review.transcriberSettings.engine == .whisper && !review.whisperReady {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Whisper is not set up on this Mac. Two commands in a Terminal:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("brew install whisper-cpp")
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                    Text(review.whisperDownloadCommand)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor)))
            } else if review.transcriberSettings.engine == .apple {
                Text("Apple's recogniser is built for dictation: it smooths out \"um\" and \"you know\" before Screenroom ever sees them, so filler words cannot be counted from it. Everything else still works.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await review.prepareMaterial() }
            } label: {
                if review.isPreparing {
                    HStack(spacing: 6) {
                        ProgressView(value: review.prepareProgress).controlSize(.small).frame(width: 60)
                        Text(review.prepareStep)
                    }
                } else {
                    Label(review.hasTranscript ? "Do it again" : "Transcribe and take stills",
                          systemImage: "waveform.and.person.filled")
                }
            }
            .disabled(review.selected?.hasRecording != true || review.isPreparing
                      || (review.transcriberSettings.engine == .whisper && !review.whisperReady))
            .help("Transcribes the recording on this Mac and pulls one still every twenty seconds. Nothing leaves the Mac in this step, whichever engine you pick.")
        }
    }

    private func materialRow(_ title: String, _ value: String, _ missing: Bool) -> some View {
        HStack {
            Text(title).font(.caption)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(missing ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Brand.green))
        }
    }

    private var agentBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            eyebrow("YOUR AGENT")

            Toggle("Send this presentation to an agent", isOn: Binding(
                get: { review.agentSettings.enabled },
                set: { review.agentSettings.enabled = $0; review.saveAgentSettings() }))
                .font(.caption)

            if review.agentSettings.enabled {
                Picker("", selection: Binding(
                    get: { review.agentSettings.kind },
                    set: { kind in
                        review.agentSettings.kind = kind
                        // Swapping the agent replaces the command, unless the
                        // teacher has written their own - overwriting an
                        // edited command with a default is the kind of thing
                        // that costs somebody an afternoon.
                        if kind != .custom,
                           ScreenroomAgentSettings.Kind.allCases.map(\.defaultCommand)
                            .contains(review.agentSettings.command) {
                            review.agentSettings.command = kind.defaultCommand
                        }
                        review.saveAgentSettings()
                    })) {
                    ForEach(ScreenroomAgentSettings.Kind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // The command is shown, not hidden behind a preference. It is
                // about to run in the teacher's own shell with their own
                // credentials, and they should be able to read it first.
                TextField("command", text: Binding(
                    get: { review.agentSettings.command },
                    set: { review.agentSettings.command = $0; review.saveAgentSettings() }),
                          axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1...4)

                Text("Runs in your login shell, in this presentation's folder, with the brief on standard input. Read-only: the agent cannot change these files, and Screenroom saves what it prints.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("This is the one part of Screenroom that may leave your Mac. Whatever your agent does with a transcript and stills of a named student is between you and it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task { await review.runAgent() }
                } label: {
                    if review.isRunningAgent {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Running\u{2026}")
                        }
                    } else {
                        Label("Run the agent", systemImage: "terminal")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(review.selected == nil || review.isRunningAgent
                          || review.agentSettings.command.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Writes BRIEF.md into the folder and runs your agent on it.")
            }
        }
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.tertiary)
    }
}
