//
//  CuesSettingsTab.swift
//  Greenroom
//
//  Settings → Cues, and the rows Onboarding borrows from it.
//
//  Grouped form, the Layout tab's grammar: a title and a one-line subtitle
//  on the left, the control on the right, and nothing that needs a
//  paragraph. The paragraphs live on the Guide and Privacy pages; a switch
//  earns one sentence.
//
//  Below macOS 26 the tab is that one sentence: the feature does not exist
//  there and a toggle would be a lie.
//
import SwiftUI

struct CuesSettingsTab: View {
    var body: some View {
        Form {
            if !CuesAvailability.isReleased {
                CuesComingSoonRows()
            } else if #available(macOS 26.0, *) {
                CuesSetupRows(compact: false)
                CuesTryItRows()
                #if DEBUG
                CuesDebugRows()
                #endif
            } else {
                Section { CuesUnavailableText() }
            }
        }
        .formStyle(.grouped)
    }
}

/// The one sentence for Macs that cannot run it.
struct CuesUnavailableText: View {
    var body: some View {
        Text("Cues needs macOS 26. It listens to your microphone during a class and suggests links for what you mention, using Apple\u{2019}s on-device models. Everything else in Greenroom works as before.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

/// A title with a one-line subtitle, for the leading side of a row.
struct SettingLabel: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Switch, model, detector, language, YouTube - shared by Settings and the
/// onboarding page. `compact` drops the section headers for the wizard.
@available(macOS 26.0, *)
struct CuesSetupRows: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @ObservedObject private var assets = ModelAssets.shared
    @State private var locales: [Locale] = []
    var compact: Bool

    private var inClass: Bool { coordinator.isRunning || coordinator.virtualCamActive }

    var body: some View {
        Section {
            Toggle(isOn: $coordinator.cuesEnabled) {
                SettingLabel(title: "Listen during classes and suggest links",
                             subtitle: "Cards for the tools, words, quotes, books, videos, topics and people you name. Off by default.")
            }
        } header: { if !compact { Text("Cues") } } footer: {
            if !compact {
                Text("Only the short search phrase leaves the Mac \u{2014} to Google Books, Open Library, Wikipedia and, if allowed, YouTube \u{2014} and each one is written to the status log. The audio, the transcript and the names of people in the meeting never leave this Mac; the transcript is saved into the class folder unless you turn that off below.")
            }
        }

        // Three rows, not nine.
        //
        // The tab had grown a row per decision: Apple's model, the language,
        // the engine, the whisper model, the model detector, the transcript,
        // YouTube search. Nine settings between a teacher and "start
        // listening", when eight of them are set once and never touched.
        //
        // What stays visible is what you would change: whether it listens,
        // what it listens with, and which model. The rest is behind a
        // disclosure, which is not hiding it - it is saying it is not a
        // morning decision.
        Section {
            Picker(selection: $coordinator.cuesUseWhisper) {
                Text("Apple").tag(false)
                Text("Whisper").tag(true)
            } label: {
                SettingLabel(title: "Listens with",
                             subtitle: CuesWhisperTranscriber.isAvailable
                             ? "Whisper hears names and titles properly. Apple\u{2019}s is about a second quicker and tidies them away."
                             : "Whisper needs setting up in Settings \u{2192} Screenroom.")
            }
            .pickerStyle(.segmented)
            .disabled(inClass || !CuesWhisperTranscriber.isAvailable)

            if coordinator.cuesUseWhisper, CuesWhisperTranscriber.isAvailable {
                WhisperModelPicker(
                    subtitle: "Bigger hears accents better and takes longer per window. Shared with Screenroom.")
            } else {
                LabeledContent {
                    HStack(spacing: 10) {
                        switch assets.status {
                        case .downloading(let fraction):
                            ProgressView(value: fraction).frame(width: 110)
                            Text(assets.status.label).font(.caption).foregroundStyle(.secondary)
                        case .installed:
                            Label(assets.status.label, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Brand.text)
                        case .notDownloaded, .failed:
                            Text(assets.status.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Button("Download\u{2026}") { download() }
                                .disabled(inClass)
                                .help(inClass ? "Not during a class." : "From Apple, once, through the system\u{2019}s asset service.")
                        case .unsupported, .unknown:
                            Text(assets.status.label).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } label: {
                    SettingLabel(title: "Apple\u{2019}s speech model",
                                 subtitle: "Downloaded once. Never during a class.")
                }
            }

            DisclosureGroup("More") {
                Picker(selection: $coordinator.cuesLocaleIdentifier) {
                    Text("System (\(ModelAssets.displayName(Locale.current)))").tag("")
                    ForEach(locales, id: \.identifier) { locale in
                        Text(ModelAssets.displayName(locale)).tag(locale.identifier)
                    }
                } label: {
                    SettingLabel(title: "Language", subtitle: "What you teach in.")
                }
                .disabled(inClass)
                .onChange(of: coordinator.cuesLocaleIdentifier) { _ in
                    Task { await assets.refresh(preferredLocale: coordinator.cuesLocaleIdentifier) }
                }

                Toggle(isOn: $coordinator.cuesUseModel) {
                    SettingLabel(title: "Also suggest links for things I mention without naming them",
                                 subtitle: FoundationModelsDetector.isAvailable
                                     ? "Apple\u{2019}s language model reads each sentence. Finds much more, and interrupts much more."
                                     : "Needs Apple Intelligence, which is off \u{2014} \(FoundationModelsDetector.unavailableReason ?? "unavailable").")
                }
                .disabled(!FoundationModelsDetector.isAvailable || inClass)

                LabeledContent("Mentions found by") {
                    Text(coordinator.cuesUseModel && FoundationModelsDetector.isAvailable
                         ? "Apple Intelligence" : "Word patterns")
                }

                Toggle(isOn: $coordinator.cuesSaveTranscript) {
                    SettingLabel(title: "Save the transcript and links with the class",
                                 subtitle: "transcript.txt for what was said and cues.txt for what was suggested, in the class folder beside the recording. Off keeps both in memory only.")
                }

                Toggle(isOn: $coordinator.cuesVideoSearch) {
                    SettingLabel(title: "Video links may use YouTube search",
                                 subtitle: coordinator.youtubeConnected
                                     ? "Top result on your connected Google account, up to 20 a class."
                                     : "No Google account connected \u{2014} video cards are search links until then.")
                }
            }

        } header: { if !compact { Text("Listening") } }

        // Run once on appear and again when the switch is turned on.
        Color.clear.frame(height: 0)
            .task {
                locales = await ModelAssets.supportedLocales()
                await assets.refresh(preferredLocale: coordinator.cuesLocaleIdentifier)
            }
            .onChange(of: coordinator.cuesEnabled) { enabled in
                guard enabled, !inClass else { return }
                Task {
                    await assets.refresh(preferredLocale: coordinator.cuesLocaleIdentifier)
                    if assets.status == .notDownloaded { download() }
                }
            }
    }

    private func download() {
        let language = ModelAssets.displayName(assets.resolvedLocale)
        coordinator.log("Cues: downloading the speech model from Apple (\(language))\u{2026}")
        Analytics.feature("prompter_model_download")
        Task {
            await assets.download(preferredLocale: coordinator.cuesLocaleIdentifier)
            switch assets.status {
            case .installed: coordinator.log("Cues: speech model installed (\(language)).")
            case .failed(let why):
                coordinator.log("Cues: speech model download failed \u{2014} \(why)")
                Analytics.failure("prompter_asset")
            default: break
            }
        }
    }
}

/// Thirty seconds of live transcription and detection, no lookups.
@available(macOS 26.0, *)
struct CuesTryItRows: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @ObservedObject private var assets = ModelAssets.shared
    @StateObject private var tester = CuesController()

    private var inClass: Bool { coordinator.isRunning || coordinator.virtualCamActive }

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: 10) {
                    if tester.isListening {
                        Button("Stop") { tester.stop() }
                        if tester.isSpeaking {
                            Label("Hearing you", systemImage: "waveform").font(.caption).foregroundStyle(Brand.green)
                        }
                    } else {
                        Button("Try it (30 s)") {
                            Task { await tester.startTest(seconds: 30, configuration: coordinator.cuesConfiguration()) }
                        }
                        .disabled(inClass || !assets.status.isInstalled)
                    }
                }
            } label: {
                SettingLabel(title: "Try it",
                             subtitle: tester.status.isEmpty ? "Live text and the mentions found. Nothing is looked up." : tester.status)
            }

            if tester.isListening || !tester.liveTail.isEmpty {
                Text(tester.liveTail.isEmpty ? "\u{2026}" : tester.liveTail)
                    .font(.callout)
                    .foregroundStyle(tester.isListening ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !tester.testMentions.isEmpty {
                // Mono eyebrow + prose, the card grammar in miniature.
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(tester.testMentions.enumerated()), id: \.offset) { _, mention in
                        HStack(spacing: 8) {
                            Text(mention.kind.eyebrow)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 48, alignment: .leading)
                            Text(mention.query)
                        }
                    }
                }
            }
        }
    }
}

#if DEBUG
/// Developer paths: each stage of the pipeline on its own, with real inputs.
@available(macOS 26.0, *)
struct CuesDebugRows: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @StateObject private var bench = CuesController()
    @State private var text = "We\u{2019}re reading the book called Charlotte\u{2019}s Web by E. B. White, and I watched a video about spiders."
    @State private var result = ""

    var body: some View {
        // One flow, not four buttons.
        //
        // It was Detect, Resolve, Feed audio file, Inject sample cards and
        // Clear, spread across three rows - five controls to answer one
        // question, which is whether a sentence turns into a card. Detect and
        // Resolve were always used together: a mention nobody could resolve
        // and a card nobody detected are each half an answer.
        //
        // So: type a sentence, press once, see what it found and what it
        // would put on screen. The audio button stays because it is the only
        // way to exercise the transcriber, which is now the part most likely
        // to be wrong.
        Section {
            DisclosureGroup("Try a sentence") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("", text: $text).labelsHidden()
                        Button("Run") { run() }
                        Button("Audio file\u{2026}") { feedAudio() }
                    }
                    if !bench.liveTail.isEmpty {
                        Text(bench.liveTail).font(.caption).foregroundStyle(.secondary)
                    }
                    if !result.isEmpty {
                        Text(result)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 4)
            }
        } header: { Text("Debug") }
    }

    /// Detect, then resolve everything detected. The two halves of the one
    /// question, run together because neither answers it alone.
    private func run() {
        Task {
            let configuration = coordinator.cuesConfiguration()
            let mentions = await bench.debugDetect(text, configuration: configuration)
            guard !mentions.isEmpty else { result = "no mentions"; return }

            var lines = mentions.map {
                "detected  \($0.kind.rawValue): \($0.query)  (\(Int($0.confidence * 100))%)"
            }
            for mention in mentions {
                await bench.debugResolve(mention.query, kind: mention.kind, configuration: configuration)
                if bench.cards.isEmpty {
                    lines.append("  \u{2192} no card \u{2014} see the status log")
                } else {
                    lines.append(contentsOf: bench.cards.map {
                        "  \u{2192} \($0.source.label): \($0.title)"
                    })
                }
            }
            result = lines.joined(separator: "\n")
        }
    }

    private func feedAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        result = ""
        Task { await bench.debugFeed(file: url, configuration: coordinator.cuesConfiguration()) }
    }
}
#endif
