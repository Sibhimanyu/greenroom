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
                // Debug builds get the workbench in place of Try it: the same
                // listening, plus typed sentences, audio files and every step
                // of the pipeline written out. Release builds never compile it.
                #if DEBUG
                CuesWorkbench()
                #else
                CuesTryItRows()
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
        // On the section, not on a zero-height Color.clear.
        //
        // A grouped Form draws its own container around EVERY top-level
        // child, so an invisible view used only to hang .task off still got a
        // rounded empty box drawn around it. A modifier belongs on something
        // already on screen.
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

/// The real pipeline, outside a class: listen, detect, look up, show cards.
///
/// It used to stop at the mentions and say "nothing is looked up", which
/// answers a question nobody was asking. What a teacher wants to know before
/// a class is whether this produces USEFUL CARDS, and finding that out meant
/// teaching one.
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
                        if tester.isSpeaking {
                            Label("Hearing you", systemImage: "waveform")
                                .font(.caption).foregroundStyle(Brand.text)
                        }
                        Button("Stop") { tester.stop() }
                    } else {
                        Button("Start listening") {
                            Task {
                                await tester.startTest(seconds: 120,
                                                       configuration: coordinator.cuesConfiguration(),
                                                       lookUp: true)
                            }
                        }
                        .disabled(inClass || !ready)
                    }
                }
            } label: {
                SettingLabel(title: "Try it",
                             subtitle: tester.status.isEmpty ? readyLine : tester.status)
            }

            if tester.isListening || !tester.liveTail.isEmpty {
                Text(tester.liveTail.isEmpty ? "\u{2026}" : tester.liveTail)
                    .font(.callout)
                    .foregroundStyle(tester.isListening ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // The cards themselves, which is the point of pressing the button.
            ForEach(tester.cards) { card in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(card.kind.eyebrow)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 48, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(card.title).lineLimit(2)
                        Text(card.source.label).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Open") { NSWorkspace.shared.open(card.url) }
                        .controlSize(.small)
                }
            }
        }
    }

    /// Whichever engine is selected has to be ready, not just Apple's.
    private var ready: Bool {
        coordinator.cuesUseWhisper ? CuesWhisperTranscriber.isAvailable : assets.status.isInstalled
    }

    private var readyLine: String {
        guard ready else {
            return coordinator.cuesUseWhisper
                ? "Whisper is not set up on this Mac yet."
                : "Apple\u{2019}s speech model has not finished downloading."
        }
        return "Listens for two minutes and shows the cards it would put up in a class."
    }
}

#if DEBUG
/// Try it and the old Debug rows, as one place to find out why a sentence did
/// or did not become a card. Debug builds only - never in a release.
///
/// Every input goes through the path a class takes. The old "Try a sentence"
/// detected, then looked each mention up again by name and kind alone, which
/// threw away what the detector knew (the category the speaker said) and so
/// tested a pipeline no class runs. Here a typed sentence is appended to the
/// transcript like a spoken one, and the trace shows each step: what was
/// heard, what each detector offered, what was dropped and why, what was
/// sent where, what was held back, and the card that came of it.
@available(macOS 26.0, *)
struct CuesWorkbench: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @ObservedObject private var assets = ModelAssets.shared
    @StateObject private var bench = CuesController()
    @State private var text = "Have you heard of the brand called imago? And moving on to Adobe Photoshop, that is more of an image editing software."
    /// The workbench's own choices. They start from Settings and change
    /// nothing there: trying Apple Intelligence here does not turn it on
    /// for the next class.
    @State private var detector: CuesController.DetectorChoice = .patterns
    @State private var useWhisper = false
    /// Typed text arrives as speech - a word at a time, then the sentence -
    /// so detection starts when it would in a class, not all at once.
    @State private var asSpeech = true
    @State private var wordsPerSecond = 2.5
    @State private var seeded = false

    private var inClass: Bool { coordinator.isRunning || coordinator.virtualCamActive }

    private var ready: Bool {
        useWhisper ? CuesWhisperTranscriber.isAvailable : assets.status.isInstalled
    }

    private func configuration() -> CuesController.Configuration {
        var configuration = coordinator.cuesConfiguration()
        configuration.detectorChoice = detector
        configuration.useWhisper = useWhisper && CuesWhisperTranscriber.isAvailable
        return configuration
    }

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    if bench.isListening {
                        if bench.isSpeaking {
                            Label("Hearing you", systemImage: "waveform")
                                .font(.caption).foregroundStyle(Brand.text)
                        }
                        Button("Stop") { bench.stop() }
                    } else {
                        Button("Listen") {
                            Task {
                                await bench.startTest(seconds: 300,
                                                      configuration: configuration(),
                                                      lookUp: true)
                            }
                        }
                        .disabled(inClass || !ready)
                    }
                    Button("Audio file\u{2026}") { feedAudio() }
                        .disabled(bench.isListening || inClass)
                    Button("Clear") {
                        bench.stop()
                        bench.clearTrace()
                    }
                }
            } label: {
                SettingLabel(title: "Listen, type or play a file",
                             subtitle: bench.status.isEmpty
                                ? "\(detector.rawValue) \u{00B7} \(useWhisper ? "whisper" : "Apple speech") \u{00B7} real lookups"
                                : bench.status)
            }

            Picker(selection: $detector) {
                ForEach(CuesController.DetectorChoice.allCases) { Text($0.rawValue).tag($0) }
            } label: {
                SettingLabel(title: "Detector", subtitle: "For the workbench only. Settings keeps its own choice.")
            }
            Picker(selection: $useWhisper) {
                Text("Apple").tag(false)
                Text("Whisper").tag(true)
            } label: {
                SettingLabel(title: "Speech to text",
                             subtitle: CuesWhisperTranscriber.isAvailable ? "Applies to Listen." : "Whisper is not set up on this Mac.")
            }
            .disabled(!CuesWhisperTranscriber.isAvailable)
            if useWhisper {
                WhisperModelPicker(subtitle: "Shared with Cues and Screenroom.")
            }
            Toggle(isOn: $asSpeech) {
                SettingLabel(title: "Typed text arrives as speech",
                             subtitle: "A word at a time, then the sentence, so detection starts when it would in a class.")
            }
            if asSpeech {
                LabeledContent {
                    Stepper(value: $wordsPerSecond, in: 1...5, step: 0.5) {
                        Text(String(format: "%.1f words a second", wordsPerSecond)).monospacedDigit()
                    }
                } label: {
                    SettingLabel(title: "Speaking pace", subtitle: "Teachers speak at about 2 to 3.")
                }
            }

            HStack {
                TextField("What a teacher might say", text: $text)
                    .labelsHidden()
                    .onSubmit(say)
                Button("Say it", action: say)
                    .keyboardShortcut(.return, modifiers: .command)
            }

            if bench.isListening || !bench.liveTail.isEmpty {
                Text(bench.liveTail.isEmpty ? "\u{2026}" : bench.liveTail)
                    .font(.callout)
                    .foregroundStyle(bench.isListening ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !bench.cards.isEmpty || bench.isListening {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("WHAT THE CLASS DISPLAY SHOWS")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        CuesRailPreview(state: surfaceState)
                            .frame(width: 300, height: 380)
                            .background(Color(nsColor: .windowBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    latencyView
                }
            }

            traceView
        } header: {
            Text("Debug \u{00B7} Cues workbench")
        } footer: {
            Text("Debug builds only. Lookups are real and are sent, exactly as in a class.")
        }
        .onAppear {
            bench.tracing = true
            if !seeded {
                seeded = true
                detector = coordinator.cuesUseModel ? .composite : .patterns
                useWhisper = coordinator.cuesUseWhisper && CuesWhisperTranscriber.isAvailable
            }
        }
        // A different detector or engine is a different pipeline: start over.
        .onChange(of: detector) { _ in bench.stop() }
        .onChange(of: useWhisper) { _ in bench.stop() }
        .onDisappear {
            bench.stop()
            bench.tracing = false
        }
    }

    private var traceView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TRACE")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("\(bench.trace.count) steps").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(traceText, forType: .string)
                }
                .controlSize(.small)
                .disabled(bench.trace.isEmpty)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(bench.trace) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(elapsed(line.at))
                                    .foregroundStyle(.tertiary)
                                Text(line.stage.rawValue.uppercased())
                                    .fontWeight(.semibold)
                                    .foregroundStyle(tint(line.stage))
                                    .frame(width: 52, alignment: .leading)
                                Text(line.text)
                                    .foregroundStyle(line.stage == .drop || line.stage == .skip ? .secondary : .primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 120, maxHeight: 340)
                .onChange(of: bench.trace.count) { _ in
                    if let last = bench.trace.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    /// Every card with where its time went, newest first, and the run's
    /// median and slowest.
    private var latencyView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LATENCY")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            let totals = bench.cards.compactMap { bench.timings[$0.id]?.totalMs }.sorted()
            if !totals.isEmpty {
                Text("median \(seconds(totals[totals.count / 2])) \u{00B7} slowest \(seconds(totals.last ?? 0)) \u{00B7} \(totals.count) card\(totals.count == 1 ? "" : "s")")
                    .font(.system(size: 11, design: .monospaced))
            }
            ForEach(bench.cards) { card in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(card.kind.eyebrow)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text(card.title).lineLimit(1)
                        Spacer(minLength: 0)
                        if let timing = bench.timings[card.id] {
                            Text(seconds(timing.totalMs)).monospacedDigit().fontWeight(.semibold)
                        }
                    }
                    .font(.callout)
                    if let timing = bench.timings[card.id] {
                        Text(breakdown(timing))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func breakdown(_ timing: CueTiming) -> String {
        var parts: [String] = []
        if let speech = timing.speechMs { parts.append("speech \(speech)") }
        parts.append("wait \(timing.waitMs)")
        parts.append("detect \(timing.detectMs)")
        parts.append("lookup \(timing.lookupMs) (\(timing.source))")
        return parts.joined(separator: " \u{00B7} ") + " ms"
    }

    private func seconds(_ ms: Int) -> String { String(format: "%.2f s", Double(ms) / 1000) }

    private var surfaceState: CuesSurfaceState {
        var state = CuesSurfaceState()
        state.listening = bench.isListening || !bench.cards.isEmpty
        state.resolving = bench.isResolving
        state.cards = bench.surfaceCards
        state.open = { NSWorkspace.shared.open($0.url) }
        state.dismiss = { bench.dismiss($0) }
        return state
    }

    private func tint(_ stage: CuesTraceLine.Stage) -> Color {
        switch stage {
        case .card: return Brand.text
        case .drop, .skip: return .secondary
        case .hold: return .orange
        default: return .primary
        }
    }

    private func elapsed(_ date: Date) -> String {
        let start = bench.trace.first?.at ?? date
        let seconds = Int(date.timeIntervalSince(start))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var traceText: String {
        bench.trace.map { "\(elapsed($0.at))\t\($0.stage.rawValue)\t\($0.text)" }.joined(separator: "\n")
    }

    private func say() {
        let typed = text
        let configuration = configuration()
        if asSpeech {
            let pace = wordsPerSecond
            Task { await bench.debugSpeak(typed, wordsPerSecond: pace, configuration: configuration) }
        } else {
            Task { await bench.debugSay(typed, configuration: configuration) }
        }
    }

    private func feedAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await bench.debugFeed(file: url, configuration: configuration()) }
    }
}

/// The class display's own Cues block, hosted here so the workbench shows
/// exactly what the reference display would: the same view, the same state.
@available(macOS 26.0, *)
struct CuesRailPreview: NSViewRepresentable {
    let state: CuesSurfaceState

    final class Host: NSView {
        let block = CuesRailBlock(frame: .zero)
        override init(frame: NSRect) {
            super.init(frame: frame)
            addSubview(block)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            block.place(x: 12, width: bounds.width - 24, top: bounds.height - 4, available: bounds.height - 8)
        }
    }

    func makeNSView(context: Context) -> Host { Host(frame: .zero) }

    func updateNSView(_ host: Host, context: Context) {
        _ = host.block.apply(state)
        host.needsLayout = true
    }
}
#endif
