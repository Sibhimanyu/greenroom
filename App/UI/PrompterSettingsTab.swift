//
//  PrompterSettingsTab.swift
//  Greenroom
//
//  Settings → Prompter, and the rows Onboarding borrows from it.
//
//  Below macOS 26 the tab is one sentence: the feature does not exist there
//  and the toggle would be a lie. On 26 it is the switch, the speech model
//  (downloaded here, never during a class), how mentions are found, the
//  YouTube choice, the language, a thirty-second try-out that looks nothing
//  up, and the paragraph that says exactly what leaves the Mac.
//
import SwiftUI

struct PrompterSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                if #available(macOS 26.0, *) {
                    PrompterSetupRows(compact: false)
                    PrompterTryItRows()
                    #if DEBUG
                    PrompterDebugRows()
                    #endif
                    PrompterPrivacyText()
                } else {
                    PrompterUnavailableText()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }
}

/// The one sentence for Macs that cannot run it.
struct PrompterUnavailableText: View {
    var body: some View {
        Text("Prompter needs macOS 26. It listens to your microphone during a class and suggests links for the books, videos, topics and places you mention \u{2014} using Apple\u{2019}s speech and language models, which run on the Mac itself and are not available on this version of macOS. Everything else in Greenroom works as before.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// What leaves, where it goes, and where to read the record of it.
struct PrompterPrivacyText: View {
    var body: some View {
        Text("What leaves this Mac: only the short search phrase Prompter builds \u{2014} a title or a name \u{2014} sent over HTTPS to Google Books and Open Library (books), Wikipedia (topics, people, places) and, if you allow it above, YouTube. Never the audio, never the transcript, never the names of people in the meeting: a name that matches someone in the room is dropped before any request. Every phrase that is sent is written to the status log and to ~/Library/Logs/Greenroom-session.log. The transcript lives in memory for the class and is discarded when it ends. Prompter pauses while you are muted in Zoom, and the menu bar has a Stop for the rest of the class.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// Switch, model, detector, language, YouTube - shared by Settings and the
/// onboarding page. `compact` drops the captions for the wizard.
@available(macOS 26.0, *)
struct PrompterSetupRows: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @ObservedObject private var assets = ModelAssets.shared
    @State private var locales: [Locale] = []
    var compact: Bool

    private var inClass: Bool { coordinator.isRunning || coordinator.virtualCamActive }

    var body: some View {
        Toggle("Listen during classes and suggest links", isOn: $coordinator.prompterEnabled)
        if !compact {
            Text("While a class is live, Prompter turns what you say into text on this Mac and, when you name a book, a video, a topic, a person or a place, offers a link card on the participants panel (or in the menu bar when there is no second display). One click opens it in your main-pane browser; one click sends it to the class chat. Off by default; nothing runs outside a class.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        LabeledContent("Speech model") {
            HStack(spacing: 10) {
                switch assets.status {
                case .downloading(let fraction):
                    ProgressView(value: fraction).frame(width: 120)
                    Text(assets.status.label).font(.caption).foregroundStyle(.secondary)
                case .installed:
                    Label(assets.status.label, systemImage: "checkmark.circle.fill").foregroundStyle(Brand.green)
                case .notDownloaded, .failed:
                    Text(assets.status.label).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                    Button("Download\u{2026}") { download() }
                        .disabled(inClass)
                        .help(inClass ? "Not during a class \u{2014} the model downloads once, from Apple, between classes." : "From Apple, through the system\u{2019}s asset service. A few hundred megabytes, once.")
                case .unsupported, .unknown:
                    Text(assets.status.label).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if !compact {
            Text("Apple\u{2019}s on-device speech model for the language below, fetched once through the system\u{2019}s asset service (the same one Dictation uses) and kept by macOS. It is never downloaded during a class: a Start that finds it missing carries on without Prompter and says so in the status log.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Picker("Language", selection: $coordinator.prompterLocaleIdentifier) {
            Text("System (\(ModelAssets.displayName(Locale.current)))").tag("")
            ForEach(locales, id: \.identifier) { locale in
                Text(ModelAssets.displayName(locale)).tag(locale.identifier)
            }
        }
        .disabled(inClass)
        .onChange(of: coordinator.prompterLocaleIdentifier) { _ in
            Task { await assets.refresh(preferredLocale: coordinator.prompterLocaleIdentifier) }
        }

        LabeledContent("Mentions found by") {
            if FoundationModelsDetector.isAvailable {
                Text("Apple Intelligence (on-device)")
            } else {
                Text("Word patterns \u{2014} \(FoundationModelsDetector.unavailableReason ?? "Apple Intelligence is off")")
                    .foregroundStyle(.secondary)
            }
        }
        if !compact {
            Text("With Apple Intelligence on, Apple\u{2019}s language model on this Mac reads the new sentences and names what could be looked up. Without it, Prompter matches phrases like \u{201C}the book called\u{2026}\u{201D}, \u{201C}a video about\u{2026}\u{201D} and capitalised names \u{2014} fewer cards, same rules. Neither sends a word of speech anywhere.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Toggle("Video links may use YouTube search", isOn: $coordinator.prompterVideoSearch)
        if !compact {
            Text(coordinator.youtubeConnected
                 ? "On: a video mention sends the phrase to the YouTube Data API on your connected Google account and the card is the top result (at most 20 per class \u{2014} it shares the daily quota with uploads). Off: the card is a \u{201C}search YouTube for\u{2026}\u{201D} link that sends nothing until you open it."
                 : "No Google account is connected (Settings \u{2192} YouTube), so video cards are \u{201C}search YouTube for\u{2026}\u{201D} links that send nothing until you open them. Connect an account to get the actual video instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

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
        Divider()
        HStack(spacing: 12) {
            Button(tester.isListening ? "Listening\u{2026}" : "Try it (30 s)") {
                Task { await tester.startTest(seconds: 30, configuration: coordinator.prompterConfiguration()) }
            }
            .disabled(tester.isListening || inClass || !assets.status.isInstalled)
            if tester.isListening {
                Button("Stop") { tester.stop() }
                if tester.isSpeaking {
                    Label("Hearing you", systemImage: "waveform").font(.caption).foregroundStyle(Brand.green)
                }
            }
            if !tester.status.isEmpty {
                Text(tester.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        if tester.isListening || !tester.liveTail.isEmpty {
            Text(tester.liveTail.isEmpty ? "\u{2026}" : tester.liveTail)
                .font(.callout)
                .foregroundStyle(tester.isListening ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
        if !tester.testMentions.isEmpty {
            // Mono eyebrow + prose, the card grammar in miniature.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(tester.testMentions.enumerated()), id: \.offset) { _, mention in
                    HStack(spacing: 8) {
                        Text(mention.kind.eyebrow).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.tertiary)
                        Text(mention.query)
                    }
                }
            }
        }
        Text("Speaks to the microphone for thirty seconds, shows the text as it is recognised and the mentions Prompter would look up \u{2014} but looks nothing up, so nothing leaves the Mac.")
            .font(.caption)
            .foregroundStyle(.secondary)
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
        Divider()
        Text("DEBUG").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.tertiary)
        HStack {
            TextField("Text", text: $text)
            Button("Detect") {
                Task {
                    let mentions = await bench.debugDetect(text, configuration: coordinator.prompterConfiguration())
                    result = mentions.isEmpty ? "no mentions" : mentions.map { "\($0.kind.rawValue): \($0.query) (\(Int($0.confidence * 100))%)" }.joined(separator: "  \u{00B7}  ")
                }
            }
        }
        HStack {
            TextField("Query", text: $query)
            Picker("", selection: $kind) {
                ForEach(Mention.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.frame(width: 100)
            Button("Resolve") {
                Task {
                    await bench.debugResolve(query, kind: kind, configuration: coordinator.prompterConfiguration())
                    result = bench.cards.map { "\($0.source.label): \($0.title) \u{2192} \($0.url.absoluteString) \($0.thumbnail == nil ? "(no image)" : "(image)")" }.joined(separator: "\n")
                    if result.isEmpty { result = "no card - see status log" }
                }
            }
        }
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
        if !bench.liveTail.isEmpty { Text(bench.liveTail).font(.caption) }
        if !result.isEmpty {
            Text(result).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }
}
#endif
