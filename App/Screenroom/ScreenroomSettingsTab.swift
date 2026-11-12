//
//  ScreenroomSettingsTab.swift
//  Greenroom
//
//  One-time setup, kept out of the working flow. It is no longer a Settings
//  tab: AnalysisSetupPanel shows it at the first press of Analyse, and the
//  "How to analyse" link beside Analyse reopens it.
//
//  Everything here used to sit beside the report, which made a six-decision
//  form out of a one-button job: which transcriber, whether to prepare, agent
//  or not, which agent, what command, and then separately whether to read the
//  notes. None of those are decisions a teacher makes per student. They are
//  decisions about this Mac, made once, and this is where decisions about this
//  Mac live.
//
//  What is deliberately NOT here: the transcriber. Whisper when the Mac has
//  it, Apple's when it does not, decided by the pipeline. Apple's deletes the
//  disfluencies the speech analysis exists to count, so nobody would choose
//  it, and offering the choice only invited somebody to get it wrong. The
//  picture reports which one will run, as a fact rather than a control.
//
//  Drawn the way Settings -> Webcam is: a picture first (where a presentation
//  goes, in the site's diagram grammar - green stays on this Mac, amber
//  leaves it), choices as tiles, explanations in hover help. The page used to
//  be four paragraphs of footer, and the one fact in them that matters - the
//  agent is the only part that can leave the Mac - is now an amber line you
//  can see rather than a sentence you have to read.
//
//  `ScreenroomPageContent` takes plain values and bindings, so it can be
//  rendered off screen with samples. `ScreenroomSettingsTab` feeds it.
//
import SwiftUI

// MARK: - The tab

struct ScreenroomSettingsTab: View {
    /// Setup focuses on the two choices that matter before a first presentation.
    private let compact: Bool

    init(compact: Bool = false) {
        self.compact = compact
    }

    @State private var agent = ScreenroomAgentSettings.load()
    @State private var transcriber = ScreenroomTranscriberSettings.load()
    @State private var whisperReady = ScreenroomTranscriberSettings.whisperIsReady
    @State private var models = ScreenroomWhisper.availableModels()
    @State private var chosenModel = ScreenroomTranscriberSettings.resolvedModel()?.path ?? ""
    @ObservedObject private var installer = WhisperInstaller.shared

    var body: some View {
        let local = ScreenroomAnalyst.modelAvailability
        ScreenroomPageContent(
            agentOn: Binding(get: { agent.enabled },
                             set: { agent.enabled = $0; agent.save() }),
            agentKind: Binding(get: { agent.kind }, set: { kind in
                agent.kind = kind
                // A named agent always brings its own command back. It used
                // to keep an edited command across a switch, so a slip in
                // the Claude Code line followed the teacher to Codex. Only "a
                // command of my own" keeps what was typed, because that is
                // the point of it.
                if kind != .custom { agent.command = kind.defaultCommand }
                agent.save()
            }),
            command: Binding(get: { agent.command },
                             set: { agent.command = $0; agent.save() }),
            commandIsEdited: agent.kind != .custom && agent.command != agent.kind.defaultCommand,
            revertCommand: {
                agent.command = agent.kind.defaultCommand
                agent.save()
            },
            whisperReady: whisperReady,
            localWriter: local.available,
            localWriterHelp: localWriterHelp(local),
            models: modelTiles,
            download: downloadState,
            busy: installer.isBusy,
            chooseModel: chooseModel,
            downloadModel: { installer.download($0) },
            cancelDownload: { installer.cancel() },
            setup: { WhisperSetupRows(onChange: refresh) },
            compact: compact)
        // No width of its own. SettingsView sizes the window (760pt) and
        // every other tab fills it; pinning this one to 520 made it the only
        // tab sitting in half the pane.
        .onAppear { refresh() }
        // A model downloaded from any of the per-model tiles.
        .onChange(of: installer.revision) { _ in refresh() }
    }

    /// What happens with no agent depends on the Mac, so the help says
    /// which. Below macOS 26, or with Apple Intelligence off, there is no
    /// on-device model to write with, and the report is the counted one.
    private func localWriterHelp(_ model: (available: Bool, reason: String?)) -> String {
        if model.available {
            return "Greenroom writes the report on this Mac, using Apple\u{2019}s on-device model."
        }
        let why: String
        if #available(macOS 26.0, *) {
            why = "Apple\u{2019}s on-device model is not ready here (\(model.reason ?? "not available"))"
        } else {
            why = "Feedback written on this Mac needs macOS 26 with Apple Intelligence"
        }
        return "\(why), so the report has the counts and your notes, with no written feedback. Turn on an agent to have it written."
    }

    /// The offered sizes, then anything else already on disk, one tile each.
    /// Picking an installed one is the model choice Cues shares (it writes
    /// the same setting WhisperModelPicker does); picking one that is not
    /// here downloads it.
    private var modelTiles: [ScreenroomModelTile] {
        var tiles = ScreenroomWhisper.offeredModels.map { offer -> ScreenroomModelTile in
            let installed = models.first { $0.url.lastPathComponent == offer.name }
            let english = offer.name.contains(".en")
            return ScreenroomModelTile(
                id: offer.name,
                title: Self.tileTitle[offer.name] ?? offer.name,
                size: offer.size,
                englishOnly: english,
                tier: Self.tier(offer.name),
                installedPath: installed?.url.path,
                help: (offer.name == WhisperInstaller.recommendedModel ? "Recommended. " : "") + offer.note)
        }
        let offered = Set(ScreenroomWhisper.offeredModels.map(\.name))
        for model in models where !offered.contains(model.url.lastPathComponent) {
            tiles.append(ScreenroomModelTile(
                id: model.url.lastPathComponent,
                title: model.family.capitalized + (model.isEnglishOnly ? " EN" : ""),
                size: model.sizeLabel,
                englishOnly: model.isEnglishOnly,
                tier: Self.tier(model.url.lastPathComponent),
                installedPath: model.url.path,
                help: model.label))
        }
        return tiles.map { tile in
            var tile = tile
            tile.chosen = tile.installedPath != nil && tile.installedPath == chosenModel
            return tile
        }
    }

    private var downloadState: (model: String, fraction: Double)? {
        if case .downloading(let model, let fraction, _) = installer.phase { return (model, fraction) }
        return nil
    }

    private func chooseModel(_ path: String) {
        chosenModel = path
        var settings = ScreenroomTranscriberSettings.load()
        settings.modelPath = path
        settings.save()
    }

    private static let tileTitle: [String: String] = [
        "ggml-small.bin": "Small",
        "ggml-medium.bin": "Medium",
        "ggml-base.en.bin": "Base EN",
        "ggml-small.en.bin": "Small EN",
    ]

    private static func tier(_ name: String) -> Int {
        if name.contains("medium") || name.contains("large") { return 2 }
        if name.contains("small") { return 1 }
        return 0
    }

    private func refresh() {
        transcriber = ScreenroomTranscriberSettings.load()
        models = ScreenroomWhisper.availableModels()
        whisperReady = ScreenroomTranscriberSettings.whisperIsReady
        chosenModel = ScreenroomTranscriberSettings.resolvedModel()?.path ?? ""
    }
}

// MARK: - The page

/// One whisper model as the page draws it.
struct ScreenroomModelTile: Identifiable, Equatable {
    let id: String
    let title: String
    let size: String
    let englishOnly: Bool
    /// 0 base, 1 small, 2 medium: how big the glyph is drawn.
    let tier: Int
    /// Where it is on disk, or nil when it is not here yet.
    let installedPath: String?
    let help: String
    var chosen = false
}

struct ScreenroomPageContent<Setup: View>: View {
    @Binding var agentOn: Bool
    @Binding var agentKind: ScreenroomAgentSettings.Kind
    @Binding var command: String
    let commandIsEdited: Bool
    let revertCommand: () -> Void
    let whisperReady: Bool
    /// Apple's on-device model can write feedback on this Mac.
    let localWriter: Bool
    let localWriterHelp: String
    let models: [ScreenroomModelTile]
    let download: (model: String, fraction: Double)?
    let busy: Bool
    let chooseModel: (String) -> Void
    let downloadModel: (String) -> Void
    let cancelDownload: () -> Void
    @ViewBuilder let setup: () -> Setup
    var compact = false
    @State private var modelDetailsExpanded = false
    @State private var commandExpanded = false

    var body: some View {
        Form {
            Section {
                if !compact {
                    ScreenroomFlowPicture(whisper: whisperReady, agentOn: agentOn,
                                          agentName: agentTitle(agentKind), localWriter: localWriter)
                } else {
                    Text("Who writes the feedback?").font(.headline)
                }
                writerPicker
                writerStatus
            }

            Section("Speech") {
                setup()
                if whisperReady {
                    if compact {
                        Label("Whisper is ready. Audio is transcribed on this Mac.", systemImage: "checkmark.circle")
                            .foregroundStyle(Brand.text)
                        DisclosureGroup("Choose another speech model", isExpanded: $modelDetailsExpanded) {
                            modelPicker
                        }
                    } else {
                        modelPicker
                    }
                    if let download { downloadRow(download) }
                }
            }

            // Hidden, not greyed, while the agent is off: "This Mac" has no
            // agent to pick or command to run.
            if agentOn {
            Section("Agent") {
                agentPicker
                if compact && agentKind != .custom {
                    DisclosureGroup("Advanced: agent command", isExpanded: $commandExpanded) {
                        commandField
                    }
                } else {
                    commandField
                }
            }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: Who writes the feedback

    private var writerPicker: some View {
        HStack(spacing: 8) {
            ChoiceTile(title: "This Mac", selected: !agentOn, badge: nil) {
                tileSymbol("laptopcomputer", selected: !agentOn)
            } action: { Collapse.animate { agentOn = false } }
            .help(localWriterHelp)

            ChoiceTile(title: "My agent", selected: agentOn, badge: "arrow.up.right") {
                tileSymbol("terminal", selected: agentOn)
            } action: { Collapse.animate { agentOn = true } }
            .help("Hand each presentation to an agent you already run: a bigger model than the one on this Mac, reading the transcript, the stills and your notes.")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var writerStatus: some View {
        if agentOn {
            Label {
                Text("Leaves your Mac \u{00B7} read-only, no video")
            } icon: {
                Image(systemName: "arrow.up.right.circle.fill").foregroundStyle(Brand.net)
            }
            .font(.callout)
            .help("This is the one part of Greenroom that can leave your Mac. It reads a copy of the presentation\u{2019}s folder without the recording, read-only, but what a cloud agent does with a transcript and stills of a named student is between you and it.")
        } else if localWriter {
            StatusBadge(text: "Written on this Mac", tone: .good)
                .help(localWriterHelp)
        } else {
            StatusBadge(text: "Counts and notes only", tone: .waiting)
                .help(localWriterHelp)
        }
    }

    // MARK: Speech

    private var modelPicker: some View {
        HStack(spacing: 8) {
            ForEach(models) { model in
                let here = model.installedPath != nil
                let fetching = download?.model == model.id
                ChoiceTile(title: model.title, selected: model.chosen,
                           badge: here ? nil : "arrow.down.circle") {
                    ModelGlyph(model: model)
                } action: {
                    if let path = model.installedPath { chooseModel(path) }
                    else if !busy { downloadModel(model.id) }
                }
                .opacity(here || fetching ? 1 : 0.7)
                .help(model.help + (here ? "" : " Click to download, \(model.size).") + " Shared with Cues.")
            }
        }
        .padding(.vertical, 4)
    }

    private func downloadRow(_ download: (model: String, fraction: Double)) -> some View {
        HStack(spacing: 8) {
            Text(models.first { $0.id == download.model }?.title ?? download.model)
                .font(.callout)
            ProgressView(value: download.fraction)
            Button("Cancel", action: cancelDownload).controlSize(.small)
        }
    }

    // MARK: Agent

    private var agentPicker: some View {
        HStack(spacing: 8) {
            ForEach(ScreenroomAgentSettings.Kind.allCases) { kind in
                ChoiceTile(title: agentTitle(kind), selected: kind == agentKind, badge: nil) {
                    tileSymbol(agentSymbol(kind), selected: kind == agentKind && agentOn)
                } action: { agentKind = kind }
                .help(agentHelp(kind))
            }
        }
        .padding(.vertical, 4)
    }

    /// Shown rather than hidden in a preference: it is about to run in your
    /// own shell with your own credentials.
    private var commandField: some View {
        HStack(alignment: .top, spacing: 8) {
            TextField("Command", text: $command, prompt: Text("command"), axis: .vertical)
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1...4)
                .help("Runs in your own shell, with your own credentials. $GREENROOM_FOLDER is the read-only copy it works in.")
            if agentKind != .custom {
                Button(action: revertCommand) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .disabled(!commandIsEdited)
                .padding(.top, 2)
                .help(commandIsEdited ? "Edited. Back to the \(agentTitle(agentKind)) default."
                                      : "The \(agentTitle(agentKind)) default")
                .accessibilityLabel("Revert to default")
            }
        }
    }

    // MARK: Pieces

    private func tileSymbol(_ name: String, selected: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(selected ? Brand.green : Color.secondary)
            .frame(height: 32)
    }

    private func agentTitle(_ kind: ScreenroomAgentSettings.Kind) -> String {
        switch kind {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .custom: return "My own"
        }
    }

    private func agentSymbol(_ kind: ScreenroomAgentSettings.Kind) -> String {
        switch kind {
        case .claudeCode: return "asterisk"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .custom: return "terminal"
        }
    }

    private func agentHelp(_ kind: ScreenroomAgentSettings.Kind) -> String {
        switch kind {
        case .claudeCode: return "Anthropic\u{2019}s Claude Code, if you already run it. Read-only tools only."
        case .codex: return "OpenAI\u{2019}s Codex CLI, if you already run it. Read-only sandbox."
        case .custom: return "A command of my own. Whatever you type below is kept."
        }
    }
}


/// Where a presentation goes, in the site's diagram grammar: the dashed box
/// is this Mac, green arrows stay inside it, amber ones cross out of it. The
/// agent is always drawn, dashed and grey while off, so the choice below has
/// a picture of what it changes.
private struct ScreenroomFlowPicture: View {
    let whisper: Bool
    let agentOn: Bool
    let agentName: String
    let localWriter: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let boxRect = CGRect(x: 12, y: 36, width: w * 0.66 - 12, height: h - 44)
            let rowY = boxRect.midY + 8
            let step = boxRect.width / 3
            let xs = (0..<3).map { boxRect.minX + step * (CGFloat($0) + 0.5) }
            let agentX = boxRect.maxX + (w - boxRect.maxX) / 2
            let half: CGFloat = 16

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.06))

                // This Mac.
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Brand.green.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .frame(width: boxRect.width, height: boxRect.height)
                    .offset(x: boxRect.minX, y: boxRect.minY)
                Label("This Mac", systemImage: "laptopcomputer")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.text)
                    .padding(.horizontal, 4)
                    .offset(x: boxRect.minX + 8, y: boxRect.minY + 8)

                // Recording -> transcript (a stream: thick), transcript ->
                // report (one shot: thin). Green: neither leaves.
                arrow(from: CGPoint(x: xs[0] + half + 6, y: rowY),
                      to: CGPoint(x: xs[1] - half - 6, y: rowY), color: Brand.green, width: 3)
                arrow(from: CGPoint(x: xs[1] + half + 6, y: rowY),
                      to: CGPoint(x: xs[2] - half - 6, y: rowY), color: Brand.green, width: 1.5)

                if agentOn {
                    // Out: transcript, stills, notes, over the top of the box.
                    let top = boxRect.minY - 20
                    Path { p in
                        p.move(to: CGPoint(x: xs[1], y: rowY - half - 6))
                        p.addLine(to: CGPoint(x: xs[1], y: top))
                        p.addLine(to: CGPoint(x: agentX, y: top))
                        p.addLine(to: CGPoint(x: agentX, y: rowY - half - 10))
                    }
                    .stroke(Brand.net, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    arrowHead(at: CGPoint(x: agentX, y: rowY - half - 6), pointing: .down,
                              color: Brand.net)
                    // Back: the written feedback, into the report.
                    arrow(from: CGPoint(x: agentX - half - 6, y: rowY),
                          to: CGPoint(x: xs[2] + half + 6, y: rowY), color: Brand.net, width: 1.5)
                }

                node("video.fill", "Recording", at: CGPoint(x: xs[0], y: rowY), active: true)
                    .help("The video stays on this Mac. No agent is given it.")
                node("waveform", whisper ? "Whisper" : "Apple", at: CGPoint(x: xs[1], y: rowY), active: true)
                    .help(whisper
                          ? "Whisper: verbatim, on this Mac, so filler words can be counted. Chosen for you: whichever of the two this Mac has. Either way the audio never leaves it."
                          : "Apple\u{2019}s, until whisper is set up. It tidies speech, so filler words are not counted. Either way the audio never leaves this Mac.")
                node("doc.text.fill", "Report", at: CGPoint(x: xs[2], y: rowY), active: true,
                     badge: !agentOn && localWriter ? "sparkles" : nil)
                    .help(agentOn ? "Counts, your notes, and the agent\u{2019}s feedback."
                          : localWriter ? "Counts, your notes, and feedback written on this Mac."
                          : "Counts and your notes. No written feedback without a model.")
                node("terminal.fill", agentName, at: CGPoint(x: agentX, y: rowY), active: agentOn,
                     dashed: !agentOn)
                    .help(agentOn ? "Reads a read-only copy of the folder, without the recording."
                                  : "Off. Pick \u{201C}My agent\u{201D} to hand it each presentation.")

                PictureChip(text: agentOn ? "LEAVES YOUR MAC" : "STAYS ON THIS MAC",
                            dot: agentOn ? Brand.net : Brand.green)
                    .offset(x: 12, y: 12)
            }
        }
        .frame(height: 140)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(agentOn ? "The presentation is read by your agent, off this Mac"
                                    : "The presentation stays on this Mac")
    }

    private enum Direction { case right, left, down }

    private func node(_ symbol: String, _ title: String, at point: CGPoint, active: Bool,
                      dashed: Bool = false, badge: String? = nil) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(active ? Brand.green : Color.secondary)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(active ? Brand.green.opacity(0.6) : Color.secondary.opacity(0.4),
                                  style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 3] : [])))
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Image(systemName: badge)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Brand.green)
                            .offset(x: 6, y: -6)
                    }
                }
            Text(title)
                .font(.caption)
                .foregroundStyle(active ? .primary : .secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .position(x: point.x, y: point.y + 8)
    }

    private func arrow(from: CGPoint, to: CGPoint, color: Color, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Path { p in
                p.move(to: from)
                p.addLine(to: CGPoint(x: to.x + (to.x > from.x ? -4 : 4), y: to.y))
            }
            .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
            arrowHead(at: to, pointing: to.x > from.x ? .right : .left, color: color)
        }
    }

    private func arrowHead(at tip: CGPoint, pointing: Direction, color: Color) -> some View {
        Path { p in
            let s: CGFloat = 6
            switch pointing {
            case .right:
                p.move(to: tip)
                p.addLine(to: CGPoint(x: tip.x - s * 1.4, y: tip.y - s))
                p.addLine(to: CGPoint(x: tip.x - s * 1.4, y: tip.y + s))
            case .left:
                p.move(to: tip)
                p.addLine(to: CGPoint(x: tip.x + s * 1.4, y: tip.y - s))
                p.addLine(to: CGPoint(x: tip.x + s * 1.4, y: tip.y + s))
            case .down:
                p.move(to: tip)
                p.addLine(to: CGPoint(x: tip.x - s, y: tip.y - s * 1.4))
                p.addLine(to: CGPoint(x: tip.x + s, y: tip.y - s * 1.4))
            }
            p.closeSubpath()
        }
        .fill(color)
    }
}

/// A model as a picture: a globe for multilingual, a letter for English-only,
/// drawn bigger for a bigger model, its size under it.
private struct ModelGlyph: View {
    let model: ScreenroomModelTile

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: model.englishOnly ? "character.bubble" : "globe")
                .font(.system(size: CGFloat(16 + model.tier * 4), weight: .regular))
                .foregroundStyle(model.chosen ? Brand.green : Color.secondary)
                .frame(height: 24)
            Text(model.size)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}
