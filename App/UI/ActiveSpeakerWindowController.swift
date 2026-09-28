//
//  ActiveSpeakerWindowController.swift
//  Greenroom
//
//  The dedicated live-speaker window, rebuilt to Zoom's documented custom-UI
//  flow, in this exact order: InMeeting -> three or more participants ->
//  get the container -> create a ZoomSDKActiveVideoElement -> register it
//  with the GENERIC createVideoElement() -> add its NSView to a visible
//  window -> setResolution -> startActiveView(true).
//
//  Two details differ from every earlier attempt, deliberately:
//  - Registration goes through createVideoElement(&element), the call the
//    documented flow shows, not the typed createActiveVideoElement().
//  - The element's view is inside a VISIBLE window before startActiveView is
//    called, so the renderer has a drawable from its first frame.
//
//  The element is created once and never recreated per speaker: Zoom switches
//  the rendered participant internally. The window controller is long-lived;
//  the element lives only while the meeting has three or more participants.
//
//  The name bar along the bottom is the participants panel's tile caption
//  (TileView in ParticipantGridWindow.swift) at the same size, so the two
//  surfaces read as one product. It follows ActiveVideoUserSignal - the
//  events Zoom switches this element on - rather than the panel's own
//  featured pick, so the caption names the person actually being drawn.
//
import AppKit
import ZoomSDK

final class ActiveSpeakerWindowController: NSWindowController, NSWindowDelegate {

    private var activeVideoElement: ZoomSDKActiveVideoElement?
    private var videoContainer: ZoomSDKVideoContainer?

    private let videoHostView = NSView()
    private let nameScrim = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private var speakerObserver: NSObjectProtocol?

    private static let baseTitle = "Active Speaker"

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.baseTitle
        // Black behind the video: letterboxing against window-background grey
        // reads as a rendering fault.
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.center()

        self.init(window: window)
        window.delegate = self
        setupVideoHost()
        setupNameBar()
        speakerObserver = NotificationCenter.default.addObserver(
            forName: ActiveVideoUserSignal.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSpeakerName() }
        }
        refreshSpeakerName()
    }

    deinit {
        if let speakerObserver { NotificationCenter.default.removeObserver(speakerObserver) }
    }

    private func setupVideoHost() {
        guard let contentView = window?.contentView else { return }
        videoHostView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(videoHostView)
        NSLayoutConstraint.activate([
            videoHostView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            videoHostView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            videoHostView.topAnchor.constraint(equalTo: contentView.topAnchor),
            videoHostView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    /// TileView's caption, restated: 26pt bar, black at 0.55, 13pt medium
    /// white, 8pt inset. Kept as literal numbers rather than a shared view
    /// because TileView is private to the panel; if one changes, change both.
    private func setupNameBar() {
        guard let contentView = window?.contentView else { return }
        // Layer-backed so the bar composites ABOVE the SDK's render surface.
        // Without it the order of sibling views over a layer-hosted video
        // view is not guaranteed, and the caption can vanish under the frame.
        contentView.wantsLayer = true
        nameScrim.wantsLayer = true
        nameScrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        nameScrim.translatesAutoresizingMaskIntoConstraints = false
        nameScrim.isHidden = true
        contentView.addSubview(nameScrim, positioned: .above, relativeTo: videoHostView)

        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = .white
        // A long display name truncates; it must never wrap into a second
        // line that the 26pt bar cannot hold.
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.cell?.truncatesLastVisibleLine = true
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameScrim.addSubview(nameLabel)

        NSLayoutConstraint.activate([
            nameScrim.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            nameScrim.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            nameScrim.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            nameScrim.heightAnchor.constraint(equalToConstant: 26),
            nameLabel.leadingAnchor.constraint(equalTo: nameScrim.leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: nameScrim.trailingAnchor, constant: -8),
            nameLabel.centerYAnchor.constraint(equalTo: nameScrim.centerYAnchor)
        ])
    }

    /// Re-reads the name from the SDK every time rather than caching it, so
    /// a rename mid-class shows up on the next signal.
    ///
    /// The title follows too. It is what Mission Control, the Window menu and
    /// Cmd-` show, where the bar is not visible, and nothing matches windows
    /// on this title (the main window's "Greenroom" is the only one looked up
    /// by name), so it is free to change.
    private func refreshSpeakerName() {
        let name = activeVideoElement == nil ? nil : Self.displayName(for: ActiveVideoUserSignal.currentUserID)
        nameLabel.stringValue = name ?? ""
        // Hidden, not blank: an empty dark strip over the video would read as
        // a caption that failed to load.
        nameScrim.isHidden = name == nil
        window?.title = name.map { "\(Self.baseTitle) \u{2014} \($0)" } ?? Self.baseTitle
    }

    /// The caption text for a user, in TileView's wording, or nil when the id
    /// does not resolve to someone in this meeting. That check is what keeps
    /// a stale id - a person who left, a user from the previous class - from
    /// captioning the picture.
    private static func displayName(for userID: UInt32?) -> String? {
        guard let userID,
              let action = ZoomSDK.shared().getMeetingService()?.getMeetingActionController(),
              let info = action.getUserByUserID(userID),
              !info.isInWaitingRoom() else { return nil }
        let raw = info.getUserName()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var name = raw.isEmpty ? "Guest" : raw
        if info.isMySelf() { name += " (you)" }
        if info.isHost() { name += " \u{00B7} host" }
        else if info.getUserRole() == UserRole_CoHost { name += " \u{00B7} co-host" }
        return name
    }

    /// Step 5-9 of the documented flow. Idempotent: an existing element is
    /// left alone, per the do-not-recreate rule.
    func startActiveSpeaker() {
        guard activeVideoElement == nil else { return }

        guard let meetingService = ZoomSDK.shared().getMeetingService(),
              let container = meetingService.getVideoContainer() else {
            ZoomMeetingSDKClient.videoLog("activeSpeakerWindow: no video container available")
            return
        }
        videoContainer = container

        // The window must be VISIBLE before the renderer starts - see header.
        showWindow(nil)
        window?.layoutIfNeeded()

        let element = ZoomSDKActiveVideoElement(frame: videoHostView.bounds)

        // The GENERIC registration call from the documented flow.
        var generic: ZoomSDKVideoElement = element
        let createResult = container.createVideoElement(&generic)
        guard createResult == ZoomSDKError_Success else {
            ZoomMeetingSDKClient.videoLog(
                "activeSpeakerWindow: createVideoElement FAILED result=\(createResult.rawValue)")
            return
        }
        activeVideoElement = element

        let zoomVideoView = element.getVideoView()
        zoomVideoView.frame = videoHostView.bounds
        zoomVideoView.autoresizingMask = [.width, .height]
        videoHostView.addSubview(zoomVideoView)
        refreshSpeakerName()

        // Conservative while debugging, per the spec - and 360p is the pane's
        // slot in the published budget anyway.
        let resolutionResult = element.setResolution(ZoomSDKVideoRenderResolution_360p)
        let startResult = element.startActiveView(true)

        ZoomMeetingSDKClient.videoLog(
            "activeSpeakerWindow: created via generic createVideoElement"
            + " create=\(createResult.rawValue)"
            + " setResolution=\(resolutionResult.rawValue)"
            + " startActiveView=\(startResult.rawValue)"
            + " hostSize=\(Int(videoHostView.bounds.width))x\(Int(videoHostView.bounds.height))"
            + " windowVisible=\(window?.isVisible == true)")
    }

    /// Steps 12-13: below three participants, or at meeting end.
    func stopActiveSpeaker() {
        guard let element = activeVideoElement else { return }
        let stopResult = element.startActiveView(false)
        let cleanResult = videoContainer?.clean(element) ?? ZoomSDKError_Success
        element.getVideoView().removeFromSuperview()
        activeVideoElement = nil
        // No picture, no caption.
        refreshSpeakerName()
        ZoomMeetingSDKClient.videoLog(
            "activeSpeakerWindow: stopped"
            + " startActiveView(false)=\(stopResult.rawValue)"
            + " clean=\(cleanResult.rawValue)")
    }

    /// Full teardown at meeting end. The container's delegate stays with
    /// ZoomMeetingSDKClient (it owns failure logging for every element), so
    /// only the reference is dropped here.
    func destroyActiveSpeaker() {
        stopActiveSpeaker()
        // Forget the speaker only when the meeting itself is over. Dropping
        // below three mid-class keeps it: Zoom only fires on a CHANGE, so a
        // window rebuilt for the same speaker would otherwise stay unnamed.
        if ZoomSDK.shared().getMeetingService()?.getMeetingStatus() != ZoomSDKMeetingStatus_InMeeting {
            ActiveVideoUserSignal.reset()
        }
        videoContainer = nil
        close()
    }

    var isShowingVideo: Bool { activeVideoElement != nil }

    // MARK: NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        guard let element = activeVideoElement else { return }
        _ = element.resize(videoHostView.bounds)
        element.getVideoView().frame = videoHostView.bounds
    }
}
