//
//  CuesController.swift
//  Greenroom
//
//  The pipeline, end to end, for one session: microphone → speech → text →
//  mentions → lookups → cards. Owned by the coordinator between the session
//  going live and End Session, and by nothing else - there is no Cues at
//  launch, none between classes, none in the background.
//
//  What it promises, and the code that keeps each promise:
//    - Only finalised sentences are detected on (`handle(.final)`); volatile
//      text goes to the Settings test panel and nowhere else.
//    - The rolling window used for detection is a struct in memory, released
//      in `stop()`. The FULL transcript is written to the class folder only
//      when the teacher asks for it (Settings -> Cues), and the log says
//      plainly which of the two happened.
//    - Every query that leaves is logged before the card exists (`resolve`).
//    - A student's name never becomes a query: the roster filter runs inside
//      both detectors, and a collision is logged as skipped.
//    - Muted in Zoom means paused: `setPaused` drops results at the door.
//
import AppKit
import AVFoundation
import Foundation
import Speech

/// How long one card took, from the end of the sentence to the screen.
struct CueTiming: Hashable {
    /// First partial words to the finished sentence: the transcriber's share.
    /// Nil for typed text, which arrives finished.
    var speechMs: Int?
    /// The finished sentence waiting for a detector pass to start.
    var waitMs: Int
    var detectMs: Int
    var lookupMs: Int
    /// Sentence finished to card on screen.
    var totalMs: Int
    var source: String
}

/// One step of the pipeline, for the Debug workbench. Recorded only while a
/// workbench is watching; a class never turns it on.
struct CuesTraceLine: Identifiable, Hashable {
    enum Stage: String {
        case heard, detect, drop, name, repair, lookup, hold, note, card, skip
    }
    let id = UUID()
    let at = Date()
    let stage: Stage
    let text: String
}

@available(macOS 26.0, *)
@MainActor
final class CuesController: ObservableObject {

    #if DEBUG
    enum DetectorChoice: String, CaseIterable, Identifiable {
        case patterns = "Word patterns"
        case composite = "Patterns, then Apple Intelligence"
        case model = "Apple Intelligence only"
        var id: String { rawValue }
    }
    #endif

    struct Configuration {
        var localeIdentifier = ""
        var videoSearch = true
        var youtubeToken: (() async throws -> String)?
        var rosterNames: () -> [String] = { [] }
        var log: (String) -> Void = { _ in }
        /// A ceiling on outbound lookups per minute, whatever the detector
        /// offers. A class stays quiet; the bench is allowed to be busier.
        /// Twelve, up from six. Six was set when the rail showed whatever the
        /// last lookup produced; the rail now holds three slots and cycles
        /// eight cards through them, so it has somewhere to put the extra
        /// results and a thin minute starves it.
        var lookupsPerMinute = 12
        /// Settings -> Cues -> "Also suggest links for things I mention
        /// without naming them". Off by default: see chooseDetector.
        var useModelDetector = false
        #if DEBUG
        /// Debug workbench only: run exactly this detector, whatever the
        /// setting says. Nil in a class; absent from release builds.
        var detectorChoice: DetectorChoice?
        #endif
        /// Listen through whisper rather than Apple's recogniser. See
        /// CuesWhisperTranscriber for what it buys and what it costs.
        var useWhisper = false
        /// Where to write the class transcript, or nil to keep it in memory
        /// only. Set to a file inside the session's folder when Settings ->
        /// Cues -> "Save the transcript with the class" is on.
        var transcriptFile: URL?
        /// Where to write the links Cues offered. Separate from the
        /// transcript because they answer different questions - one is what
        /// was said, the other is what the class was offered - and because a
        /// sparse transcript makes the two indistinguishable when they share
        /// a file: on a class the speech model barely finalises, every line
        /// of the transcript happens to be a line that produced a link.
        var linksFile: URL?
    }

    @Published private(set) var isListening = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var stoppedForClass = false
    @Published private(set) var isResolving = false
    /// Newest first. Eight kept, five shown.
    @Published private(set) var cards: [CueCard] = []
    @Published private(set) var unseenCount = 0
    /// The Settings "Try it" readout: recent finals plus the live tail.
    @Published private(set) var liveTail = ""
    /// Mentions found during a test run, for the same panel.
    @Published private(set) var testMentions: [Mention] = []
    @Published private(set) var status = ""
    private(set) var detectorName = ""
    private(set) var detectorCode = ""

    private var configuration = Configuration()
    /// Links written to the prompts file this session, for the closing line.
    /// Links offered this class, cumulative.
    ///
    /// NOT `cards.count`: that is a display window of at most `keepCards` that
    /// also drops anything older than `cardLifetime`, so it stops climbing a
    /// few minutes into a lesson. This is what the menu bar reports and what
    /// the closing log line has always counted.
    @Published private(set) var linksFound = 0
    /// Where the shown window starts in `cards`. The rail has three slots and
    /// keeps eight, so without this the older five were written to the file
    /// and never seen.
    private var rotationOffset = 0
    private var lastRotation = Date()
    /// Slow enough to read a card and reach for it, fast enough that eight
    /// cards come round inside a minute.
    private let rotateEvery: TimeInterval = 8

    /// `cards` rotated to the current window. A new card resets the rotation,
    /// so the thing just said is always the thing at the top.
    var visibleCards: [CueCard] {
        guard rotationOffset > 0, rotationOffset < cards.count else { return cards }
        return Array(cards[rotationOffset...]) + Array(cards[..<rotationOffset])
    }
    private var transcript = RollingTranscript()
    private var transcriber: Transcriber?
    private var whisperTranscriber: CuesWhisperTranscriber?
    /// For the status log, so a class's transcript can be read knowing what
    /// produced it.
    private(set) var transcriberName = "Apple"
    private var detector: MentionDetector = HeuristicDetector()
    private let resolver = LinkResolver()
    private var eventTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var detectTask: Task<Void, Never>?
    private var dismissedKeys: Set<String> = []
    /// Names said in this class, so a later mishearing of one is searched as
    /// the name. See CuesVocabulary.
    private var vocabulary = CuesVocabulary()
    /// Names people gave for themselves ("my name is Sibi"). They join the
    /// roster for the rest of the session: the teacher is not in their own
    /// roster, and a Try-it run has no roster at all.
    private var spokenNames: [String] = []
    /// Mentions the per-minute brake held back, asked again when there is
    /// room. They used to be dropped: a Try-it run lost "Adobe Photoshop"
    /// because the model had spent the minute on fragments.
    private var heldBack: [(mention: Mention, at: Date, heardAt: Date)] = []

    // MARK: Timing
    //
    // Kept in every build because it costs three dates per sentence; only the
    // Debug workbench shows it.

    /// When the words of the sentence now being spoken first appeared.
    private var utteranceStart: Date?
    /// The earliest finished sentence no detector has read yet.
    private var pendingHeardAt: Date?
    private var lastSpeechMs: Int?
    @Published private(set) var timings: [UUID: CueTiming] = [:]

    // MARK: Trace (the Debug workbench only)

    @Published private(set) var trace: [CuesTraceLine] = []
    /// Off everywhere except the Debug workbench, which is compiled out of
    /// release builds. While off, `note` returns at once.
    var tracing = false {
        didSet {
            guard tracing != oldValue else { return }
            if tracing {
                let sink: (String) -> Void = { [weak self] line in
                    Task { @MainActor in self?.note(.drop, line) }
                }
                HeuristicDetector.traceDrop = sink
                if #available(macOS 26.0, *) { FoundationModelsDetector.traceDrop = sink }
            } else {
                HeuristicDetector.traceDrop = nil
                if #available(macOS 26.0, *) { FoundationModelsDetector.traceDrop = nil }
            }
        }
    }

    func note(_ stage: CuesTraceLine.Stage, _ text: String) {
        guard tracing else { return }
        trace.append(CuesTraceLine(stage: stage, text: text))
        if trace.count > 600 { trace.removeFirst(trace.count - 600) }
    }

    func clearTrace() { trace.removeAll() }
    private var lastDetection = Date.distantPast
    private var restartAttempted = false
    private var lookupsInFlight = 0
    /// Listening outside a class, WITHOUT looking anything up.
    ///
    /// Kept as the quiet mode, for checking that speech becomes text and
    /// text becomes mentions. `startTest(lookUp: true)` is the loud one - it
    /// runs the whole pipeline and makes real cards, which is the only way
    /// to answer "would this have helped in a class" without teaching one.
    private var testMode = false
    /// Detector chosen and resolver configured, so a typed sentence can go
    /// straight into the pipeline. See `debugSay`.
    private var pipelineReady = false
    private var startedAt = Date()

    /// Twelve retained, three shown at a time, cycled. Was eight, which the
    /// longer card lifetime would otherwise throw away.
    private let keepCards = 12
    /// Thirty minutes, up from ten.
    ///
    /// Ten assumed links arrive faster than they age out. On a real class they
    /// do not: 5 Sep produced 13 lookups in 15 minutes, so cards expired faster
    /// than they were replaced and the rail sat on one. Three visible slots are
    /// only ever full if what fills them survives long enough to be joined.
    private let cardLifetime: TimeInterval = 1800
    /// Detection cadence: every 8 s if there is anything new, or as soon as a
    /// final sentence lands and at least 6 new words are waiting.
    private let detectEvery: TimeInterval = 8
    private let detectMinWords = 6
    /// Lookups allowed in one class. Eighty, up from thirty: thirty was a
    /// ceiling on a surface that showed five cards and kept eight, and a
    /// 45-minute class hit it before the halfway point.
    private let sessionLookupCap = 80

    /// What the surfaces draw: the rotated window, capped at what a rail can
    /// hold. The full list stays in `cards` so the rotation has somewhere to
    /// rotate through and the "+N older" count stays honest.
    var surfaceCards: [CueCard] { Array(visibleCards.prefix(CuesRailBlock.maxCards)) }

    // MARK: Lifecycle

    /// Starts listening for a class. Returns false (having logged why) when
    /// the model is not installed or the microphone is unavailable.
    @discardableResult
    func start(configuration: Configuration) async -> Bool {
        guard !isListening else { return true }
        self.configuration = configuration
        stoppedForClass = false
        testMode = false
        startedAt = Date()
        await resolver.reset()
        await resolver.configure(.init(sessionCap: sessionLookupCap,
                                       lookupsPerMinute: configuration.lookupsPerMinute,
                                       videoSearchEnabled: configuration.videoSearch,
                                       youtubeToken: configuration.youtubeToken))

        let locale = await Transcriber.resolvedLocale(preferred: configuration.localeIdentifier)
        let status = await AssetInventory.status(forModules: [Transcriber.makeTranscriber(locale: locale)])
        guard status == .installed else {
            configuration.log("Cues skipped \u{2014} the speech model isn't downloaded yet. Settings (\u{2318},) \u{2192} Cues \u{2192} Download.")
            Analytics.failure("prompter_asset")
            return false
        }

        chooseDetector()
        guard await startPipeline(input: nil, locale: locale) else { return false }

        configuration.log(configuration.transcriptFile == nil
                          ? "Cues: listening to your microphone. Speech becomes text on this Mac; the text stays in memory."
                          : "Cues: listening to your microphone. Speech becomes text on this Mac and is saved to this class\u{2019}s folder.")
        configuration.log(detector is HeuristicDetector
                          ? "Cues: mentions found by word patterns."
                          : "Cues: mentions found by Apple Intelligence (on-device) \u{2014} more suggestions, more wrong ones.")
        Analytics.feature("prompter_listen", source: detectorCode)
        return true
    }

    /// Idempotent. Synchronous from the caller's view: the pipeline is torn
    /// down on its own, and nothing else may read the transcript after this.
    func stop(reason: String? = nil) {
        let wasListening = isListening || transcriber != nil
        eventTask?.cancel()
        eventTask = nil
        tickTask?.cancel()
        tickTask = nil
        detectTask?.cancel()
        detectTask = nil
        if let transcriber {
            self.transcriber = nil
            Task { await transcriber.stop() }
            Task { await whisperTranscriber?.stop() }
        }
        let count = transcript.totalFinalized
        let saved = configuration.transcriptFile
        let links = linksFound
        let savedLinks = links > 0 ? configuration.linksFile : nil
        linksFound = 0
        transcript.reset()
        isListening = false
        isSpeaking = false
        isPaused = false
        isResolving = false
        liveTail = ""
        cards.removeAll()
        unseenCount = 0
        dismissedKeys.removeAll()
        vocabulary.reset()
        spokenNames.removeAll()
        heldBack.removeAll()
        pipelineReady = false
        timings.removeAll()
        utteranceStart = nil
        pendingHeardAt = nil
        if wasListening, !testMode {
            if let reason {
                configuration.log(reason)
            } else if let saved {
                configuration.log("Cues: stopped. Transcript saved (\(count) sentence\(count == 1 ? "" : "s")): \(saved.path)")
            } else {
                configuration.log("Cues: stopped. Transcript discarded (\(count) sentence\(count == 1 ? "" : "s"), never written).")
            }
            if let savedLinks {
                configuration.log("Cues: \(links) link\(links == 1 ? "" : "s") saved: \(savedLinks.path)")
            }
            // Where the waiting actually went, per source. Counts and timings
            // only - never a query, a title or a URL.
            let resolver = self.resolver
            Task { [configuration] in
                let summary = await resolver.timingSummary()
                guard !summary.isEmpty else { return }
                await MainActor.run { configuration.log("Cues: lookups this class \u{2014} \(summary).") }
            }
        }
        testMode = false
    }

    /// "Stop listening for this class": the teacher's per-session off switch.
    /// Settings stay as they were; the next class starts fresh.
    func stopForClass() {
        Analytics.feature("prompter_stop_for_class")
        let ending = configuration.transcriptFile == nil
            ? "Transcript discarded (\(transcript.totalFinalized) sentences, never written)."
            : "Transcript saved (\(transcript.totalFinalized) sentences)."
        stop(reason: "Cues: stopped for this class. \(ending)")
        stoppedForClass = true
    }

    /// Muted in Zoom → nothing is transcribed until unmuted.
    func setPaused(_ paused: Bool) {
        guard isListening, paused != isPaused else { return }
        isPaused = paused
        configuration.log(paused ? "Cues: paused \u{2014} you are muted in Zoom." : "Cues: resumed.")
    }

    func markSeen() { unseenCount = 0 }

    func dismiss(_ card: CueCard) {
        dismissedKeys.insert(card.normalizedKey)
        cards.removeAll { $0.id == card.id }
        Analytics.feature("prompter_dismiss", source: card.source.analyticsCode)
    }

    // MARK: Settings test and debug paths

    /// Thirty seconds of live transcription with detection but no lookups, for
    /// Settings → Cues → Try it. Nothing leaves the Mac.
    /// `lookUp` runs the real thing: detect, resolve, and put cards up.
    func startTest(seconds: TimeInterval, configuration: Configuration,
                   lookUp: Bool = false) async {
        guard !isListening else { return }
        self.configuration = configuration
        testMode = !lookUp
        cards = []
        testMentions = []
        liveTail = ""
        // The resolver was never configured here, so Try it ran on its
        // built-in defaults - six lookups a minute, where a class gets
        // twelve - and held back "Adobe Photoshop" in a two-minute test.
        await resolver.reset()
        await resolver.configure(.init(sessionCap: sessionLookupCap,
                                       lookupsPerMinute: configuration.lookupsPerMinute,
                                       videoSearchEnabled: configuration.videoSearch,
                                       youtubeToken: configuration.youtubeToken))
        startedAt = Date()
        pipelineReady = true
        status = lookUp
            ? "Listening\u{2026} name a book, a tool, a place."
            : "Listening\u{2026} say something."
        chooseDetector()
        note(.note, "listening \u{00B7} detector: \(detectorName) \u{00B7} speech: \(configuration.useWhisper ? "whisper" : "Apple") \u{00B7} \(configuration.lookupsPerMinute) lookups a minute")
        let locale = await Transcriber.resolvedLocale(preferred: configuration.localeIdentifier)
        guard await startPipeline(input: nil, locale: locale) else {
            status = "Could not start: \(self.status)"
            return
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.isListening else { return }
            if lookUp {
                self.status = self.cards.isEmpty
                    ? "Done. Nothing was found \u{2014} try \u{201C}the book called Matilda\u{201D}."
                    : "Done. \(self.cards.count) card\(self.cards.count == 1 ? "" : "s")."
            } else {
                self.status = self.testMentions.isEmpty
                    ? "Done. Nothing findable was named \u{2014} try \u{201C}the book called Matilda\u{201D}."
                    : "Done. \(self.testMentions.count) mention\(self.testMentions.count == 1 ? "" : "s") found; nothing was looked up."
            }
            self.stop()
        }
    }

    /// Runs an audio file through the same pipeline, lookups included. Debug
    /// builds only; it is how a regression is reproduced without a class.
    func debugFeed(file url: URL, configuration: Configuration) async {
        guard !isListening else { return }
        self.configuration = configuration
        testMode = false
        await resolver.reset()
        await resolver.configure(.init(sessionCap: sessionLookupCap,
                                       lookupsPerMinute: configuration.lookupsPerMinute,
                                       videoSearchEnabled: configuration.videoSearch,
                                       youtubeToken: configuration.youtubeToken))
        chooseDetector()
        let locale = await Transcriber.resolvedLocale(preferred: configuration.localeIdentifier)
        do {
            let file = try AVAudioFile(forReading: url)
            _ = await startPipeline(input: .file(file), locale: locale)
        } catch {
            configuration.log("Cues: could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// The full pipeline on audio buffers from anywhere - the test bench's
    /// played recording. Same code as a class, minus the microphone.
    func debugFeed(buffers: AsyncStream<AnalyzerInput>, configuration: Configuration) async {
        guard !isListening else { return }
        self.configuration = configuration
        testMode = false
        await resolver.reset()
        await resolver.configure(.init(sessionCap: sessionLookupCap,
                                       lookupsPerMinute: configuration.lookupsPerMinute,
                                       videoSearchEnabled: configuration.videoSearch,
                                       youtubeToken: configuration.youtubeToken))
        chooseDetector()
        let locale = await Transcriber.resolvedLocale(preferred: configuration.localeIdentifier)
        _ = await startPipeline(input: .buffers(buffers), locale: locale)
        configuration.log(detector is HeuristicDetector
                          ? "Cues: mentions found by word patterns."
                          : "Cues: mentions found by Apple Intelligence (on-device) \u{2014} more suggestions, more wrong ones.")
    }

    #if DEBUG
    /// Typed text as if it were being spoken: words appear one at a time as
    /// partial results at `wordsPerSecond`, and each sentence is finished the
    /// way the transcriber finishes one. Detection then runs on its own, as
    /// it does in a class, so the timings are a class's timings minus the
    /// microphone. Debug builds.
    func debugSpeak(_ text: String, wordsPerSecond: Double, configuration: Configuration) async {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".?!"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !sentences.isEmpty else { return }
        if !pipelineReady { await preparePipeline(configuration) }
        let pause = UInt64(1_000_000_000 / max(0.5, wordsPerSecond))
        var cursor = text.startIndex
        for sentence in sentences {
            // Keep the speaker's own punctuation on the finished sentence.
            var finished = sentence
            if let range = text.range(of: sentence, range: cursor..<text.endIndex) {
                cursor = range.upperBound
                if cursor < text.endIndex, ".?!".contains(text[cursor]) { finished += String(text[cursor]) }
            }
            var partial: [Substring] = []
            for word in sentence.split(separator: " ") {
                partial.append(word)
                handle(.volatile(partial.joined(separator: " ")))
                try? await Task.sleep(nanoseconds: pause)
                guard pipelineReady else { return }
            }
            handle(.final(finished))
        }
    }

    private func preparePipeline(_ configuration: Configuration) async {
        self.configuration = configuration
        testMode = false
        await resolver.reset()
        await resolver.configure(.init(sessionCap: sessionLookupCap,
                                       lookupsPerMinute: configuration.lookupsPerMinute,
                                       videoSearchEnabled: configuration.videoSearch,
                                       youtubeToken: configuration.youtubeToken))
        chooseDetector()
        note(.note, "detector: \(detectorName) \u{00B7} \(configuration.lookupsPerMinute) lookups a minute")
        startedAt = Date()
        pipelineReady = true
    }

    /// A typed sentence, through exactly the path a spoken one takes: the
    /// transcript, the detector, the repair, the resolver and the cards.
    /// Works while listening or not. Debug builds.
    func debugSay(_ text: String, configuration: Configuration) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !pipelineReady { await preparePipeline(configuration) }
        handle(.final(trimmed))
        // Typed text arrives whole, so there is nothing to wait for.
        runDetection(force: true)
    }
    #endif

    func debugInjectSampleCards() {
        let samples: [CueCard] = [
            CueCard(kind: .book, query: "charlottes web", title: "Charlotte\u{2019}s Web", subtitle: "E. B. White",
                         source: .googleBooks, url: URL(string: "https://books.google.com/books?id=sample")!),
            CueCard(kind: .person, query: "eric carle", title: "Eric Carle", subtitle: "American author and illustrator",
                         source: .wikipedia, url: URL(string: "https://en.wikipedia.org/wiki/Eric_Carle")!),
            CueCard(kind: .video, query: "baby shark dance", title: "Search YouTube for \u{201C}baby shark dance\u{201D}",
                         subtitle: "Nothing sent until you open it", source: .search,
                         url: URL(string: "https://www.youtube.com/results?search_query=baby+shark+dance")!),
            // Six, not three. Three fills the rail's slots exactly and so never
            // rotates - the button could not show the one behaviour it is most
            // useful for testing.
            CueCard(kind: .word, query: "pabulum", title: "pabulum", subtitle: "Bland intellectual fare",
                         source: .dictionary, url: URL(string: "dict://pabulum")!),
            CueCard(kind: .thing, query: "haiku deck", title: "Haiku Deck", subtitle: "haikudeck.com",
                         source: .officialSite, url: URL(string: "https://www.haikudeck.com")!),
            CueCard(kind: .quote, query: "ask not what your country can do for you",
                         title: "John F. Kennedy", subtitle: "Inaugural Address, 1961",
                         source: .wikiquote, url: URL(string: "https://en.wikiquote.org/wiki/John_F._Kennedy")!)
        ]
        for card in samples { insert(card) }
        isListening = true
    }

    // MARK: Pipeline

    /// Word patterns unless the teacher asked for the model.
    ///
    /// The model was measured against a recorded class and it is not ready to
    /// run a lesson: 100% recall, but 264 lookups and roughly 254 wrong cards
    /// in 45 minutes, against the word patterns' 16 lookups at 56% precision.
    /// Every wrong card is an interruption on the reference display, so the
    /// precise detector is the default and the model is a switch the teacher
    /// turns on knowing what it costs.
    private func chooseDetector() {
        #if DEBUG
        if let choice = configuration.detectorChoice {
            switch choice {
            case .patterns:
                detector = HeuristicDetector()
            case .composite where FoundationModelsDetector.isAvailable:
                let model = FoundationModelsDetector()
                model.prewarm()
                detector = CompositeDetector(model: model)
            case .model where FoundationModelsDetector.isAvailable:
                let model = FoundationModelsDetector()
                model.prewarm()
                detector = model
            default:
                detector = HeuristicDetector()
                note(.note, "Apple Intelligence is not available here \u{2014} word patterns instead")
            }
            detectorName = detector.name
            detectorCode = detector.analyticsCode
            return
        }
        #endif
        if configuration.useModelDetector, FoundationModelsDetector.isAvailable {
            let model = FoundationModelsDetector()
            model.prewarm()
            // Both, not one. The patterns answer the sentences that carry an
            // explicit tell and the model gets the rest - see CompositeDetector.
            detector = CompositeDetector(model: model)
        } else {
            detector = HeuristicDetector()
        }
        detectorName = detector.name
        detectorCode = detector.analyticsCode
    }

    private func startPipeline(input: Transcriber.Input?, locale: Locale) async -> Bool {
        let source: Transcriber.Input = input ?? .microphone(MicStream())

        // Two transcribers behind one stream of events. The detector, the
        // resolver and everything downstream never learn which one ran -
        // whisper's sliding windows are turned into settled sentences by
        // CuesStabiliser before they get here, which is the whole reason that
        // type exists.
        let events: AsyncStream<Transcriber.Event>
        if configuration.useWhisper, case .microphone = source, let whisper = CuesWhisperTranscriber() {
            self.whisperTranscriber = whisper
            transcriberName = "whisper"
            events = whisper.start(input: source, locale: locale)
        } else {
            let transcriber = Transcriber()
            self.transcriber = transcriber
            transcriberName = "Apple"
            events = transcriber.start(input: source, locale: locale)
        }
        isListening = true
        isPaused = false
        restartAttempted = false

        eventTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                self.handle(event)
            }
        }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                self.tick()
            }
        }
        // The microphone fails synchronously inside `start`, surfaced as a
        // `.failed` event; give it a beat so Start can log the honest reason.
        try? await Task.sleep(nanoseconds: 250_000_000)
        return isListening
    }

    private func handle(_ event: Transcriber.Event) {
        if case .final(let text) = event, !isPaused {
            let now = Date()
            lastSpeechMs = utteranceStart.map { Int(now.timeIntervalSince($0) * 1000) }
            utteranceStart = nil
            if pendingHeardAt == nil { pendingHeardAt = now }
            note(.heard, lastSpeechMs.map { "\(text)   (\($0) ms from first words to finished sentence)" } ?? text)
        }
        switch event {
        case .volatile(let text):
            guard !isPaused else { return }
            if utteranceStart == nil, !text.isEmpty { utteranceStart = Date() }
            transcript.setVolatile(text)
            liveTail = transcript.display
        case .final(let text):
            guard !isPaused else { return }
            transcript.appendFinal(text)
            appendToTranscriptFile(text)
            liveTail = transcript.display
            // A free detector runs on the sentence that just landed; there is
            // nothing to ration and every wait is delay the teacher feels.
            // A model pass is seconds of work, so it still waits for enough
            // new words to be worth spending them on.
            if detector.isCheap {
                runDetection()
            } else if transcript.unprocessedWordCount >= detectMinWords,
                      Date().timeIntervalSince(lastDetection) > 2 {
                runDetection()
            }
        case .speech(let speaking):
            isSpeaking = speaking && !isPaused
        case .failed(let why):
            if why.contains("no microphone input") {
                status = why
                configuration.log("Cues: no microphone input \u{2014} listening is off for this session.")
                Analytics.failure("prompter_mic")
                stopQuietly()
            } else if !restartAttempted, !testMode {
                restartAttempted = true
                configuration.log("Cues: transcription stopped (\(why)). Trying once more\u{2026}")
                Analytics.failure("prompter_analyzer")
                Task { [weak self] in
                    guard let self else { return }
                    let locale = await Transcriber.resolvedLocale(preferred: self.configuration.localeIdentifier)
                    self.eventTask?.cancel()
                    self.tickTask?.cancel()
                    if let old = self.transcriber { await old.stop() }
                    let ok = await self.startPipeline(input: nil, locale: locale)
                    self.restartAttempted = true
                    if !ok { self.configuration.log("Cues: transcription stopped again. Listening is off for the rest of this session.") }
                }
            } else {
                status = why
                configuration.log("Cues: transcription stopped (\(why)). Listening is off for the rest of this session.")
                Analytics.failure("prompter_analyzer")
                stopQuietly()
            }
        case .finished:
            // File input ran out. Detect whatever is left, then wind down.
            runDetection(force: true)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.stop()
            }
        }
    }

    /// One line per finalised sentence, timestamped from the session's start.
    private func appendToTranscriptFile(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        append("\(stamp())\t\(trimmed)\n", to: configuration.transcriptFile, headerLines: [
            "What the microphone heard, as Cues transcribed it on this Mac.",
            "One line per finalised sentence: time, then what was said.",
            "Sparse is normal. The speech model finalises only what it can render",
            "in the class language, so a bilingual class transcribes thinly."
        ])
    }

    /// One line per link Cues put on screen.
    ///
    /// A separate file from the transcript, and not a subset of it. They read
    /// as the same thing on a thin transcript - where nearly every sentence the
    /// model finalised also produced a link - and that coincidence is exactly
    /// what makes one file useless for judging either.
    private func appendToPromptsFile(_ card: CueCard, foundBy: FoundBy) {
        let fields = [stamp(), foundBy.rawValue, card.kind.rawValue, card.source.label,
                      oneLine(card.query), oneLine(card.title), card.url.absoluteString]
        append(fields.joined(separator: "\t") + "\n", to: configuration.linksFile, headerLines: [
            "Links Cues offered during this class, in the order they appeared.",
            "time, found by, kind, source, what it heard, what it found, link.",
            "",
            "\"found by\" is patterns or model. Word patterns answer a sentence with",
            "an explicit tell; the model gets the sentences nobody else can read.",
            "Measured on one recorded class the two were far apart - 16 lookups at",
            "56% precision against 264 at 3% - so the split in a real lesson is the",
            "number worth watching."
        ])
    }

    /// Seconds since the session started, as h:mm:ss.
    private func stamp() -> String {
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        return String(format: "%d:%02d:%02d", elapsed / 3600, (elapsed % 3600) / 60, elapsed % 60)
    }

    /// Tabs and newlines out, so a title can never split a row in two.
    private func oneLine(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Appended as it lands rather than written at the end - a class that
    /// crashes keeps everything up to that moment. The header is written with
    /// the first line, so a file only exists once it has something in it.
    private func append(_ line: String, to url: URL?, headerLines: [String]) {
        guard let url else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            let folder = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let preamble = (["# \(folder.lastPathComponent)"] + headerLines.map { "# \($0)" })
                .joined(separator: "\n") + "\n\n"
            try? Data((preamble + line).utf8).write(to: url)
        }
    }

    /// Tears the audio down without the "stopped" line - the caller has
    /// already logged the real reason.
    private func stopQuietly() {
        eventTask?.cancel()
        tickTask?.cancel()
        if let transcriber {
            self.transcriber = nil
            Task { await transcriber.stop() }
            Task { await whisperTranscriber?.stop() }
        }
        isListening = false
        isSpeaking = false
        transcript.reset()
    }

    private func tick() {
        // Cards that sat untouched for ten minutes are stale by class standards.
        let cutoff = Date().addingTimeInterval(-cardLifetime)
        cards.removeAll { $0.createdAt < cutoff }
        // Cycle the window when there is more than the rail can show at once.
        if cards.count > CuesRailBlock.minCards,
           Date().timeIntervalSince(lastRotation) >= rotateEvery {
            rotationOffset = (rotationOffset + 1) % cards.count
            lastRotation = Date()
        } else if cards.count <= CuesRailBlock.minCards {
            rotationOffset = 0
        }
        // Held-back mentions go again, oldest first, once they are younger
        // than two minutes; older than that the moment has passed.
        heldBack.removeAll { Date().timeIntervalSince($0.at) > 120 }
        if !heldBack.isEmpty, detectTask == nil {
            let waiting = heldBack
            heldBack.removeAll()
            Task { [weak self] in
                for item in waiting {
                    await self?.resolve([item.mention], heardAt: item.heardAt, detectBegan: item.heardAt,
                                        detectedAt: item.heardAt, speechMs: nil)
                }
            }
        }
        // The catch-up tick, for speech that never reaches the word count.
        let gap = detector.isCheap ? 3.0 : detectEvery
        if transcript.unprocessedWordCount > 0,
           Date().timeIntervalSince(lastDetection) >= gap {
            runDetection()
        }
    }

    private func runDetection(force: Bool = false) {
        guard detectTask == nil || force else { return }
        lastDetection = Date()
        let (fresh, context) = transcript.unprocessedText(leadInWords: 20)
        guard !fresh.isEmpty else { return }
        for name in HeuristicDetector.selfIntroducedNames(in: context + " " + fresh)
        where !spokenNames.contains(name) {
            spokenNames.append(name)
            note(.name, "\u{201C}\(name)\u{201D} introduced themselves \u{2014} never looked up this session")
        }
        let names = configuration.rosterNames() + spokenNames
        let current = detector
        let began = Date()
        let heardAt = pendingHeardAt ?? began
        pendingHeardAt = nil
        let speechMs = lastSpeechMs
        detectTask = Task { [weak self] in
            defer { self?.detectTask = nil }
            do {
                let mentions = try await current.detect(newText: fresh, context: context, excludedNames: names)
                guard let self, !Task.isCancelled else { return }
                let ms = Int(Date().timeIntervalSince(began) * 1000)
                self.note(.detect, mentions.isEmpty
                    ? "\(current.name), \(ms) ms: nothing"
                    : "\(current.name), \(ms) ms: " + mentions.map { mention in
                        var line = "\(mention.kind.rawValue) \u{201C}\(mention.query)\u{201D} by \(mention.foundBy.rawValue) \(Int(mention.confidence * 100))%"
                        if let category = mention.category { line += ", said to be a \(category)" }
                        if mention.searchQuery != mention.query { line += ", searched as \u{201C}\(mention.searchQuery)\u{201D}" }
                        return line
                    }.joined(separator: "; "))
                // Log roster collisions without ever logging the transcript.
                if let heuristic = current as? HeuristicDetector {
                    _ = heuristic
                }
                if self.testMode {
                    self.testMentions.append(contentsOf: mentions)
                } else {
                    await self.resolve(mentions, heardAt: heardAt, detectBegan: began,
                                       detectedAt: Date(), speechMs: speechMs)
                }
            } catch {
                guard let self else { return }
                self.note(.drop, "\(current.name) failed: \(error.localizedDescription)")
                if let model = current as? FoundationModelsDetector, model.consecutiveErrors >= 3 {
                    self.detector = HeuristicDetector()
                    self.detectorName = self.detector.name
                    self.detectorCode = self.detector.analyticsCode
                    self.configuration.log("Cues: Apple Intelligence failed three times running \u{2014} mentions found by word patterns for the rest of this session.")
                    Analytics.failure("prompter_model")
                }
            }
        }
    }

    private func resolve(_ mentions: [Mention], heardAt: Date = Date(), detectBegan: Date = Date(),
                         detectedAt: Date = Date(), speechMs: Int? = nil) async {
        for heard in mentions where !dismissedKeys.contains(heard.normalizedKey) {
            var mention = heard
            // "Adobe O Strader", a minute after "Adobe Illustrator" was said
            // twice, is Adobe Illustrator misheard. Search for what was meant.
            if let meant = vocabulary.repair(mention.query) {
                configuration.log("Cues: heard \u{201C}\(mention.query)\u{201D}, searched \u{201C}\(meant)\u{201D} (said earlier in this class).")
                note(.repair, "\u{201C}\(mention.query)\u{201D} is \u{201C}\(meant)\u{201D} misheard (a name already found this session)")
                mention = Mention(kind: mention.kind, query: meant, confidence: mention.confidence)
                mention.foundBy = heard.foundBy
                mention.category = heard.category
            }
            // Roster names are filtered inside the detectors; a mention that
            // still equals a roster name here is a second line of defence.
            let names = (configuration.rosterNames() + spokenNames).map(Mention.normalize)
            if names.contains(mention.normalizedKey) {
                note(.skip, "\u{201C}\(mention.query)\u{201D} is someone in the meeting")
                configuration.log("Cues: skipped \u{201C}\(mention.query)\u{201D} \u{2014} matches someone in the meeting.")
                Analytics.feature("prompter_roster_skip")
                continue
            }
            // Already have a card for it: nothing to send. The same name as a
            // different kind is a different request - "the book, Adobe
            // Illustrator" after a card for the software - and replaces it.
            if cards.contains(where: { $0.normalizedKey == mention.normalizedKey && $0.kind == mention.kind }) {
                note(.skip, "\u{201C}\(mention.query)\u{201D} already has a \(mention.kind.rawValue) card")
                continue
            }

            lookupsInFlight += 1
            isResolving = true
            let lookupBegan = Date()
            let resolution = await resolver.resolve(mention)
            let lookupMs = Int(Date().timeIntervalSince(lookupBegan) * 1000)
            lookupsInFlight -= 1
            isResolving = lookupsInFlight > 0

            if resolution.heldBack {
                heldBack.removeAll { $0.mention.normalizedKey == mention.normalizedKey && $0.mention.kind == mention.kind }
                heldBack.append((mention, Date(), heardAt))
                if heldBack.count > 10 { heldBack.removeFirst(heldBack.count - 10) }
                note(.hold, "\u{201C}\(mention.query)\u{201D} waits: the minute's lookups are spent")
            }
            if resolution.skipped, resolution.cards.isEmpty {
                for line in resolution.notes { configuration.log("Cues: \(line)."); if !resolution.heldBack { note(.note, line) } }
                continue
            }
            if !resolution.sentTo.isEmpty {
                note(.lookup, "\u{201C}\(mention.searchQuery)\u{201D} \u{2192} \(resolution.sentTo.joined(separator: " and "))")
            }
            for line in resolution.notes { note(.note, line) }
            // Only a name that found something is worth remembering. Learning
            // every name let a mishearing that found nothing ("Adobe O
            // Strader") become the name a later correct hearing was
            // "repaired" into.
            if !resolution.cards.isEmpty, !resolution.searchLinkOnly { vocabulary.learn(mention.query) }
            if resolution.cards.isEmpty { note(.note, "no card for \u{201C}\(mention.query)\u{201D}") }
            if !resolution.sentTo.isEmpty {
                configuration.log("Cues: sent \u{201C}\(mention.searchQuery)\u{201D} to \(resolution.sentTo.joined(separator: " and ")).")
            }
            if resolution.searchLinkOnly {
                configuration.log("Cues: video card for \u{201C}\(mention.query)\u{201D} is a search link \u{2014} nothing sent.")
            }
            for note in resolution.notes { configuration.log("Cues: \(note).") }
            for card in resolution.cards.prefix(1) {
                let timing = CueTiming(speechMs: speechMs,
                                       waitMs: max(0, Int(detectBegan.timeIntervalSince(heardAt) * 1000)),
                                       detectMs: max(0, Int(detectedAt.timeIntervalSince(detectBegan) * 1000)),
                                       lookupMs: lookupMs,
                                       totalMs: Int(Date().timeIntervalSince(heardAt) * 1000),
                                       source: card.source.label)
                timings[card.id] = timing
                note(.card, "\(card.kind.eyebrow) \(card.title) \u{00B7} \(card.source.label)\(resolution.searchLinkOnly ? " (search link, nothing sent)" : "") \u{00B7} \(timing.totalMs) ms after the sentence ended (wait \(timing.waitMs), detect \(timing.detectMs), lookup \(timing.lookupMs)) \u{00B7} \(card.url.absoluteString)")
                insert(card, foundBy: mention.foundBy)
                Analytics.feature("prompter_card", source: card.source.analyticsCode)
                if let thumbnail = resolution.thumbnails[card.id] {
                    loadThumbnail(thumbnail, for: card.id)
                }
            }
        }
    }

    /// Fetches a card's picture after the card is already on screen.
    ///
    /// The card used to wait for this. That put a second round trip in front
    /// of a link the teacher could already have clicked, to fetch decoration.
    /// If it arrives, the card gains a picture in place; if it never does, the
    /// card is exactly as useful without one.
    private func loadThumbnail(_ url: URL, for id: UUID) {
        Task { [weak self] in
            guard let image = await ThumbnailLoader.shared.image(for: url) else { return }
            guard let self else { return }
            // The card may have been dismissed or aged out while this was in
            // flight, which is not worth a word to anyone.
            guard let index = self.cards.firstIndex(where: { $0.id == id }) else { return }
            self.cards[index].thumbnail = image
        }
    }

    private func insert(_ card: CueCard, foundBy: FoundBy = .patterns) {
        guard !dismissedKeys.contains(card.normalizedKey) else { return }
        cards.removeAll { $0.normalizedKey == card.normalizedKey }
        cards.insert(card, at: 0)
        if cards.count > keepCards { cards.removeLast(cards.count - keepCards) }
        unseenCount += 1
        // The newest link goes to the top of the window, not into the queue
        // behind whatever the rotation was showing.
        rotationOffset = 0
        lastRotation = Date()
        appendToPromptsFile(card, foundBy: foundBy)
        linksFound += 1
    }
}
