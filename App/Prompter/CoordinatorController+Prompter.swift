//
//  CoordinatorController+Prompter.swift
//  Greenroom
//
//  Where Prompter meets the session: started when the meeting is live,
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

    /// Whether this Mac can run Prompter at all. Settings says why when not.
    var prompterAvailableOnThisMac: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// The engine, typed. Nil below macOS 26 or before the first start.
    @available(macOS 26.0, *)
    var prompter: PrompterController? {
        get { prompterEngine as? PrompterController }
    }

    @available(macOS 26.0, *)
    private func makePrompterIfNeeded() -> PrompterController {
        if let existing = prompterEngine as? PrompterController { return existing }
        let created = PrompterController()
        prompterEngine = created
        return created
    }

    @available(macOS 26.0, *)
    func prompterConfiguration() -> PrompterController.Configuration {
        var configuration = PrompterController.Configuration()
        configuration.localeIdentifier = prompterLocaleIdentifier
        configuration.videoSearch = prompterVideoSearch
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
    func startPrompterIfEnabled() {
        guard prompterEnabled else { return }
        guard #available(macOS 26.0, *) else {
            log("Prompter: not available on this Mac (macOS 26 required).")
            return
        }
        loadSecretsIfNeeded()
        let engine = makePrompterIfNeeded()
        let configuration = prompterConfiguration()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let started = await engine.start(configuration: configuration)
            self.prompterListening = started
            guard started else { return }
            self.prompterTickTask?.cancel()
            self.prompterTickTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.syncPrompterSurfaces()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            self.syncPrompterSurfaces()
        }
    }

    /// Stops listening and clears both surfaces. Safe to call at any time.
    func stopPrompter() {
        prompterTickTask?.cancel()
        prompterTickTask = nil
        prompterMenuBar.setVisible(false)
        if #available(macOS 26.0, *), let engine = prompter {
            engine.stop()
        }
        prompterListening = false
        prompterCardCount = 0
        ParticipantGridWindowController.applyPrompter(.empty)
    }

    func stopPrompterForClass() {
        guard #available(macOS 26.0, *), let engine = prompter else { return }
        engine.stopForClass()
        prompterTickTask?.cancel()
        prompterTickTask = nil
        prompterMenuBar.setVisible(false)
        prompterListening = false
        prompterCardCount = 0
        ParticipantGridWindowController.applyPrompter(.empty)
    }

    /// Once a second: mute → pause, and whichever surface applies gets the
    /// current state. Rail when the participants panel is open; otherwise the
    /// menu-bar item. Never both.
    func syncPrompterSurfaces() {
        guard #available(macOS 26.0, *), let engine = prompter, engine.isListening else {
            // The engine stopped on its own (no microphone, transcriber gave
            // up): the mirrors must say so or the menu bar keeps claiming it
            // is listening.
            prompterListening = false
            prompterPaused = false
            prompterCardCount = 0
            prompterMenuBar.setVisible(false)
            ParticipantGridWindowController.applyPrompter(.empty)
            return
        }
        engine.setPaused(zoomChatClient.isJoined && zoomChatClient.iAmMuted)
        prompterListening = true
        prompterCardCount = engine.cards.count
        prompterPaused = engine.isPaused

        let state = prompterSurfaceState(engine)
        prompterOnRail = ParticipantGridWindowController.isOpen
        if ParticipantGridWindowController.isOpen {
            prompterMenuBar.setVisible(false)
            ParticipantGridWindowController.applyPrompter(state)
            if !prompterSurfaceReported {
                prompterSurfaceReported = true
                Analytics.track(.surfaceShown, [.surface: "prompter", .placement: "reference_display"])
            }
            engine.markSeen()
        } else {
            ParticipantGridWindowController.applyPrompter(.empty)
            if !prompterMenuBar.isVisible {
                prompterMenuBar.setVisible(true)
                prompterMenuBar.onOpen = { [weak self] in
                    guard let self, #available(macOS 26.0, *) else { return }
                    self.prompter?.markSeen()
                    self.syncPrompterSurfaces()
                }
                prompterMenuBar.onStopForClass = { [weak self] in self?.stopPrompterForClass() }
                if !prompterSurfaceReported {
                    prompterSurfaceReported = true
                    Analytics.track(.surfaceShown, [.surface: "prompter", .placement: "menu_bar"])
                }
            }
            let statusText = engine.isPaused ? "Paused \u{2014} you are muted"
                : "Listening \u{00B7} on this Mac \u{00B7} \(engine.detectorName)"
            prompterMenuBar.apply(state, unseen: engine.unseenCount, statusText: statusText)
        }
    }

    @available(macOS 26.0, *)
    private func prompterSurfaceState(_ engine: PrompterController) -> PrompterSurfaceState {
        var state = PrompterSurfaceState()
        state.listening = engine.isListening
        state.paused = engine.isPaused
        state.resolving = engine.isResolving
        state.cards = engine.surfaceCards
        state.canSend = zoomChatClient.isJoined && zoomChatBridge.isAttached
        state.open = { [weak self] card in self?.openPrompterCard(card) }
        state.send = { [weak self] card in self?.sendPrompterCard(card) }
        state.dismiss = { [weak self] card in
            guard let self, #available(macOS 26.0, *) else { return }
            self.prompter?.dismiss(card)
            self.syncPrompterSurfaces()
        }
        return state
    }

    // MARK: Actions

    /// Opens the card in the main-pane browser without pulling focus: the
    /// Greenroom Browser gets a background tab; any other browser is asked
    /// to open the URL without activating.
    func openPrompterCard(_ card: PrompterCard) {
        Analytics.feature("prompter_open", source: card.source.analyticsCode)
        if AppCatalog.isBuiltInBrowser(mainAppBundleID) {
            BrowserWindowController.open(card.url, focus: false, layout: workspaceLayout)
            log("Prompter: opened \u{201C}\(card.title)\u{201D} in Greenroom Browser.")
        } else {
            let name = mainAppDisplayName
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            if AppCatalog.isBrowser(mainAppBundleID), let appURL = AppCatalog.appURL(forBundleID: mainAppBundleID) {
                NSWorkspace.shared.open([card.url], withApplicationAt: appURL, configuration: configuration) { _, _ in }
            } else {
                NSWorkspace.shared.open(card.url, configuration: configuration) { _, _ in }
            }
            log("Prompter: opened \u{201C}\(card.title)\u{201D} in \(name).")
        }
        if let folder = sessionFolder {
            SessionMetadata.recordLink(in: folder, kind: card.kind.rawValue, title: card.title,
                                       url: card.url.absoluteString, action: "opened")
        }
        ToastController.show("Opened in \(AppCatalog.isBuiltInBrowser(mainAppBundleID) ? "Greenroom Browser" : mainAppDisplayName)",
                             detail: card.title, dismissAfter: 2)
    }

    /// Posts the bare URL to everyone in the meeting chat. Zoom linkifies it.
    func sendPrompterCard(_ card: PrompterCard) {
        guard zoomChatClient.isJoined, zoomChatBridge.isAttached else {
            ToastController.show("Chat is not connected", detail: "Open the chat window first, then Send.", kind: .failure)
            return
        }
        zoomChatBridge.send(card.url.absoluteString)
        Analytics.feature("prompter_send", source: card.source.analyticsCode)
        log("Prompter: sent \(card.url.absoluteString) to the class chat.")
        if let folder = sessionFolder {
            SessionMetadata.recordLink(in: folder, kind: card.kind.rawValue, title: card.title,
                                       url: card.url.absoluteString, action: "sent")
        }
        ToastController.show("Sent to the class chat", detail: card.title, dismissAfter: 2)
    }
}
