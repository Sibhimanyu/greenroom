//
//  AnalysisProgressViews.swift
//  Greenroom
//
//  What the watch page's Analysing pill shows: a small ring in the pill, and a
//  popover with the step list, a bar, elapsed time and Stop. Everything is read
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

/// The popover behind the pill.
struct AnalysisProgressPopover: View {
    @ObservedObject var review: ScreenroomReviewController
    let onStop: () -> Void

    var body: some View {
        let progress = review.runProgress
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(progress.isStopping ? "Stopping\u{2026}" : progress.title)
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
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .greenroomGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
