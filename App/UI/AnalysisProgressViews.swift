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

/// One step in a sequence, Ready or running. Not a control: no button or
/// toggle traits, no hover state. VoiceOver reads "Step 1 of 5, Transcribe
/// with Whisper".
struct StepList: View {
    struct Item: Identifiable {
        enum Mark { case number, running, done }
        let id: String
        let title: String
        var mark: Mark
        var tag: String?
        var dim = false
    }

    let items: [Item]
    private let marker: CGFloat = 18
    private let gap: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 8) {
                    markerView(item, number: index + 1)
                    Text(item.title)
                        .font(.callout)
                        .foregroundStyle(item.dim ? .secondary : .primary)
                    Spacer(minLength: 0)
                    if let tag = item.tag {
                        Text(tag).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: marker)
                .overlay(alignment: .topLeading) {
                    if index < items.count - 1 {
                        Rectangle().fill(.quaternary)
                            .frame(width: 1, height: gap)
                            .offset(x: marker / 2 - 0.5, y: marker)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(index + 1) of \(items.count), \(item.title)"
                                    + (item.mark == .done ? ", done" : item.mark == .running ? ", in progress" : ""))
            }
        }
    }

    @ViewBuilder private func markerView(_ item: Item, number: Int) -> some View {
        ZStack {
            switch item.mark {
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .resizable().scaledToFit()
                    .foregroundStyle(Brand.green)
            case .running:
                Circle().fill(.quaternary.opacity(0.5))
                ProgressView().controlSize(.mini).scaleEffect(0.8)
            case .number:
                Circle().fill(.quaternary.opacity(0.5))
                Text("\(number)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: marker, height: marker)
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
                StepList(items: review.plannedSteps.enumerated().map { row, step in
                    let state = ScreenroomRunRules.rowState(row: row, stepIndex: review.stepIndex)
                    return StepList.Item(
                        id: step.id,
                        title: step.title(ScreenroomRunRules.phase(for: state)),
                        mark: state == .done ? .done : state == .running ? .running : .number,
                        dim: state == .waiting)
                })
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
        ZStack(alignment: .top) {
            switch state {
            case .ready:
                AnalysisReadyView(review: review,
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
        .frame(width: 340, alignment: .leading)
        .greenroomGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Ready: what Start will do for this folder, who does it (inline pickers
/// that write the same settings Feedback settings does), and Start.
struct AnalysisReadyView: View {
    @ObservedObject var review: ScreenroomReviewController
    let onStart: () -> Void
    let onCancel: () -> Void

    @State private var rows: [ScreenroomRunRules.PlanRow] = []
    @State private var agent = ScreenroomAgentSettings.load()
    @State private var whisper = ScreenroomTranscriberSettings.whisperIsReady
    @State private var models = ScreenroomWhisper.availableModels()
    @State private var chosenModel = ScreenroomTranscriberSettings.resolvedModel()?.path ?? ""

    private var transcribeOnly: Bool { review.popoverTranscribeOnly }

    private var agentUsable: Bool {
        agent.enabled && !agent.command.trimmingCharacters(in: .whitespaces).isEmpty
    }

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

            StepList(items: rows.map {
                StepList.Item(id: $0.id, title: $0.step.title(.plan),
                              mark: $0.reused ? .done : .number,
                              tag: $0.reused ? "Reused" : nil, dim: $0.reused)
            })

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if !transcribeOnly { writerRow }
                transcriberRow
                if !transcribeOnly {
                    HStack {
                        if agentUsable {
                            Text("Leaves this Mac")
                                .font(.caption)
                                .foregroundStyle(Brand.netText)
                        }
                        Spacer(minLength: 0)
                        quietLink("More settings\u{2026}") { review.openSetup() }
                    }
                }
            }

            HStack {
                Spacer()
                // A normal secondary button: primary label on the bordered
                // shape. The root tint would otherwise colour it green.
                Button(action: onCancel) {
                    Text("Cancel").foregroundStyle(.primary)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                Button("Start", action: onStart)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.green)
            }
        }
        .onAppear { refreshChoices() }
        .onChange(of: review.showingSetup) { refreshChoices() }
        .onChange(of: review.popoverTranscribeOnly) { refreshPlan() }
    }

    // MARK: Report by

    private var writerRow: some View {
        let local = ScreenroomAnalyst.modelAvailability.available
        return choiceRow("Report by") {
            Picker("Report by", selection: Binding(get: { writerTag }, set: setWriter)) {
                Text(local ? "This Mac" : "This Mac (counts only)").tag(Self.macTag)
                ForEach(ScreenroomAgentSettings.Kind.allCases.filter {
                    $0 != .custom || (agent.kind == .custom && agentUsable)
                }) { kind in
                    Text(kind.label).tag(kind.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    private static let macTag = "mac"

    private var writerTag: String { agentUsable ? agent.kind.rawValue : Self.macTag }

    private func setWriter(_ tag: String) {
        // The same writes the Feedback settings tiles make.
        if let kind = ScreenroomAgentSettings.Kind(rawValue: tag) {
            agent.enabled = true
            agent.kind = kind
            if kind != .custom { agent.command = kind.defaultCommand }
        } else {
            agent.enabled = false
        }
        agent.save()
        refreshPlan()
    }

    // MARK: Transcribed by

    @ViewBuilder private var transcriberRow: some View {
        if whisper {
            choiceRow("Transcribed by") {
                if models.count > 1 {
                    Picker("Transcribed by", selection: Binding(get: { chosenModel }, set: setModel)) {
                        ForEach(models) { model in
                            Text(ScreenroomRunRules.transcriberSummary(whisper: true, modelName: model.name))
                                .tag(model.url.path)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                } else {
                    Text(ScreenroomRunRules.transcriberSummary(whisper: true, modelName: models.first?.name))
                        .font(.callout)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                choiceRow("Transcribed by") {
                    Text(ScreenroomRunRules.transcriberSummary(whisper: false, modelName: nil))
                        .font(.callout)
                }
                HStack(spacing: 4) {
                    Text("Whisper is not set up on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    quietLink("Set up Whisper\u{2026}", font: .caption) { review.openSetup() }
                }
            }
        }
    }

    private func setModel(_ path: String) {
        chosenModel = path
        var settings = ScreenroomTranscriberSettings.load()
        settings.modelPath = path
        settings.save()
    }

    // MARK: Pieces

    private func choiceRow<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            control()
        }
    }

    /// The app's inline link: Brand.text on a plain button, the way
    /// "Open report" is drawn. `.link` would take the system blue.
    private func quietLink(_ title: String, font: Font = .callout, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(font).foregroundStyle(Brand.text)
        }
        .buttonStyle(.plain)
    }

    private func refreshChoices() {
        agent = ScreenroomAgentSettings.load()
        whisper = ScreenroomTranscriberSettings.whisperIsReady
        models = ScreenroomWhisper.availableModels()
        chosenModel = ScreenroomTranscriberSettings.resolvedModel()?.path ?? ""
        refreshPlan()
    }

    private func refreshPlan() {
        guard let folder = review.selected?.folder else { rows = []; return }
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        rows = ScreenroomRunRules.plan(
            transcribeOnly: transcribeOnly,
            hasRecording: review.selected?.recording != nil,
            whisper: whisper,
            agent: agentUsable,
            existing: existing)
    }
}
