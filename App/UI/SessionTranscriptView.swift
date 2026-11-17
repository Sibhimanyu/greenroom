//
//  SessionTranscriptView.swift
//  Greenroom
//
//  What was said in a class, and what it was about.
//
//  Until now the transcript was written to the class folder and readable only
//  in Finder: the app recorded it, saved it, named it in the status log, and
//  then offered no way to look at it. This is that way.
//
//  Two things stacked, in the order a teacher wants them. The summary first,
//  because after a lesson you want the gist and not 40 minutes of lines. The
//  transcript under it, timestamped and selectable, because the summary is a
//  model's account and the lines are the evidence.
//
//  The summary is generated on this Mac and cached in the class's own folder.
//  Never a cloud call: a class transcript is children speaking, and Cues
//  already promises that only a short search phrase ever leaves.
//
import SwiftUI

struct SessionTranscriptView: View {
    let folder: URL
    /// Watch mode: a click on a line moves the picture to it.
    var onSeek: ((Double) -> Void)?

    @State private var lines: [SessionSummary.Line] = []
    @State private var summary: String?
    @State private var problem: String?
    @State private var working = false
    @State private var copied = false
    /// Which pass is running. A real class is several model calls, so a bare
    /// spinner would sit there for a minute looking broken.
    @State private var step = "Reading the meeting\u{2026}"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryCard
            Divider()
            transcriptList
        }
        .task(id: folder) { load() }
    }

    // MARK: Summary

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("SUMMARY")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .kerning(0.8)
                    .foregroundStyle(.tertiary)
                Spacer()
                if working {
                    ProgressView().controlSize(.small)
                    Text(step)
                        .font(.caption).foregroundStyle(.secondary)
                } else if summary != nil {
                    Button("Copy") { copy() }
                        .controlSize(.small)
                        .help("Copy the summary")
                    Button("Again") { summarise() }
                        .controlSize(.small)
                        .help("Write a new summary from the same transcript")
                } else if lines.isEmpty {
                    EmptyView()
                } else if let reason = SessionSummary.unavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Summarise on this Mac") { summarise() }
                        .controlSize(.small)
                }
            }

            if let summary {
                ScrollView {
                    Text(LocalizedStringKey(summary))
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 190)
            } else if let problem {
                Text(problem)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if lines.isEmpty {
                Text(SessionSummary.hasTranscript(in: folder)
                     ? "Nothing was said that the speech model could make out: this meeting's transcript is only room sound."
                     : "No transcript for this meeting. Cues writes one only when it was listening and \u{201C}Save the transcript and links with the meeting\u{201D} is on.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(lines.count) line\(lines.count == 1 ? "" : "s") transcribed. Nothing leaves this Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if copied {
                Text("Copied").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Transcript

    @ViewBuilder private var transcriptList: some View {
        if lines.isEmpty {
            VStack(spacing: 6) {
                Text("Nothing was transcribed")
                    .font(.system(size: 13, weight: .medium))
                Text("A bilingual meeting transcribes thinly: the speech model finalises only what it can render in English, and there is no Tamil model on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            // Machine facts in mono, prose in the system face,
                            // which is the split DESIGN.md asks for. Tabular
                            // figures so the stamps form a column.
                            Text(line.stamp)
                                .font(.system(size: 11, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                                .frame(width: 56, alignment: .leading)
                            Text(line.text)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let onSeek, let at = SessionDetailRules.stampSeconds(line.stamp) { onSeek(at) }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: Work

    private func load() {
        lines = SessionSummary.lines(in: folder)
        summary = SessionSummary.cached(in: folder)
        problem = nil
        copied = false
    }

    private func summarise() {
        guard #available(macOS 26.0, *) else { return }
        working = true
        problem = nil
        step = "Reading the meeting\u{2026}"
        Task {
            let outcome = await SessionSummary.generate(for: folder) { note in
                Task { @MainActor in step = note }
            }
            await MainActor.run {
                working = false
                switch outcome {
                case .summary(let text): summary = text
                case .problem(let text): problem = text
                }
            }
        }
    }

    private func copy() {
        guard let summary else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await MainActor.run { copied = false }
        }
    }
}

// MARK: - Edit mode

/// The transcript as a way to cut: a click on a sentence marks that stretch as
/// removed (shift-click extends to a second sentence), a click on a struck
/// sentence puts it back, and the stamp moves the picture there.
struct SessionEditTranscript: View {
    let folder: URL
    @EnvironmentObject private var vm: EditorViewModel
    @State private var lines: [SessionSummary.Line] = []
    @State private var starts: [Double] = []
    @State private var anchor: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TRANSCRIPT")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 6)
            if lines.isEmpty {
                Text("No transcript to click on. Get feedback writes one, on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                            row(index, line)
                        }
                    }
                    .padding(.bottom, 8)
                }
                Text("Click a sentence to cut it out. Shift-click to cut through a second one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: folder) {
            lines = SessionSummary.lines(in: folder)
            starts = lines.map { SessionDetailRules.stampSeconds($0.stamp) ?? 0 }
        }
    }

    private var current: Int? { SessionDetailRules.currentLine(starts: starts, at: vm.playhead) }

    private func cut(covering index: Int) -> CutRegion? {
        guard let span = SessionDetailRules.transcriptSpan(starts: starts, from: index, duration: vm.duration)
        else { return nil }
        let mid = (span.lowerBound + span.upperBound) / 2
        return vm.cuts.first { $0.start <= mid && mid <= $0.end }
    }

    private func row(_ index: Int, _ line: SessionSummary.Line) -> some View {
        let struck = cut(covering: index) != nil
        let isCurrent = current == index
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.stamp)
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 50, alignment: .leading)
                .onTapGesture { vm.seek(to: starts[index]) }
            Text(line.text)
                .font(.system(size: 13))
                .strikethrough(struck)
                .foregroundStyle(struck ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(isCurrent ? Color.primary.opacity(0.07) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { clicked(index) }
        .help(struck ? "Click to put this back" : "Click to cut this out of the video")
    }

    private func clicked(_ index: Int) {
        if let existing = cut(covering: index) {
            vm.deleteCut(id: existing.id)
            anchor = nil
            return
        }
        let shift = NSEvent.modifierFlags.contains(.shift)
        if shift, let first = anchor {
            let lo = min(first, index), hi = max(first, index)
            if let span = SessionDetailRules.transcriptSpan(starts: starts, from: lo, to: hi, duration: vm.duration) {
                vm.addCut(start: span.lowerBound, end: span.upperBound)
            }
            anchor = nil
        } else if let span = SessionDetailRules.transcriptSpan(starts: starts, from: index, duration: vm.duration) {
            vm.addCut(start: span.lowerBound, end: span.upperBound)
            anchor = index
        }
    }
}
