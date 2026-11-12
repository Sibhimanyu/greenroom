#if DEBUG
//
//  ViewSpike.swift
//  Greenroom
//
//  Phase 0 of .context/meeting-views-plan.md: the go/no-go for showing the
//  meeting as several windows. Does a SECOND window draw live video from its own
//  normal render element, next to the meeting window's?
//
//  Hidden: it only runs when the default `meetingViews.spike` is true
//      defaults write com.sibhimanyu.greenroom meetingViews.spike -bool true
//  and a custom-UI meeting is live with the meeting window open. It opens one
//  non-activating panel, "Active speaker (test)", that shows whoever the stage
//  shows (spotlight, then pin, then the speaker) on an element of its own.
//  Everything it learns goes to ~/Library/Logs/Greenroom-video.log, lines that
//  start "View spike:". With the default off, nothing here does anything.
//
import AppKit
import ZoomSDK

@MainActor
final class ViewSpike {
    static let shared = ViewSpike()
    static let defaultsKey = "meetingViews.spike"
    static let windowTitle = "Active speaker (test)"

    private var panel: SpikePanel?
    private var task: Task<Void, Never>?
    private var closeObserver: NSObjectProtocol?
    private weak var client: ZoomMeetingSDKClient?

    private var element: ZoomSDKNormalVideoElement?
    private var userID: UInt32?
    private var subscribed = false
    private var lastFrame: NSRect = .zero
    private var nextSwitchAt = Date.distantPast
    private var subscribedAt: Date?
    private var gotVideo = false
    private var warnedNoVideo = false
    /// The teacher closed the test window: it stays closed until the next class.
    private var dismissed = false

    private let placeholder: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.alignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.isHidden = true
        return label
    }()

    private static func log(_ message: String) { ZoomMeetingSDKClient.videoLog("View spike: " + message) }

    // MARK: Called from the meeting window's one-second tick

    func sync(client: ZoomMeetingSDKClient, meetingWindowOpen: Bool) {
        let on = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        if !on {
            if panel != nil { close() }
            return
        }
        guard panel == nil, !dismissed, meetingWindowOpen, client.didUseCustomUI else { return }
        open(client: client)
    }

    /// Meeting over (or the default turned off): everything goes back.
    func close() {
        task?.cancel()
        task = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        releaseElement()
        unhook()
        let hadPanel = panel != nil
        panel?.close()
        panel = nil
        dismissed = false
        if hadPanel { Self.log("closed") }
    }

    // MARK: Opening

    private func open(client: ZoomMeetingSDKClient) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        self.client = client
        let area = screen.visibleFrame
        let frame = NSRect(x: area.maxX - 520, y: area.maxY - 360, width: 480, height: 270 + 28)
        let made = SpikePanel(contentRect: frame,
                              styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                              backing: .buffered, defer: false, screen: screen)
        made.title = Self.windowTitle
        made.isReleasedWhenClosed = false
        made.hidesOnDeactivate = false
        made.backgroundColor = .black
        made.level = .normal
        made.collectionBehavior = [.managed, .fullScreenAuxiliary]
        made.minSize = NSSize(width: 240, height: 135 + 28)
        let content = NSView(frame: NSRect(origin: .zero, size: made.contentRect(forFrameRect: frame).size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        made.contentView = content
        placeholder.frame = content.bounds.insetBy(dx: 16, dy: 16)
        placeholder.autoresizingMask = [.width, .height]
        content.addSubview(placeholder)

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: made, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel != nil else { return }
                self.dismissed = true
                self.task?.cancel()
                self.task = nil
                self.releaseElement()
                self.unhook()
                self.panel = nil
                Self.log("window closed by hand")
            }
        }
        panel = made
        // Render order, from the lesson of 028a189: show the window and lay it
        // out FIRST, create the element after, subscribe once it is visible.
        made.orderFrontRegardless()
        content.layoutSubtreeIfNeeded()
        Self.log("opened window '\(Self.windowTitle)'")

        client.onSpikeDataType = { [weak self] type in self?.dataType(type) }
        client.onSpikeSubscribeFail = { [weak self] code, user in
            guard let self else { return }
            self.showPlaceholder("Video didn\u{2019}t start in this window")
            _ = (code, user)
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: One second

    private func tick() {
        guard let panel, let client, let content = panel.contentView else { return }
        guard let person = client.spikeStagePerson() else {
            if element != nil { releaseElement() }
            showPlaceholder("Waiting for others")
            return
        }
        let bounds = content.bounds
        if element == nil {
            guard panel.isVisible else { return }
            let made = client.spikeCreateElement(frame: bounds, userID: person.id)
            guard let el = made.element else {
                Self.log("FAILED step=createNormalVideoElement code=\(made.code)")
                showPlaceholder("Video didn\u{2019}t start in this window")
                return
            }
            element = el
            userID = person.id
            lastFrame = bounds
            let view = el.getVideoView()
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            content.addSubview(view, positioned: .below, relativeTo: placeholder)
            let set = el.setResolution(ZoomSDKVideoRenderResolution_720p)
            if set != ZoomSDKError_Success {
                Self.log("FAILED step=setResolution code=\(set.rawValue)")
                _ = el.setResolution(ZoomSDKVideoRenderResolution_720p)
            }
            nextSwitchAt = Date().addingTimeInterval(2)
        }
        guard let el = element else { return }
        if lastFrame != bounds {
            lastFrame = bounds
            _ = el.resize(bounds)
        }
        if userID != person.id, Date() >= nextSwitchAt {
            _ = el.subscribeVideo(false)
            el.userid = person.id
            userID = person.id
            subscribed = false
            nextSwitchAt = Date().addingTimeInterval(2)   // faster risks code 7
            Self.log("stage person -> user=\(person.id)")
        }
        // Subscribe only once the window is actually on screen.
        if !subscribed, panel.isVisible {
            let sub = el.subscribeVideo(true)
            if sub == ZoomSDKError_Success {
                let shown = el.showVideo(true)
                if shown != ZoomSDKError_Success { Self.log("FAILED step=showVideo code=\(shown.rawValue)") }
                subscribed = true
                subscribedAt = Date()
                gotVideo = false
                warnedNoVideo = false
                showPlaceholder(nil)
                Self.log("subscribed user \(person.id) at 720p in window '\(Self.windowTitle)'")
            } else {
                Self.log("FAILED step=subscribeVideo code=\(sub.rawValue) user=\(person.id)")
            }
        }
        // Six seconds with the camera on and no video arriving: the failure
        // this whole spike exists to catch.
        if subscribed, !gotVideo, !warnedNoVideo, person.videoOn,
           let at = subscribedAt, Date().timeIntervalSince(at) >= 6 {
            warnedNoVideo = true
            Self.log("no video after 6s")
            showPlaceholder("Video didn\u{2019}t start in this window")
        }
    }

    private func dataType(_ type: VideoRenderDataType) {
        guard type == VideoRenderDataType_Video else { return }
        gotVideo = true
        if warnedNoVideo, let at = subscribedAt {
            Self.log("video arrived after \(Int(Date().timeIntervalSince(at)))s")
        }
        showPlaceholder(nil)
    }

    private func unhook() {
        client?.onSpikeDataType = nil
        client?.onSpikeSubscribeFail = nil
    }

    private func showPlaceholder(_ text: String?) {
        placeholder.stringValue = text ?? ""
        placeholder.isHidden = text == nil
    }

    private func releaseElement() {
        client?.spikeReleaseElement()
        element = nil
        userID = nil
        subscribed = false
        subscribedAt = nil
        gotVideo = false
        warnedNoVideo = false
    }
}

/// Never key and never main: it must not take focus from the meeting window.
private final class SpikePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
#endif
