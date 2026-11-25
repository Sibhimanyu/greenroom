//
//  RecorderVisibility.swift
//  Greenroom
//
//  Applies PresenceRecorderRules to the one window it ever hides from other apps'
//  captures: the camera bubble, `.none` while the camera state is Only me
//  (R6.5). Every other Greenroom window keeps the default sharingType and is not
//  registered anywhere. The window is held weakly.
//
//  This only controls OTHER apps. Greenroom's own capture (StageScreenSource)
//  excludes every Greenroom window through the app-wide filter, whatever
//  sharingType says.
//
import AppKit

@MainActor
enum RecorderVisibility {
    private static weak var bubble: NSWindow?

    /// The camera state the bubble is showing now. The coordinator sets it whenever the bubble is refreshed.
    static var cameraState: CameraState = .everyoneAndMe {
        didSet { if cameraState != oldValue { applyBubble() } }
    }

    /// Registers the camera bubble panel and sets its sharingType now.
    static func trackCameraBubble(_ window: NSWindow) {
        bubble = window
        applyBubble()
    }

    private static func applyBubble() {
        guard let window = bubble else { return }
        let wanted: NSWindow.SharingType =
            PresenceRecorderRules.cameraBubbleSharing(cameraState: cameraState) == .readOnly ? .readOnly : .none
        if window.sharingType != wanted { window.sharingType = wanted }
    }
}
