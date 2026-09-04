//
//  PrompterSettingsTab.swift
//  Greenroom
//
//  Settings → Prompter, and the rows Onboarding borrows from it.
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

struct PrompterSettingsTab: View {
    var body: some View {
        Form {
            if #available(macOS 26.0, *) {
                PrompterSetupRows(compact: false)
                PrompterTryItRows()
                #if DEBUG
                PrompterDebugRows()
                #endif
            } else {
                Section { PrompterUnavailableText() }
            }
        }
        .formStyle(.grouped)
    }
}

/// The one sentence for Macs that cannot run it.
struct PrompterUnavailableText: View {
    var body: some View {
        Text("Prompter needs macOS 26. It listens to your microphone during a class and suggests links for what you mention, using Apple\u{2019}s on-device models. Everything else in Greenroom works as before.")
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
struct PrompterSetupRows: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @ObservedObject private var assets = ModelAssets.shared
    @State private var locales: [Locale] = []
    var compact: Bool

    private var inClass: Bool { coordinator.isRunning || coordinator.virtualCamActive }

    var body: some View {
        Section {
            Toggle(isOn: $coordinator.prompterEnabled) {
                SettingLabel(title: "Listen during classes and suggest links",
                             subtitle: "Cards for the tools, words, quotes, books, videos, topics and people you name. Off by default.")
            }
        } header: { if !compact { Text("Prompter") } } footer: {
            if !compact {
                Text("Only the short search phrase leaves the Mac \u{2014} to Google Books, Open Library, Wikipedia and, if allowed, YouTube \u{2014} and each one is written to the status log. The audio, the transcript and the names of people in the meeting never leave this Mac; the transcript is saved into the class folder unless you turn that off below.")
            }
        }

        Section {
            LabeledContent {
                HStack(spacing: 10) {
                    switch assets.status {
                    case .downloading(let fraction):
                        ProgressView(value: fraction).frame(width: 110)
                        Text(assets.status.label).font(.caption).foregroundStyle(.secondary)
                    case .installed:
                        Label(assets.status.label, systemImage: "checkmark.circle.fill").foregroundStyle(Brand.green)
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
                SettingLabel(title: "Speech model", subtitle: "Apple\u{2019}s, downloaded once. Never during a class.")
            }

            Picker(selection: $coordinator.prompterLocaleIdentifier) {
                Text("System (\(ModelAssets.displayName(Locale.current)))").tag("")
                ForEach(locales, id: \.identifier) { locale in
                    Text(ModelAssets.displayName(locale)).tag(locale.identifier)
                }
            } label: {
                SettingLabel(title: "Language", subtitle: "What you teach in.")
            }
            .disabled(inClass)
            .onChange(of: coordinator.prompterLocaleIdentifier) { _ in
                Task { await assets.refresh(preferredLocale: coordinator.prompterLocaleIdentifier) }
            }

            Toggle(isOn: $coordinator.prompterUseModel) {
                SettingLabel(title: "Also suggest links for things I mention without naming them",
                             subtitle: FoundationModelsDetector.isAvailable
                                 ? "Apple\u{2019}s language model reads each sentence. Finds much more, and interrupts much more."
                                 : "Needs Apple Intelligence, which is off \u{2014} \(FoundationModelsDetector.unavailableReason ?? "unavailable").")
            }
            .disabled(!FoundationModelsDetector.isAvailable || inClass)

            LabeledContent("Mentions found by") {
                Text(coordinator.prompterUseModel && FoundationModelsDetector.isAvailable
                     ? "Apple Intelligence" : "Word patterns")
            }

            Toggle(isOn: $coordinator.prompterSaveTranscript) {
                SettingLabel(title: "Save the transcript with the class",
                             subtitle: "A transcript.txt in the class folder, beside the recording. Off keeps the text in memory only.")
            }

            Toggle(isOn: $coordinator.prompterVideoSearch) {
                SettingLabel(title: "Video links may use YouTube search",
                             subtitle: coordinator.youtubeConnected
                                 ? "Top result on your connected Google account, up to 20 a class."
                                 : "No Google account connected \u{2014} video cards are search links until then.")
            }
        } header: { if !compact { Text("How it works") } }

        // Run once on appear and again when the switch is turned on.
        Color.clear.frame(height: 0)
            .task {
                locales = await ModelAssets.supportedLocales()
                await assets.refresh(preferredLocale: coordinator.prompterLocaleIdentifier)
            }
            .onChange(of: coordinator.prompterEnabled) { enabled in
                guard enabled, !inClass else { return }
                Task {
                    await assets.refresh(preferredLocale: coordinator.prompterLocaleIdentifier)
                    if assets.status == .notDownloaded { download() }
                }
            }
    }

    private func download() {
        let language = ModelAssets.displayName(assets.resolvedLocale)
        coordinator.log("Prompter: downloading the speech model from Apple (\(language))\u{2026}")
        Analytics.feature("prompter_model_download")
        Task {
            await assets.download(preferredLocale: coordinator.prompterLocaleIdentifier)
            switch assets.status {
            case .installed: coordinator.log("Prompter: speech model installed (\(language)).")
            case .failed(let why):
                coordinator.log("Prompter: speech model download failed \u{2014} \(why)")
                Analytics.failure("prompter_asset")
            default: break
            }
        }
    }
}

/// Thirty seconds of live transcription and detection, no lookups.
@available(macOS 26.0, *)
struct PrompterTryItRows: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @ObservedObject private var assets = ModelAssets.shared
    @StateObject private var tester = PrompterController()

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
                            Task { await tester.startTest(seconds: 30, configuration: coordinator.prompterConfiguration()) }
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
struct PrompterDebugRows: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @StateObject private var bench = PrompterController()
    @State private var text = "We\u{2019}re reading the book called Charlotte\u{2019}s Web by E. B. White, and I watched a video about spiders."
    @State private var query = "Charlotte\u{2019}s Web"
    @State private var kind: Mention.Kind = .book
    @State private var result = ""

    var body: some View {
        Section {
            LabeledContent("Detect from text") {
                HStack {
                    TextField("", text: $text).labelsHidden().frame(maxWidth: 340)
                    Button("Detect") {
                        Task {
                            let mentions = await bench.debugDetect(text, configuration: coordinator.prompterConfiguration())
                            result = mentions.isEmpty ? "no mentions" : mentions.map { "\($0.kind.rawValue): \($0.query) (\(Int($0.confidence * 100))%)" }.joined(separator: "  \u{00B7}  ")
                        }
                    }
                }
            }
            LabeledContent("Resolve a query") {
                HStack {
                    TextField("", text: $query).labelsHidden()
                    Picker("", selection: $kind) {
                        ForEach(Mention.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                    Button("Resolve") {
                        Task {
                            await bench.debugResolve(query, kind: kind, configuration: coordinator.prompterConfiguration())
                            result = bench.cards.map { "\($0.source.label): \($0.title) \u{2192} \($0.url.absoluteString) \($0.thumbnail == nil ? "(no image)" : "(image)")" }.joined(separator: "\n")
                            if result.isEmpty { result = "no card - see status log" }
                        }
                    }
                }
            }
            LabeledContent("Surfaces") {
                HStack {
                    Button("Feed audio file\u{2026}") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.audio]
                        panel.allowsMultipleSelection = false
                        guard panel.runModal() == .OK, let url = panel.url else { return }
                        Task { await bench.debugFeed(file: url, configuration: coordinator.prompterConfiguration()) }
                    }
                    Button("Inject sample cards") {
                        if let engine = coordinator.prompter {
                            engine.debugInjectSampleCards()
                        } else {
                            coordinator.prompterEngine = PrompterController()
                            coordinator.prompter?.debugInjectSampleCards()
                        }
                        coordinator.prompterTickTask?.cancel()
                        coordinator.prompterTickTask = Task { @MainActor in
                            while !Task.isCancelled {
                                coordinator.syncPrompterSurfaces()
                                try? await Task.sleep(nanoseconds: 1_000_000_000)
                            }
                        }
                    }
                    Button("Clear") { coordinator.stopPrompter() }
                }
            }
            if !bench.liveTail.isEmpty { Text(bench.liveTail).font(.caption) }
            if !result.isEmpty {
                Text(result).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        } header: { Text("Debug") }
    }
}
#endif
