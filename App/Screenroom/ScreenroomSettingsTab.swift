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
                                 : "Apple's recogniser tidies speech up, so filler words are not counted.")
                }

                if whisperReady {
                    WhisperModelPicker(
                        subtitle: "Multilingual beats English-only on accents, even at the same size. Shared with Cues.")
                }

                DisclosureGroup("Add another model") {
                    VStack(alignment: .leading, spacing: 10) {
                        if !whisperReady {
                            Text("whisper itself is missing. First:")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("brew install whisper-cpp")
                                .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        }
                        ForEach(ScreenroomWhisper.offeredModels, id: \.name) { offer in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(offer.name.replacingOccurrences(of: "ggml-", with: "")
                                        .replacingOccurrences(of: ".bin", with: ""))
                                        .font(.caption.weight(.medium))
                                    Text(offer.size).font(.caption2).foregroundStyle(.tertiary)
                                    if models.contains(where: { $0.url.lastPathComponent == offer.name }) {
                                        Text("installed").font(.caption2).foregroundStyle(Brand.text)
                                    }
                                }
                                Text(offer.note).font(.caption2).foregroundStyle(.secondary)
                                if !models.contains(where: { $0.url.lastPathComponent == offer.name }) {
                                    Text(ScreenroomWhisper.downloadCommand(for: offer.name))
                                        .font(.system(size: 9, design: .monospaced))
                                        .textSelection(.enabled)
                                        .lineLimit(3)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        Button("Look again") { refresh() }
                            .controlSize(.small)
                    }
                    .padding(.top, 4)
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
                if agent.enabled {
                    Picker(selection: Binding(get: { agent.kind }, set: { kind in
                        agent.kind = kind
                        // Only replace a command the teacher has not edited.
                        if kind != .custom,
                           ScreenroomAgentSettings.Kind.allCases.map(\.defaultCommand)
                            .contains(agent.command) {
                            agent.command = kind.defaultCommand
                        }
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
                }
            } header: {
                Text("Your agent")
            } footer: {
                Text(agent.enabled
                     ? "This is the one part of Greenroom that can leave your Mac. It runs read-only in the presentation's folder and cannot change anything in it, but what a cloud agent does with a transcript and stills of a named student is between you and it."
                     : "Off. Screenroom writes the report on this Mac, using Apple's on-device model.")
            }
        }
        .formStyle(.grouped)
        // No width of its own. SettingsView sizes the window (760pt) and
        // every other tab fills it; pinning this one to 520 made it the only
        // tab sitting in half the pane.
        .onAppear { refresh() }
    }

    private func refresh() {
        transcriber = ScreenroomTranscriberSettings.load()
        models = ScreenroomWhisper.availableModels()
        whisperReady = ScreenroomTranscriberSettings.whisperIsReady
    }
}
