//
//  CoordinatorController+Cues.swift
//  Greenroom
//
//  Where Cues meets the session: started when the meeting is live,
//  stopped with End Session and on quit, paused while muted, drawn on the
//  participants panel when there is one and in the menu bar when there is
//  not, and wired to the two actions a card offers - open it in the main-pane
//  browser, or send it to the class chat.
//
//  This file compiles on macOS 14: the engine is stored as AnyObject and every
//  touch of it sits inside `if #available(macOS 26.0, *)`. Below 26 each
//  function is a no-op, which is exactly the "the app works without it"
//  promise.
//
import AppKit
import Foundation

extension CoordinatorController {

    /// Whether this Mac can run Cues at all. Settings says why when not.
    var cuesAvailableOnThisMac: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// The engine, typed. Nil below macOS 26 or before the first start.
    @available(macOS 26.0, *)
    var cues: CuesController? {
        get { cuesEngine as? CuesController }
    }

    @available(macOS 26.0, *)
    private func makeCuesIfNeeded() -> CuesController {
        if let existing = cuesEngine as? CuesController { return existing }
        let created = CuesController()
        cuesEngine = created
        return created
    }

    @available(macOS 26.0, *)
    func cuesConfiguration() -> CuesController.Configuration {
        var configuration = CuesController.Configuration()
        configuration.localeIdentifier = cuesLocaleIdentifier
        configuration.videoSearch = cuesVideoSearch
        configuration.useModelDetector = cuesUseModel
        configuration.useWhisper = cuesUseWhisper && CuesWhisperTranscriber.isAvailable
        // Beside the recording and the clips, in the folder named for this
        // class. Nil when the teacher turned saving off, or before a session
        // has a folder of its own.
        if cuesSaveTranscript, let folder = sessionFolder {
            configuration.transcriptFile = folder.appendingPathComponent("transcript.txt")
            // Two files, not one. What was said and what was suggested answer
            // different questions, and on a class the speech model barely
            // finalises they are indistinguishable in a single file.
            configuration.linksFile = folder.appendingPathComponent("cues.txt")
        }
        if youtubeConnected {
            let clientID = youtubeClientID.trimmingCharacters(in: .whitespacesAndNewlines)
            let clientSecret = youtubeClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            configuration.youtubeToken = { try await YouTubeAuth.accessToken(clientID: clientID, clientSecret: clientSecret) }
        }
        configuration.rosterNames = { [weak self] in
            guard let self else { return [] }
            var names = self.zoomChatClient.meetingRoster().map(\.name)
            names += self.zoomChatClient.waitingRoomNames().map(\.name)
            names.append(self.userDisplayName)
            return names
        }
        configuration.log = { [weak self] message in self?.log(message) }
        return configuration
    }

    // MARK: Lifecycle hooks

    /// Called once the meeting is live. Off by default; below macOS 26 it
    /// says so once and returns.
    func startCuesIfEnabled() {
        // Checked before `cuesEnabled`, not after: every Mac that ran an
        // earlier build already has prompterEnabled=true sitting in its
        // defaults, so hiding the switch alone would still start listening
        // for anyone upgrading into this release.
        guard CuesAvailability.isReleased else { return }
        guard cuesEnabled else { return }
        guard #available(macOS 26.0, *) else {
            log("Cues: not available on this Mac (macOS 26 required).")
            return
        }
        loadSecretsIfNeeded()
        let engine = makeCuesIfNeeded()
        let configuration = cuesConfiguration()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let started = await engine.start(configuration: configuration)
            self.cuesListening = started
            guard started else { return }
            self.cuesTickTask?.cancel()
            self.cuesTickTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.syncCuesSurfaces()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            self.syncCuesSurfaces()
        }
    }

    /// Stops listening and clears both surfaces. Safe to call at any time.
    func stopCues() {
        cuesTickTask?.cancel()
        cuesTickTask = nil
        cuesMenuBar.setVisible(false)
        if #available(macOS 26.0, *), let engine = cues {
            engine.stop()
        }
        cuesListening = false
        cuesLinkCount = 0
        ParticipantGridWindowController.applyCues(.empty)
    }

    func stopCuesForClass() {
        guard #available(macOS 26.0, *), let engine = cues else { return }
        engine.stopForClass()
        cuesTickTask?.cancel()
        cuesTickTask = nil
        cuesMenuBar.setVisible(false)
        cuesListening = false
        cuesLinkCount = 0
        ParticipantGridWindowController.applyCues(.empty)
    }

    /// Once a second: mute → pause, and whichever surface applies gets the
    /// current state. Rail when the participants panel is open; otherwise the
    /// menu-bar item. Never both.
    func syncCuesSurfaces() {
        guard #available(macOS 26.0, *), let engine = cues, engine.isListening else {
            // The engine stopped on its own (no microphone, transcriber gave
            // up): the mirrors must say so or the menu bar keeps claiming it
            // is listening.
            cuesListening = false
            cuesPaused = false
            cuesLinkCount = 0
            cuesMenuBar.setVisible(false)
            ParticipantGridWindowController.applyCues(.empty)
            return
        }
        engine.setPaused(zoomChatClient.isJoined && zoomChatClient.iAmMuted)
        cuesListening = true
        cuesLinkCount = engine.linksFound
        cuesPaused = engine.isPaused

        let state = cuesSurfaceState(engine)
        cuesOnRail = ParticipantGridWindowController.isOpen
        if ParticipantGridWindowController.isOpen {
            cuesMenuBar.setVisible(false)
            ParticipantGridWindowController.applyCues(state)
            if !cuesSurfaceReported {
                cuesSurfaceReported = true
                Analytics.track(.surfaceShown, [.surface: "cues", .placement: "reference_display"])
            }
            engine.markSeen()
        } else {
            ParticipantGridWindowController.applyCues(.empty)
            if !cuesMenuBar.isVisible {
                cuesMenuBar.setVisible(true)
                cuesMenuBar.onOpen = { [weak self] in
                    guard let self, #available(macOS 26.0, *) else { return }
                    self.cues?.markSeen()
                    self.syncCuesSurfaces()
                }
                cuesMenuBar.onStopForClass = { [weak self] in self?.stopCuesForClass() }
                if !cuesSurfaceReported {
                    cuesSurfaceReported = true
                    Analytics.track(.surfaceShown, [.surface: "cues", .placement: "menu_bar"])
                }
            }
            let statusText = engine.isPaused ? "Paused \u{2014} you are muted"
                : "Listening \u{00B7} on this Mac \u{00B7} \(engine.detectorName)"
            cuesMenuBar.apply(state, unseen: engine.unseenCount, statusText: statusText)
        }
    }

    @available(macOS 26.0, *)
    private func cuesSurfaceState(_ engine: CuesController) -> CuesSurfaceState {
        var state = CuesSurfaceState()
        state.listening = engine.isListening
        state.paused = engine.isPaused
        state.resolving = engine.isResolving
        state.cards = engine.surfaceCards
        state.canSend = zoomChatClient.isJoined && zoomChatBridge.isAttached
        state.open = { [weak self] card in self?.openCueCard(card) }
        state.send = { [weak self] card in self?.sendCueCard(card) }
        state.dismiss = { [weak self] card in
            guard let self, #available(macOS 26.0, *) else { return }
            self.cues?.dismiss(card)
            self.syncCuesSurfaces()
        }
        return state
    }

    // MARK: Actions

    /// Opens the card in the main-pane browser without pulling focus: the
    /// Greenroom Browser gets a background tab; any other browser is asked
    /// to open the URL without activating.
    func openCueCard(_ card: CueCard) {
        Analytics.feature("prompter_open", source: card.source.analyticsCode)
        // A dictionary card opens in Dictionary.app, not a browser: it never
        // was a web page, and nothing is sent.
        guard card.url.scheme == "https" || card.url.scheme == "http" else {
            NSWorkspace.shared.open(card.url)
            log("Cues: opened \u{201C}\(card.title)\u{201D} in Dictionary.")
            return
        }
        if AppCatalog.isBuiltInBrowser(mainAppBundleID) {
            BrowserWindowController.open(card.url, focus: false, layout: workspaceLayout)
            log("Cues: opened \u{201C}\(card.title)\u{201D} in Greenroom Browser.")
        } else {
            let name = mainAppDisplayName
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            if AppCatalog.isBrowser(mainAppBundleID), let appURL = AppCatalog.appURL(forBundleID: mainAppBundleID) {
                NSWorkspace.shared.open([card.url], withApplicationAt: appURL, configuration: configuration) { _, _ in }
            } else {
                NSWorkspace.shared.open(card.url, configuration: configuration) { _, _ in }
            }
            log("Cues: opened \u{201C}\(card.title)\u{201D} in \(name).")
        }
        if let folder = sessionFolder {
            SessionMetadata.recordLink(in: folder, kind: card.kind.rawValue, title: card.title,
                                       url: card.url.absoluteString, action: "opened")
        }
        ToastController.show("Opened in \(AppCatalog.isBuiltInBrowser(mainAppBundleID) ? "Greenroom Browser" : mainAppDisplayName)",
                             detail: card.title, dismissAfter: 2)
    }

    /// Posts the bare URL to everyone in the meeting chat. Zoom linkifies it.
    func sendCueCard(_ card: CueCard) {
        guard zoomChatClient.isJoined, zoomChatBridge.isAttached else {
            ToastController.show("Chat is not connected", detail: "Open the chat window first, then Send.", kind: .failure)
            return
        }
        // A word card has no page to send; the class gets the definition.
        let message = card.kind == .word ? "\(card.title): \(card.subtitle)" : card.url.absoluteString
        zoomChatBridge.send(message)
        Analytics.feature("prompter_send", source: card.source.analyticsCode)
        log("Cues: sent \(card.kind == .word ? "the definition of \u{201C}\(card.title)\u{201D}" : card.url.absoluteString) to the class chat.")
        if let folder = sessionFolder {
            SessionMetadata.recordLink(in: folder, kind: card.kind.rawValue, title: card.title,
                                       url: card.url.absoluteString, action: "sent")
        }
        ToastController.show("Sent to the class chat", detail: card.title, dismissAfter: 2)
    }
}
