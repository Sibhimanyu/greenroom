//
//  ScreenroomSettingsTab.swift
//  Greenroom
//
//  One-time setup, kept out of the working flow.
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
//  it, and offering the choice only invited somebody to get it wrong. The row
//  below reports which one will run, as a fact rather than a control.
//
import SwiftUI

struct ScreenroomSettingsTab: View {
    @State private var agent = ScreenroomAgentSettings.load()
    @State private var transcriber = ScreenroomTranscriberSettings.load()
    @State private var whisperReady = ScreenroomTranscriberSettings.whisperIsReady
    @State private var models = ScreenroomWhisper.availableModels()
    @ObservedObject private var installer = WhisperInstaller.shared

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text(whisperReady ? "Whisper" : "Apple")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(whisperReady ? AnyShapeStyle(Brand.text) : AnyShapeStyle(.secondary))
                } label: {
                    SettingLabel(title: "Transcriber",
                                 subtitle: whisperReady
                                 ? "Verbatim, on this Mac. Filler words can be counted."
                                 : "Apple\u{2019}s, until whisper is set up. It tidies speech, so filler words are not counted.")
                }

                // The program and a first model, as buttons, when either is
                // missing. See WhisperInstaller.
                WhisperSetupRows(onChange: refresh)

                if whisperReady {
                    WhisperModelPicker(
                        subtitle: "Multilingual beats English-only on accents, even at the same size. Shared with Cues.")
                }

                // Other sizes, only once whisper works, one line each. It was
                // a paragraph and a curl command per model, which read as a
                // manual rather than a choice.
                if whisperReady {
                    DisclosureGroup("Other models") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(ScreenroomWhisper.offeredModels, id: \.name) { offer in
                                modelLine(offer.name, size: offer.size)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            } header: {
                Text("Speech")
            } footer: {
                Text("Chosen for you: whichever of the two this Mac has. Either way the audio never leaves it.")
            }

            Section {
                Toggle(isOn: Binding(get: { agent.enabled },
                                     set: { agent.enabled = $0; agent.save() })) {
                    SettingLabel(title: "Hand each presentation to my agent",
                                 subtitle: "A bigger model than the one on this Mac, reading the transcript, the stills and your notes.")
                }
                // Greyed out rather than hidden while the agent is off, like
                // the rest of Settings: which agent and what it would run are
                // worth seeing before deciding to hand it anything.
                Group {
                    Picker(selection: Binding(get: { agent.kind }, set: { kind in
                        agent.kind = kind
                        // A named agent always brings its own command back.
                        // It used to keep an edited command across a switch,
                        // so a slip in the Claude Code line followed the
                        // teacher to Codex. Only "a command of my own" keeps
                        // what was typed, because that is the point of it.
                        if kind != .custom { agent.command = kind.defaultCommand }
                        agent.save()
                    })) {
                        ForEach(ScreenroomAgentSettings.Kind.allCases) { Text($0.label).tag($0) }
                    } label: {
                        SettingLabel(title: "Which one", subtitle: "Whatever you already run.")
                    }

                    // Shown rather than hidden in a preference: it is about to
                    // run in your own shell with your own credentials.
                    TextField("command", text: Binding(get: { agent.command },
                                                       set: { agent.command = $0; agent.save() }),
                              axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1...4)
                    if agent.kind != .custom, agent.command != agent.kind.defaultCommand {
                        HStack {
                            Text("Edited from the \(agent.kind.label) default.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Revert to default") {
                                agent.command = agent.kind.defaultCommand
                                agent.save()
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .disabled(!agent.enabled)
            } header: {
                Text("Your agent")
            } footer: {
                Text(agent.enabled
                     ? "This is the one part of Greenroom that can leave your Mac. It reads a copy of the presentation's folder without the recording, read-only, but what a cloud agent does with a transcript and stills of a named student is between you and it."
                     : offFooter)
            }
        }
        .formStyle(.grouped)
        // No width of its own. SettingsView sizes the window (760pt) and
        // every other tab fills it; pinning this one to 520 made it the only
        // tab sitting in half the pane.
        .onAppear { refresh() }
        // A model downloaded from any of the per-model buttons.
        .onChange(of: installer.revision) { _ in refresh() }
    }

    /// What happens with no agent depends on the Mac, so the footer says
    /// which. Below macOS 26, or with Apple Intelligence off, there is no
    /// on-device model to write with, and the report is the counted one.
    private var offFooter: String {
        let model = ScreenroomAnalyst.modelAvailability
        if model.available {
            return "Off. Screenroom writes the report on this Mac, using Apple's on-device model."
        }
        let why: String
        if #available(macOS 26.0, *) {
            why = "Apple's on-device model is not ready here (\(model.reason ?? "not available"))"
        } else {
            why = "Feedback written on this Mac needs macOS 26 with Apple Intelligence"
        }
        return "Off. \(why), so the report has the counts and your notes, with no written feedback. Turn on an agent to have it written."
    }

    /// One model: what it is in a few words, and a button or a tick.
    @ViewBuilder
    private func modelLine(_ name: String, size: String) -> some View {
        let installed = models.contains { $0.url.lastPathComponent == name }
        HStack(spacing: 8) {
            Text(Self.shortName[name] ?? name).font(.callout)
            Text(size).font(.caption).foregroundStyle(.tertiary)
            Spacer()
            if installed {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(Brand.text)
            } else if case .downloading(let model, let fraction, _) = installer.phase, model == name {
                ProgressView(value: fraction).frame(width: 90)
                Button("Cancel") { installer.cancel() }.controlSize(.small)
            } else {
                Button("Download") { installer.download(name) }
                    .controlSize(.small)
                    .disabled(installer.isBusy)
            }
        }
    }

    private static let shortName: [String: String] = [
        "ggml-small.bin": "Small, multilingual (recommended)",
        "ggml-medium.bin": "Medium, multilingual: better, three times slower",
        "ggml-base.en.bin": "Base, English only: fast, weak on accents",
        "ggml-small.en.bin": "Small, English only",
    ]

    private func refresh() {
        transcriber = ScreenroomTranscriberSettings.load()
        models = ScreenroomWhisper.availableModels()
        whisperReady = ScreenroomTranscriberSettings.whisperIsReady
    }
}
