//
//  CuesSettingsTab.swift
//  Greenroom
//
//  Settings -> Cues, and the rows Onboarding borrows from it.
//
//  Built to be looked at, like Webcam. The top of the tab is a picture of
//  what Cues does - a sentence heard, the cards it turns into - with the
//  privacy line drawn into it: green for what stays on the Mac, amber for
//  the one thing that leaves (DESIGN.md, Semantic). Every choice below is a
//  picture of itself (which engine listens, how much it finds), and the
//  sentences that used to sit under each row are hover help.
//
//  `CuesSetupContent` and `CuesTryItContent` take plain bindings and values,
//  not the coordinator, so the tab can be rendered off screen with sample
//  values to check it by eye. `CuesSetupRows` and `CuesTryItRows` are the
//  thin layers that feed them.
//
//  Below macOS 26 the tab is one line: the feature does not exist there and
//  a toggle would be a lie.
//
import SwiftUI

struct CuesSettingsTab: View {
    #if DEBUG
    @State private var workbenchOpen = false
    #endif

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
                Section {
                    Toggle("Show debug workbench", isOn: $workbenchOpen)
                }
                if workbenchOpen { CuesWorkbench() }
                #else
                CuesTryItRows()
                #endif
            } else {
                Section { CuesUnavailableText() }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

/// The one line for Macs that cannot run it. The why is in its help.
struct CuesUnavailableText: View {
    var body: some View {
        StatusBadge(text: "Cues needs macOS 26", tone: .waiting)
            .help("Cues listens to your microphone during a class and suggests links for what you mention, using Apple\u{2019}s on-device models. Everything else in Greenroom works as before.")
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

// MARK: - Setup

/// Switch, engine, detector, language, YouTube - shared by Settings and the
/// onboarding page. `compact` drops the picture and the section headers for
/// the wizard, which has its own paragraph.
@available(macOS 26.0, *)
struct CuesSetupRows: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @ObservedObject private var assets = ModelAssets.shared
    /// Watched so "Listening" turns on the moment whisper lands.
    @ObservedObject private var whisper = WhisperInstaller.shared
    @State private var locales: [Locale] = []
    var compact: Bool

    private var inClass: Bool { coordinator.isRunning || coordinator.stageLive }

    var body: some View {
        CuesSetupContent(
            enabled: $coordinator.cuesEnabled,
            useWhisper: $coordinator.cuesUseWhisper,
            useModel: $coordinator.cuesUseModel,
            languageID: $coordinator.cuesLocaleIdentifier,
            saveTranscript: $coordinator.cuesSaveTranscript,
            videoSearch: $coordinator.cuesVideoSearch,
            compact: compact,
            inClass: inClass,
            whisperReady: CuesWhisperTranscriber.isAvailable,
            modelReady: FoundationModelsDetector.isAvailable,
            modelUnavailableReason: FoundationModelsDetector.unavailableReason,
            youtubeConnected: coordinator.youtubeConnected,
            speechModel: assets.status,
            systemLanguage: ModelAssets.displayName(Locale.current),
            languages: locales.map { CuesLanguage(id: $0.identifier, name: ModelAssets.displayName($0)) },
            download: download,
            appear: {
                locales = await ModelAssets.supportedLocales()
                await assets.refresh(preferredLocale: coordinator.cuesLocaleIdentifier)
            },
            languageChanged: {
                Task { await assets.refresh(preferredLocale: coordinator.cuesLocaleIdentifier) }
            },
            enabledChanged: { enabled in
                guard enabled, !inClass else { return }
                Task {
                    await assets.refresh(preferredLocale: coordinator.cuesLocaleIdentifier)
                    if assets.status == .notDownloaded { download() }
                }
            },
            whisperSetup: { WhisperSetupRows() },
            whisperModel: { WhisperModelPicker(subtitle: "Also used when you analyse a session.") })
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

/// A language the transcriber can do, as the picker shows it.
struct CuesLanguage: Identifiable, Hashable {
    let id: String
    let name: String
}

/// The setup rows themselves, fed plain values.
@available(macOS 26.0, *)
struct CuesSetupContent<WhisperSetup: View, WhisperModel: View>: View {
    @Binding var enabled: Bool
    @Binding var useWhisper: Bool
    @Binding var useModel: Bool
    @Binding var languageID: String
    @Binding var saveTranscript: Bool
    @Binding var videoSearch: Bool
    let compact: Bool
    let inClass: Bool
    /// Whisper's program and a model are both on this Mac.
    let whisperReady: Bool
    /// Apple Intelligence is on and its model is ready.
    let modelReady: Bool
    let modelUnavailableReason: String?
    let youtubeConnected: Bool
    let speechModel: ModelAssets.Status
    let systemLanguage: String
    let languages: [CuesLanguage]
    let download: () -> Void
    let appear: () async -> Void
    let languageChanged: () -> Void
    let enabledChanged: (Bool) -> Void
    @ViewBuilder let whisperSetup: () -> WhisperSetup
    @ViewBuilder let whisperModel: () -> WhisperModel

    /// What is actually in use, which is what the tiles show: Whisper picked
    /// on a Mac that has since lost it listens with Apple's.
    private var listensWithWhisper: Bool { useWhisper && whisperReady }
    private var findsEverything: Bool { useModel && modelReady }

    var body: some View {
        Section {
            if !compact {
                CuesPicture(on: enabled)
            }
            Toggle(isOn: $enabled.animatedCollapse()) {
                Text("Suggest links while I teach")
            }
            .help("Listens during classes and offers cards for the tools, words, quotes, books, videos, topics and people you name. Off by default.")
        } header: { if !compact { Text("Cues") } }
        // On the section, not on a zero-height Color.clear.
        //
        // A grouped Form draws its own container around EVERY top-level
        // child, so an invisible view used only to hang .task off still got a
        // rounded empty box drawn around it. A modifier belongs on something
        // already on screen.
        .task { await appear() }
        .onChange(of: enabled) { enabledChanged($0) }
        .onChange(of: languageID) { _ in languageChanged() }

        // Three groups, each a picture or a short row.
        //
        // The tab had grown a row per decision, each with a sentence under
        // it. What you would change - what listens and how much it finds -
        // is drawn; what is set once is a short row under More.
        //
        // Hidden while Cues itself is off (owner rule: a switch that is off
        // takes what depends on it away, it does not grey it). The values are
        // kept, so turning Cues on finds them as they were. Try it stays,
        // because it is how a teacher decides whether to turn Cues on.
        if enabled {
        Section {
            HStack(spacing: 8) {
                ChoiceTile(title: "Apple", selected: !listensWithWhisper, badge: nil) {
                    EngineGlyph(symbol: "apple.logo", selected: !listensWithWhisper)
                } action: { useWhisper = false }
                .help("Apple\u{2019}s speech model. About a second quicker, and tidies names and titles away.")
                ChoiceTile(title: "Whisper", selected: listensWithWhisper,
                           badge: whisperReady ? nil : "arrow.down.circle") {
                    EngineGlyph(symbol: "waveform", selected: listensWithWhisper)
                } action: { useWhisper = true }
                .disabled(!whisperReady)
                .help(whisperReady
                      ? "Hears names and titles properly."
                      : "Hears names and titles properly. Set it up below, once.")
            }
            .padding(.vertical, 4)
            .disabled(inClass)

            // The setup itself, here, rather than a pointer to another tab
            // that only offered Terminal commands.
            if !whisperReady, !inClass {
                whisperSetup()
            }

            if listensWithWhisper {
                whisperModel()
                    .help("Bigger hears accents better and takes longer per window. Also used when you analyse a session.")
            } else {
                LabeledContent {
                    speechModelState
                } label: {
                    Label("Speech model", systemImage: "cpu")
                }
                .help("Apple\u{2019}s, downloaded once through the system\u{2019}s asset service. Never during a class.")
            }
            HStack(spacing: 8) {
                ChoiceTile(title: "Named things", selected: !findsEverything, badge: nil) {
                    SentenceGlyph(everything: false, selected: !findsEverything)
                } action: { useModel = false }
                .help("Word patterns catch the books, tools, people, words and quotes you name. Quick and quiet.")
                ChoiceTile(title: "Everything", selected: findsEverything,
                           badge: modelReady ? "sparkles" : "exclamationmark.triangle") {
                    SentenceGlyph(everything: true, selected: findsEverything)
                } action: { useModel = true }
                .disabled(!modelReady)
                .help(modelReady
                      ? "Also things you mention without naming them. Apple\u{2019}s language model reads each sentence: finds much more, and interrupts much more."
                      : "Needs Apple Intelligence, which is off \u{2014} \(modelUnavailableReason ?? "unavailable").")
            }
            .padding(.vertical, 4)
            .disabled(inClass)

            if !modelReady {
                StatusBadge(text: "Everything needs Apple Intelligence", tone: .waiting)
                    .help(modelUnavailableReason ?? "Apple Intelligence is unavailable on this Mac.")
            }
        } header: { if !compact { Text("Listening and suggestions") } }

        Section {
            Picker(selection: $languageID) {
                Text("System (\(systemLanguage))").tag("")
                ForEach(languages) { language in
                    Text(language.name).tag(language.id)
                }
            } label: {
                Label("Language", systemImage: "globe")
            }
            .help("What you teach in.")
            .disabled(inClass)

            Toggle(isOn: $saveTranscript) {
                Label("Save the transcript", systemImage: "doc.text")
            }
            .help("transcript.txt for what was said and cues.txt for what was suggested, in the class folder beside the recording. Off keeps both in memory only.")

            Toggle(isOn: $videoSearch) {
                HStack(spacing: 6) {
                    // Amber: this is a search that leaves the Mac.
                    Label {
                        Text("Search YouTube for videos")
                    } icon: {
                        Image(systemName: "play.rectangle").foregroundStyle(Brand.netText)
                    }
                    if !youtubeConnected {
                        Text("No account").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .help(youtubeConnected
                  ? "Top result on your connected Google account, up to 20 a class."
                  : "No Google account connected \u{2014} video cards are search links until then.")
        } header: { if !compact { Text("More") } }
        }
    }

    /// Apple's speech model, as a state and at most one button.
    @ViewBuilder private var speechModelState: some View {
        HStack(spacing: 8) {
            switch speechModel {
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 110)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            case .installed:
                StatusBadge(text: "Installed", tone: .good)
            case .notDownloaded:
                StatusBadge(text: "Not downloaded", tone: .waiting)
                downloadButton
            case .failed(let why):
                StatusBadge(text: "Download failed", tone: .problem).help(why)
                downloadButton
            case .unsupported:
                StatusBadge(text: "Language not supported", tone: .problem)
            case .unknown:
                StatusBadge(text: "Checking\u{2026}", tone: .waiting)
            }
        }
    }

    private var downloadButton: some View {
        Button("Download\u{2026}") { download() }
            .disabled(inClass)
            .help(inClass ? "Not during a class." : "From Apple, once, through the system\u{2019}s asset service.")
    }
}

// MARK: - Try it

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

    private var inClass: Bool { coordinator.isRunning || coordinator.stageLive }

    var body: some View {
        CuesTryItContent(
            isListening: tester.isListening,
            isSpeaking: tester.isSpeaking,
            status: tester.status,
            heard: tester.heardSoFar,
            cards: tester.cards,
            canStart: !inClass && ready,
            notReady: ready ? nil
                : (coordinator.cuesUseWhisper ? "Whisper not set up" : "Speech model not ready"),
            start: {
                Task {
                    await tester.startTest(seconds: 120,
                                           configuration: coordinator.cuesConfiguration(),
                                           lookUp: true)
                }
            },
            stop: { tester.finishTest() },
            open: { NSWorkspace.shared.open($0.url) })
    }

    /// Whichever engine is selected has to be ready, not just Apple's.
    private var ready: Bool {
        coordinator.cuesUseWhisper ? CuesWhisperTranscriber.isAvailable : assets.status.isInstalled
    }
}

/// Try it, fed plain values.
@available(macOS 26.0, *)
struct CuesTryItContent: View {
    let isListening: Bool
    let isSpeaking: Bool
    /// The tester's own line while it runs or after it stops; empty before.
    let status: String
    let heard: String
    let cards: [CueCard]
    let canStart: Bool
    /// Why it cannot start yet, in a few words, or nil when it can.
    let notReady: String?
    let start: () -> Void
    let stop: () -> Void
    let open: (CueCard) -> Void

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    if isListening {
                        if isSpeaking {
                            Label("Hearing you", systemImage: "waveform")
                                .font(.caption).foregroundStyle(Brand.text)
                        }
                        Button("Stop", action: stop)
                    } else {
                        Button(action: start) {
                            Label("Start listening", systemImage: "mic.fill")
                        }
                        .disabled(!canStart)
                    }
                }
            } label: {
                if !status.isEmpty {
                    Text(status).foregroundStyle(.secondary).lineLimit(2)
                } else if let notReady {
                    StatusBadge(text: notReady, tone: .waiting)
                } else {
                    Label("Two minutes, real cards", systemImage: "timer")
                }
            }
            .help("Listens for two minutes and shows the cards it would put up in a class. Lookups are real.")

            if isListening || !heard.isEmpty {
                CuesHeardText(text: heard, listening: isListening)
            }

            // The cards themselves, which is the point of pressing the button.
            ForEach(cards) { card in
                HStack(spacing: 12) {
                    CardThumb(kind: card.kind)
                    VStack(alignment: .leading, spacing: 2) {
                        Eyebrow(text: "\(card.kind.eyebrow) \u{00B7} \(card.source.label.uppercased())")
                        Text(card.title).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Button { open(card) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.borderless)
                        .help("Open \(card.url.host ?? "the link")")
                        .accessibilityLabel("Open")
                }
            }
        } header: { Text("Try it") }
    }
}

// MARK: - Pictures

/// What Cues does, drawn: a sentence heard on this Mac, the search phrase
/// that leaves it, and the cards that come back. Greyed while Cues is off.
private struct CuesPicture: View {
    let on: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(on ? Brand.green : Color.secondary)
                    Waveform(on: on)
                }
                Text("\u{201C}\u{2026}as Kahneman puts it in Thinking, Fast and Slow\u{2026}\u{201D}")
                    .font(.callout).italic()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label("On this Mac", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // The one thing that leaves, in the colour for leaving.
            VStack(spacing: 4) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 16, weight: .semibold))
                Text("PHRASE")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .kerning(0.8)
            }
            .foregroundStyle(Brand.netText)
            .frame(width: 56)

            VStack(spacing: 8) {
                SampleCard(kind: .book, source: "OPEN LIBRARY", title: "Thinking, Fast and Slow")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.top, 32)
        .padding(.bottom, 8)
        .saturation(on ? 1 : 0)
        .opacity(on ? 1 : 0.75)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.08)))
        .overlay(alignment: .topLeading) {
            PictureChip(text: on ? "ON" : "OFF", dot: on ? Brand.green : Color.white.opacity(0.6))
                .padding(10)
        }
        .padding(.vertical, 4)
        .help("Only the short search phrase leaves the Mac \u{2014} to Google Books, Open Library, Wikipedia and, if allowed, YouTube \u{2014} and each one is written to the status log. The audio, the transcript and the names of people in the meeting never leave this Mac; the transcript is saved into the class folder unless you turn that off under More.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cues turns what you say into link cards. Audio stays on this Mac; only the search phrase is sent.")
    }
}

/// A row of bars, the shape of someone talking.
private struct Waveform: View {
    let on: Bool
    private static let levels: [CGFloat] = [0.35, 0.7, 1, 0.55, 0.85, 0.4, 0.95, 0.6, 0.3, 0.5, 0.75, 0.35]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(Self.levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(on ? Brand.green : Color.secondary.opacity(0.5))
                    .frame(width: 3, height: 4 + 16 * level)
            }
        }
        .frame(height: 20)
    }
}

/// A cue card as the class display draws it, at rest.
private struct SampleCard: View {
    let kind: Mention.Kind
    let source: String
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            CardThumb(kind: kind)
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow(text: "\(kind.eyebrow) \u{00B7} \(source)")
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.2)))
    }
}

/// The kind's glyph in a small square, where a card's thumbnail goes.
private struct CardThumb: View {
    let kind: Mention.Kind

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
            .accessibilityHidden(true)
    }

    /// The class display's placeholders (CueCardView), so the two agree.
    private var symbol: String {
        switch kind {
        case .book: return "book.closed"
        case .video: return "play.rectangle"
        case .topic: return "text.book.closed"
        case .person: return "person"
        case .place: return "mappin.and.ellipse"
        case .thing: return "cube"
        case .word: return "character.book.closed"
        case .quote: return "quote.opening"
        }
    }
}

/// Mono, upper case, tracked: the card eyebrow (DESIGN.md, Typography).
private struct Eyebrow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .kerning(0.8)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }
}

/// An engine's tile picture: its symbol, green when it is the one listening.
private struct EngineGlyph: View {
    let symbol: String
    let selected: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(selected ? Brand.green : Color.secondary)
            .frame(height: 32)
    }
}

/// A sentence as grey bars, with what gets a card in green: one named thing,
/// or several things for the language model.
private struct SentenceGlyph: View {
    let everything: Bool
    let selected: Bool

    /// Widths of the words on two lines, and which ones light up.
    private static let lines: [[CGFloat]] = [[14, 22, 10, 26], [18, 12, 24, 16]]
    private var lit: Set<[Int]> {
        everything ? [[0, 1], [0, 3], [1, 2]] : [[0, 3]]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<Self.lines.count, id: \.self) { line in
                HStack(spacing: 4) {
                    ForEach(0..<Self.lines[line].count, id: \.self) { word in
                        let on = lit.contains([line, word])
                        Capsule()
                            .fill(on ? (selected ? Brand.green : Color.secondary.opacity(0.7))
                                     : Color.secondary.opacity(0.25))
                            .frame(width: Self.lines[line][word], height: 7)
                    }
                }
            }
        }
        .frame(height: 32)
        .accessibilityHidden(true)
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

    private var inClass: Bool { coordinator.isRunning || coordinator.stageLive }

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
                WhisperModelPicker(subtitle: "Shared with Cues and Analyse.")
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

            if bench.isListening || !bench.heardSoFar.isEmpty {
                CuesHeardText(text: bench.heardSoFar, listening: bench.isListening)
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

/// Everything Try it has heard, in a box that scrolls and keeps up with the
/// newest words. It showed the class display's last-few-sentences view, so
/// the start of what the teacher said vanished while they were still reading
/// it back.
@available(macOS 26.0, *)
struct CuesHeardText: View {
    let text: String
    let listening: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text.isEmpty ? "\u{2026}" : text)
                        .font(.callout)
                        .foregroundStyle(listening ? .primary : .secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .frame(minHeight: 44, maxHeight: 220)
            .onChange(of: text) { _ in
                guard listening else { return }
                proxy.scrollTo("end", anchor: .bottom)
            }
        }
    }
}
