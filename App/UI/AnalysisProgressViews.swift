//
//  AnalysisProgressViews.swift
//  Greenroom
//
//  What the watch page's Get feedback capsule shows: a small ring while it
//  runs, and one popover with two states, Ready (steps, choices, Start) and
//  progress (step list, a bar, elapsed time, tokens and Stop). Everything is read
//  from ScreenroomReviewController.runProgress; the maths is in
//  ScreenroomRunRules. Colours come from tokens (Brand.green, semantic styles).
//
import SwiftUI

/// The pill's icon: a ring that fills with the whole run, or the small spinner
/// until the first step has begun or while stopping.
struct AnalysisRing: View {
    let progress: ScreenroomReviewController.RunProgress

    var body: some View {
        if progress.stepLine == nil || progress.isStopping {
            ProgressView().controlSize(.small)
        } else {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.04, progress.overall))
                    .stroke(Brand.green, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
            .animation(.easeOut(duration: 0.3), value: progress.overall)
            .accessibilityHidden(true)
        }
    }
}

/// The running state of the popover (chrome and width come from
/// AnalysisRunPopover).
struct AnalysisProgressPopover: View {
    @ObservedObject var review: ScreenroomReviewController
    let onStop: () -> Void

    var body: some View {
        let progress = review.runProgress
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(progress.heading)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle(progress))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            bar(progress)

            if !review.plannedSteps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(review.plannedSteps.enumerated()), id: \.element.id) { row, step in
                        stepRow(step, state: ScreenroomRunRules.rowState(row: row, stepIndex: review.stepIndex))
                    }
                }
            }

            if let last = review.log.split(whereSeparator: \.isNewline).last, !last.isEmpty {
                Text(String(last))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
            }

            if let line = review.usageLine, !progress.isStopping {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let eta = review.eta, !progress.isStopping {
                Text(ScreenroomETA.label(eta))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Stopping keeps the steps that finished. Your recording and notes are never touched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Stop", role: .destructive, action: onStop)
                    .disabled(progress.isStopping)
                    .help("Stops the run and closes whatever it started")
            }
        }
    }

    private func subtitle(_ progress: ScreenroomReviewController.RunProgress) -> String {
        var parts: [String] = []
        if let line = progress.stepLine { parts.append(line) }
        if let fraction = progress.fraction { parts.append(ScreenroomRunRules.percent(fraction)) }
        parts.append(ScreenroomAnalysisPane.clock(progress.elapsed))
        return parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder private func bar(_ progress: ScreenroomReviewController.RunProgress) -> some View {
        if let fraction = progress.fraction, !progress.isStopping {
            ProgressView(value: min(max(fraction, 0), 1)).tint(Brand.green)
        } else {
            ProgressView().progressViewStyle(.linear).tint(Brand.green)
        }
    }

    private func stepRow(_ step: ScreenroomRunStep, state: ScreenroomRunRules.RowState) -> some View {
        HStack(spacing: 8) {
            switch state {
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.green)
            case .running:
                Image(systemName: "circle.dotted").foregroundStyle(.primary)
            case .waiting:
                Image(systemName: "circle").foregroundStyle(.tertiary)
            }
            Text(step.title)
                .font(.callout)
                .foregroundStyle(state == .waiting ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The one popover behind the Get feedback capsule. Ready until Start, then
/// the same popover crossfades in place to the progress view. Closing it never
/// stops the run; clicking the capsule reopens it.
struct AnalysisRunPopover: View {
    @ObservedObject var review: ScreenroomReviewController
    let onStart: () -> Void
    let onStop: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = ScreenroomRunRules.popoverState(isAnalysing: review.isAnalysing)
        let inline = state == .ready && !review.popoverTranscribeOnly
            && ScreenroomRunRules.showsChoicesInline(setupSeen: AnalysisSetup.seen)
        ZStack(alignment: .top) {
            switch state {
            case .ready:
                AnalysisReadyView(review: review, inlineChoices: inline,
                                  onStart: onStart, onCancel: { review.runPopoverOpen = false })
                    .transition(.opacity)
            case .running:
                AnalysisProgressPopover(review: review, onStop: onStop)
                    .transition(.opacity)
            }
        }
        // DESIGN.md Motion: 150-250ms state change, ease-in-out. A crossfade
        // is already the Reduce Motion form.
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.2), value: state)
        .padding(16)
        .frame(width: inline ? 440 : 320, alignment: .leading)
        .greenroomGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Ready: what Start will do for this folder, who does it, and Start.
struct AnalysisReadyView: View {
    @ObservedObject var review: ScreenroomReviewController
    let inlineChoices: Bool
    let onStart: () -> Void
    let onCancel: () -> Void

    @State private var rows: [ScreenroomRunRules.PlanRow] = []
    @State private var agent = ScreenroomAgentSettings.load()
    @State private var whisper = ScreenroomTranscriberSettings.whisperIsReady
    @State private var modelName: String?

    private var transcribeOnly: Bool { review.popoverTranscribeOnly }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(transcribeOnly ? "Transcribe" : "Get feedback").font(.headline)
                Text(transcribeOnly
                     ? "Writes a transcript. No report."
                     : "Steps for this meeting")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Image(systemName: row.reused ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(row.reused ? AnyShapeStyle(Brand.green) : AnyShapeStyle(.tertiary))
                        Text(row.step.title)
                            .font(.callout)
                            .foregroundStyle(row.reused ? .secondary : .primary)
                        Spacer(minLength: 0)
                        if row.reused {
                            Text("Reused").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            if inlineChoices {
                ScreenroomSettingsTab(compact: true)
                    .frame(height: 300)
                    .onDisappear(perform: refreshChoices)
            } else {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    if !transcribeOnly {
                        choiceLine("Report by", ScreenroomRunRules.writerSummary(
                            agentOn: agent.enabled, command: agent.command, agentName: agent.kind.label))
                    }
                    choiceLine("Transcribed by", ScreenroomRunRules.transcriberSummary(
                        whisper: whisper, modelName: modelName))
                    HStack(spacing: 8) {
                        if !transcribeOnly, agent.enabled,
                           !agent.command.trimmingCharacters(in: .whitespaces).isEmpty {
                            Text("Leaves this Mac")
                                .font(.caption)
                                .foregroundStyle(Brand.netText)
                        }
                        Spacer(minLength: 0)
                        Button("Change\u{2026}") { review.openSetup() }
                            .buttonStyle(.link)
                            .font(.callout)
                            .tint(Brand.text)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Start", action: onStart)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.green)
            }
        }
        .onAppear { refreshPlan(); refreshChoices() }
        .onChange(of: review.showingSetup) { refreshPlan(); refreshChoices() }
        .onChange(of: review.popoverTranscribeOnly) { refreshPlan() }
    }

    private func choiceLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.callout)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func refreshChoices() {
        agent = ScreenroomAgentSettings.load()
        whisper = ScreenroomTranscriberSettings.whisperIsReady
        modelName = ScreenroomTranscriberSettings.resolvedModel().map {
            $0.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "ggml-", with: "")
        }
        refreshPlan()
    }

    private func refreshPlan() {
        guard let folder = review.selected?.folder else { rows = []; return }
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        rows = ScreenroomRunRules.plan(
            transcribeOnly: transcribeOnly,
            hasRecording: review.selected?.recording != nil,
            whisper: whisper,
            agent: agent.enabled && !agent.command.trimmingCharacters(in: .whitespaces).isEmpty,
            existing: existing)
    }
}
