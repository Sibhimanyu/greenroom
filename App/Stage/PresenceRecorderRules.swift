//
//  PresenceRecorderRules.swift
//  Greenroom
//
//  What other apps' screen captures (screenshots, QuickTime, Loom, Zoom's own
//  share, OBS) may see of Greenroom. Decision 2026-11-25: all of it. Every
//  Greenroom window keeps the default sharingType (`.readOnly`), the Room screen
//  and the setup guide included (secrets are dotted in SecureFields instead).
//  The one exception is the camera bubble while the camera state is Only me,
//  a mirror for the owner alone (R6.5): `cameraBubbleSharing`. There is no
//  switch and no stored setting.
//  Greenroom's own capture is unaffected: StageScreenSource excludes the whole
//  app and lets back in only ShareVisibleWindows, and the compositor draws the
//  camera and drawings itself. `sharingType` only controls OTHER apps.
//  Foundation only (tests compile it).
//
import Foundation

enum PresenceRecorderRules {
    enum Sharing: Equatable { case readOnly, none }

    /// What the camera bubble panel's `NSWindow.sharingType` should be.
    static func cameraBubbleSharing(cameraState: CameraState) -> Sharing {
        cameraState == .onlyMe ? .none : .readOnly
    }

    /// The camera size the compositor works at; the feed never exceeds it.
    static let compositorCameraWidth: CGFloat = 1920

    /// Pixel width of the picture handed to the bubble: its real size on screen
    /// (points x backing scale), at least 1 px and at most the compositor's camera width.
    /// The bubble is always recordable (even Only me draws at this size), so there is no cheap cap.
    static func feedWidth(bubbleWidthPoints: CGFloat, backingScale: CGFloat) -> CGFloat {
        let pixels = (bubbleWidthPoints * max(backingScale, 1)).rounded(.up)
        return min(max(pixels, 1), compositorCameraWidth)
    }

    /// Fade after the pointer lets go: other apps can record the bubble, so its outline and
    /// handles show only while it is grabbed (and through this fade), never on mere hover.
    static let chromeFade: TimeInterval = 0.5
}
