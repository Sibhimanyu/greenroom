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
import AppKit
import ZoomSDK

final class ActiveSpeakerWindowController: NSWindowController, NSWindowDelegate {

    private var activeVideoElement: ZoomSDKActiveVideoElement?
    private var videoContainer: ZoomSDKVideoContainer?

    private let videoHostView = NSView()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Active Speaker"
        // Black behind the video: letterboxing against window-background grey
        // reads as a rendering fault.
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.center()

        self.init(window: window)
        window.delegate = self
        setupVideoHost()
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
