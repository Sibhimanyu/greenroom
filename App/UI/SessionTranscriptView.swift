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

    @State private var lines: [SessionSummary.Line] = []
    @State private var summary: String?
    @State private var problem: String?
    @State private var working = false
    @State private var copied = false
    /// Which pass is running. A real class is several model calls, so a bare
    /// spinner would sit there for a minute looking broken.
    @State private var step = "Reading the class\u{2026}"

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
                Text("No transcript for this class. Cues writes one only when it was listening and \u{201C}Save the transcript and links with the class\u{201D} is on.")
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
                Text("A bilingual class transcribes thinly: the speech model finalises only what it can render in English, and there is no Tamil model on this Mac.")
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
        step = "Reading the class\u{2026}"
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
