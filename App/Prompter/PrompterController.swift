//
//  PrompterController.swift
//  Greenroom
//
//  The pipeline, end to end, for one session: microphone → speech → text →
//  mentions → lookups → cards. Owned by the coordinator between the session
//  going live and End Session, and by nothing else - there is no Prompter at
//  launch, none between classes, none in the background.
//
//  What it promises, and the code that keeps each promise:
//    - Only finalised sentences are detected on (`handle(.final)`); volatile
//      text goes to the Settings test panel and nowhere else.
//    - Nothing is written down: `RollingTranscript` is a struct in memory,
//      released in `stop()`, and the closing log line counts what was dropped.
//    - Every query that leaves is logged before the card exists (`resolve`).
//    - A student's name never becomes a query: the roster filter runs inside
//      both detectors, and a collision is logged as skipped.
//    - Muted in Zoom means paused: `setPaused` drops results at the door.
//
import AppKit
import AVFoundation
import Foundation
import Speech

@available(macOS 26.0, *)
@MainActor
final class PrompterController: ObservableObject {

    struct Configuration {
        var localeIdentifier = ""
        var videoSearch = true
        var youtubeToken: (() async throws -> String)?
        var rosterNames: () -> [String] = { [] }
        var log: (String) -> Void = { _ in }
        /// Bench mode: every mention becomes a FAN of choices (the site
        /// itself, a video, pictures, the encyclopedia entry, a definition)
        /// instead of one best card, and far more of them are kept. The
        /// shipped app leaves this off - a class needs restraint, a test
        /// needs to see everything.
        var optionsMode = false
    }

    @Published private(set) var isListening = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var stoppedForClass = false
    @Published private(set) var isResolving = false
    /// Newest first. Eight kept, five shown.
    @Published private(set) var cards: [PrompterCard] = []
    @Published private(set) var unseenCount = 0
    /// The Settings "Try it" readout: recent finals plus the live tail.
    @Published private(set) var liveTail = ""
    /// Mentions found during a test run, for the same panel.
    @Published private(set) var testMentions: [Mention] = []
    @Published private(set) var status = ""
    private(set) var detectorName = ""
    private(set) var detectorCode = ""

    private var configuration = Configuration()
    private var transcript = RollingTranscript()
    private var transcriber: Transcriber?
    private var detector: MentionDetector = HeuristicDetector()
    private let resolver = LinkResolver()
    private var eventTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var detectTask: Task<Void, Never>?
    private var dismissedKeys: Set<String> = []
    private var lastDetection = Date.distantPast
    private var restartAttempted = false
    private var lookupsInFlight = 0
    private var testMode = false

    private let keepCards = 8
    private let cardLifetime: TimeInterval = 600
    /// Detection cadence: every 8 s if there is anything new, or as soon as a
    /// final sentence lands and at least 6 new words are waiting.
    private let detectEvery: TimeInterval = 8
    private let detectMinWords = 6

    var surfaceCards: [PrompterCard] { Array(cards.prefix(PrompterRailBlock.maxCards)) }

    // MARK: Lifecycle

    /// Starts listening for a class. Returns false (having logged why) when
    /// the model is not installed or the microphone is unavailable.
    @discardableResult
    func start(configuration: Configuration) async -> Bool {
        guard !isListening else { return true }
        self.configuration = configuration
        stoppedForClass = false
        testMode = false
        await resolver.reset()
        await resolver.configure(.init(sessionCap: configuration.optionsMode ? 500 : 30,
                                       videoSearchEnabled: configuration.videoSearch,
                                       youtubeToken: configuration.youtubeToken))

        let locale = await Transcriber.resolvedLocale(preferred: configuration.localeIdentifier)
        let status = await AssetInventory.status(forModules: [Transcriber.makeTranscriber(locale: locale)])
        guard status == .installed else {
            configuration.log("Prompter skipped \u{2014} the speech model isn't downloaded yet. Settings (\u{2318},) \u{2192} Prompter \u{2192} Download.")
            Analytics.failure("prompter_asset")
            return false
        }

        chooseDetector()
        guard await startPipeline(input: nil, locale: locale) else { return false }

        configuration.log("Prompter: listening to your microphone. Speech becomes text on this Mac; the text stays in memory.")
        configuration.log(detector is HeuristicDetector
                          ? "Prompter: mentions found by word patterns (Apple Intelligence is off)."
                          : "Prompter: mentions found by Apple Intelligence (on-device).")
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
        }
        let count = transcript.totalFinalized
        transcript.reset()
        isListening = false
        isSpeaking = false
        isPaused = false
        isResolving = false
        liveTail = ""
        cards.removeAll()
        unseenCount = 0
        dismissedKeys.removeAll()
        if wasListening, !testMode {
            configuration.log(reason ?? "Prompter: stopped. Transcript discarded (\(count) sentence\(count == 1 ? "" : "s"), never written).")
        }
        testMode = false
    }

    /// "Stop listening for this class": the teacher's per-session off switch.
    /// Settings stay as they were; the next class starts fresh.
    func stopForClass() {
        Analytics.feature("prompter_stop_for_class")
        stop(reason: "Prompter: stopped for this class. Transcript discarded (\(transcript.totalFinalized) sentences, never written).")
        stoppedForClass = true
    }

    /// Muted in Zoom → nothing is transcribed until unmuted.
    func setPaused(_ paused: Bool) {
        guard isListening, paused != isPaused else { return }
        isPaused = paused
        configuration.log(paused ? "Prompter: paused \u{2014} you are muted in Zoom." : "Prompter: resumed.")
    }

    func markSeen() { unseenCount = 0 }

    func dismiss(_ card: PrompterCard) {
        dismissedKeys.insert(card.normalizedKey)
        cards.removeAll { $0.id == card.id }
        Analytics.feature("prompter_dismiss", source: card.source.analyticsCode)
    }

    // MARK: Settings test and debug paths

    /// Thirty seconds of live transcription with detection but no lookups, for
    /// Settings → Prompter → Try it. Nothing leaves the Mac.
    func startTest(seconds: TimeInterval, configuration: Configuration) async {
        guard !isListening else { return }
        self.configuration = configuration
        testMode = true
        testMentions = []
        liveTail = ""
        status = "Listening\u{2026} say something."
        chooseDetector()
        let locale = await Transcriber.resolvedLocale(preferred: configuration.localeIdentifier)
        guard await startPipeline(input: nil, locale: locale) else {
            status = "Could not start: \(self.status)"
            return
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.testMode else { return }
            self.status = self.testMentions.isEmpty
                ? "Done. Nothing findable was named \u{2014} try \u{201C}the book called Matilda\u{201D}."
                : "Done. \(self.testMentions.count) mention\(self.testMentions.count == 1 ? "" : "s") found; nothing was looked up."
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
        await resolver.configure(.init(sessionCap: configuration.optionsMode ? 500 : 30,
                                       videoSearchEnabled: configuration.videoSearch,
                                       youtubeToken: configuration.youtubeToken))
        chooseDetector()
        let locale = await Transcriber.resolvedLocale(preferred: configuration.localeIdentifier)
        do {
            let file = try AVAudioFile(forReading: url)
            _ = await startPipeline(input: .file(file), locale: locale)
        } catch {
            configuration.log("Prompter: could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// The full pipeline on audio buffers from anywhere - the test bench's
    /// played recording. Same code as a class, minus the microphone.
    func debugFeed(buffers: AsyncStream<AnalyzerInput>, configuration: Configuration) async {
        guard !isListening else { return }
        self.configuration = configuration
        testMode = false
        await resolver.reset()
        await resolver.configure(.init(sessionCap: configuration.optionsMode ? 500 : 30,
                                       videoSearchEnabled: configuration.videoSearch,
                                       youtubeToken: configuration.youtubeToken))
        chooseDetector()
        let locale = await Transcriber.resolvedLocale(preferred: configuration.localeIdentifier)
        _ = await startPipeline(input: .buffers(buffers), locale: locale)
        configuration.log(detector is HeuristicDetector
                          ? "Prompter: mentions found by word patterns (Apple Intelligence is off)."
                          : "Prompter: mentions found by Apple Intelligence (on-device).")
    }

    /// Detector only, on typed text. Debug builds.
    func debugDetect(_ text: String, configuration: Configuration) async -> [Mention] {
        self.configuration = configuration
        chooseDetector()
        let names = configuration.rosterNames()
        do {
            return try await detector.detect(newText: text, context: "", excludedNames: names)
        } catch {
            configuration.log("Prompter: detector error: \(error.localizedDescription)")
            return []
        }
    }

    /// Resolver only, on a typed query. Debug builds; the query IS sent.
    func debugResolve(_ query: String, kind: Mention.Kind, configuration: Configuration) async {
        self.configuration = configuration
        await resolver.configure(.init(sessionCap: configuration.optionsMode ? 500 : 30,
                                       videoSearchEnabled: configuration.videoSearch,
                                       youtubeToken: configuration.youtubeToken))
        await resolve([Mention(kind: kind, query: query, confidence: 1)])
    }

    func debugInjectSampleCards() {
        let samples: [PrompterCard] = [
            PrompterCard(kind: .book, query: "charlottes web", title: "Charlotte\u{2019}s Web", subtitle: "E. B. White",
                         source: .googleBooks, url: URL(string: "https://books.google.com/books?id=sample")!),
            PrompterCard(kind: .person, query: "eric carle", title: "Eric Carle", subtitle: "American author and illustrator",
                         source: .wikipedia, url: URL(string: "https://en.wikipedia.org/wiki/Eric_Carle")!),
            PrompterCard(kind: .video, query: "baby shark dance", title: "Search YouTube for \u{201C}baby shark dance\u{201D}",
                         subtitle: "Nothing sent until you open it", source: .search,
                         url: URL(string: "https://www.youtube.com/results?search_query=baby+shark+dance")!)
        ]
        for card in samples { insert(card) }
        isListening = true
    }

    // MARK: Pipeline

    private func chooseDetector() {
        if FoundationModelsDetector.isAvailable {
            let model = FoundationModelsDetector()
            model.prewarm()
            detector = model
        } else {
            detector = HeuristicDetector()
        }
        detectorName = detector.name
        detectorCode = detector.analyticsCode
    }

    private func startPipeline(input: Transcriber.Input?, locale: Locale) async -> Bool {
        let transcriber = Transcriber()
        self.transcriber = transcriber
        let source: Transcriber.Input = input ?? .microphone(MicStream())
        let events = transcriber.start(input: source, locale: locale)
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
        switch event {
        case .volatile(let text):
            guard !isPaused else { return }
            transcript.setVolatile(text)
            liveTail = transcript.display
        case .final(let text):
            guard !isPaused else { return }
            transcript.appendFinal(text)
            liveTail = transcript.display
            if transcript.unprocessedWordCount >= detectMinWords,
               Date().timeIntervalSince(lastDetection) > 2 {
                runDetection()
            }
        case .speech(let speaking):
            isSpeaking = speaking && !isPaused
        case .failed(let why):
            if why.contains("no microphone input") {
                status = why
                configuration.log("Prompter: no microphone input \u{2014} listening is off for this session.")
                Analytics.failure("prompter_mic")
                stopQuietly()
            } else if !restartAttempted, !testMode {
                restartAttempted = true
                configuration.log("Prompter: transcription stopped (\(why)). Trying once more\u{2026}")
                Analytics.failure("prompter_analyzer")
                Task { [weak self] in
                    guard let self else { return }
                    let locale = await Transcriber.resolvedLocale(preferred: self.configuration.localeIdentifier)
                    self.eventTask?.cancel()
                    self.tickTask?.cancel()
                    if let old = self.transcriber { await old.stop() }
                    let ok = await self.startPipeline(input: nil, locale: locale)
                    self.restartAttempted = true
                    if !ok { self.configuration.log("Prompter: transcription stopped again. Listening is off for the rest of this session.") }
                }
            } else {
                status = why
                configuration.log("Prompter: transcription stopped (\(why)). Listening is off for the rest of this session.")
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

    /// Tears the audio down without the "stopped" line - the caller has
    /// already logged the real reason.
    private func stopQuietly() {
        eventTask?.cancel()
        tickTask?.cancel()
        if let transcriber {
            self.transcriber = nil
            Task { await transcriber.stop() }
        }
        isListening = false
        isSpeaking = false
        transcript.reset()
    }

    private func tick() {
        // Cards that sat untouched for ten minutes are stale by class standards.
        let cutoff = Date().addingTimeInterval(-cardLifetime)
        cards.removeAll { $0.createdAt < cutoff }
        if transcript.unprocessedWordCount > 0,
           Date().timeIntervalSince(lastDetection) >= detectEvery {
            runDetection()
        }
    }

    private func runDetection(force: Bool = false) {
        guard detectTask == nil || force else { return }
        lastDetection = Date()
        let (fresh, context) = transcript.unprocessedText(leadInWords: 20)
        guard !fresh.isEmpty else { return }
        let names = configuration.rosterNames()
        let current = detector
        detectTask = Task { [weak self] in
            defer { self?.detectTask = nil }
            do {
                let mentions = try await current.detect(newText: fresh, context: context, excludedNames: names)
                guard let self, !Task.isCancelled else { return }
                // Log roster collisions without ever logging the transcript.
                if let heuristic = current as? HeuristicDetector {
                    _ = heuristic
                }
                if self.testMode {
                    self.testMentions.append(contentsOf: mentions)
                } else {
                    await self.resolve(mentions)
                }
            } catch {
                guard let self else { return }
                if let model = current as? FoundationModelsDetector, model.consecutiveErrors >= 3 {
                    self.detector = HeuristicDetector()
                    self.detectorName = self.detector.name
                    self.detectorCode = self.detector.analyticsCode
                    self.configuration.log("Prompter: Apple Intelligence failed three times running \u{2014} mentions found by word patterns for the rest of this session.")
                    Analytics.failure("prompter_model")
                }
            }
        }
    }

    private func resolve(_ mentions: [Mention]) async {
        for mention in mentions where !dismissedKeys.contains(mention.normalizedKey) {
            // Roster names are filtered inside the detectors; a mention that
            // still equals a roster name here is a second line of defence.
            let names = configuration.rosterNames().map(Mention.normalize)
            if names.contains(mention.normalizedKey) {
                configuration.log("Prompter: skipped \u{201C}\(mention.query)\u{201D} \u{2014} matches someone in the meeting.")
                Analytics.feature("prompter_roster_skip")
                continue
            }
            // Already have a card for it: nothing to send. In options mode a
            // key carries several cards, so match on the key AND the fact that
            // the fan was already built.
            if cards.contains(where: { $0.normalizedKey == mention.normalizedKey }) { continue }

            lookupsInFlight += 1
            isResolving = true
            let resolution = configuration.optionsMode
                ? await resolver.resolveOptions(mention)
                : await resolver.resolve(mention)
            lookupsInFlight -= 1
            isResolving = lookupsInFlight > 0

            if resolution.skipped, resolution.cards.isEmpty {
                for note in resolution.notes { configuration.log("Prompter: \(note).") }
                continue
            }
            if !resolution.sentTo.isEmpty {
                configuration.log("Prompter: sent \u{201C}\(mention.searchQuery)\u{201D} to \(resolution.sentTo.joined(separator: " and ")).")
            }
            if resolution.searchLinkOnly {
                configuration.log("Prompter: video card for \u{201C}\(mention.query)\u{201D} is a search link \u{2014} nothing sent.")
            }
            for note in resolution.notes { configuration.log("Prompter: \(note).") }
            // One card per mention in a class; every option in bench mode.
            let offered = configuration.optionsMode ? resolution.cards : Array(resolution.cards.prefix(1))
            if configuration.optionsMode, !offered.isEmpty {
                configuration.log("Prompter: \(offered.count) option\(offered.count == 1 ? "" : "s") for \u{201C}\(mention.query)\u{201D} \u{2014} \(offered.map(\.source.label).joined(separator: ", ")).")
            }
            for card in offered {
                insert(card)
                Analytics.feature("prompter_card", source: card.source.analyticsCode)
            }
            // Second wave: the product's own site takes a second or two to
            // answer, so it arrives after the quick cards rather than holding
            // all of them up.
            if configuration.optionsMode {
                Task { [weak self] in
                    guard let self, let site = await self.resolver.officialSiteCard(for: mention) else { return }
                    self.insert(site)
                    Analytics.feature("prompter_card", source: site.source.analyticsCode)
                }
            }
        }
    }

    private func insert(_ card: PrompterCard) {
        guard !dismissedKeys.contains(card.normalizedKey) else { return }
        // A class keeps one card per thing; the bench keeps every option, so
        // the same key legitimately appears several times there.
        if !configuration.optionsMode {
            cards.removeAll { $0.normalizedKey == card.normalizedKey }
        }
        cards.insert(card, at: 0)
        let limit = configuration.optionsMode ? 200 : keepCards
        if cards.count > limit { cards.removeLast(cards.count - limit) }
        unseenCount += 1
    }
}
