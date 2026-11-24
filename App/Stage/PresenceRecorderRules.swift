//
//  PresenceRecorderRules.swift
//  Greenroom
//
//  Whether other apps' screen recordings (QuickTime, Loom, OBS, a native Zoom
//  share) may capture the on-screen camera bubble, and what follows from it.
//  One place for the decisions: the window's sharingType, the mirror the
//  bubble really draws, how sharp its picture is, and when its hover chrome
//  shows. Greenroom's own capture is unaffected either way: StageScreenSource
//  excludes the whole app and the bubble is never listed in ShareVisibleWindows,
//  and the compositor draws the camera itself. Foundation only (tests compile it).
//
import Foundation

enum PresenceRecorderRules {
    /// Settings -> Webcam -> Camera. Default on.
    static let key = "presence.visibleToRecorders"

    static var storedVisibleToRecorders: Bool {
        visibleToRecorders(stored: UserDefaults.standard.object(forKey: key) as? Bool)
    }

    static func visibleToRecorders(stored: Bool?) -> Bool { stored ?? true }

    /// What the bubble panel's `NSWindow.sharingType` should be.
    enum Sharing: Equatable { case readOnly, none }
    static func sharing(visibleToRecorders: Bool) -> Sharing { visibleToRecorders ? .readOnly : .none }

    /// The mirror the bubble draws. Others would record a reversed picture, so
    /// a bubble they can record is never mirrored.
    static func effectiveMirror(userMirror: Bool, visibleToRecorders: Bool) -> Bool {
        userMirror && !visibleToRecorders
    }

    /// "Mirror my camera" can be changed only while nobody can record the bubble.
    static func mirrorSettingEnabled(visibleToRecorders: Bool) -> Bool { !visibleToRecorders }
    static let mirrorDisabledNote = "Off while other apps can record your bubble."
    static let settingNote = "Screen recorders like QuickTime and Loom capture your bubble. Greenroom\u{2019}s own picture never includes it twice."

    /// The camera size the compositor works at; the feed never exceeds it.
    static let compositorCameraWidth: CGFloat = 1920
    /// The cheap cap while the bubble is hidden from recorders.
    static let cheapFeedWidth: CGFloat = 640

    /// Pixel width of the picture handed to the bubble. Visible to recorders:
    /// the bubble's real size on screen (points x backing scale), at least the
    /// cheap cap's floor of 1 px and at most the compositor's camera width.
    static func feedWidth(visibleToRecorders: Bool, bubbleWidthPoints: CGFloat, backingScale: CGFloat) -> CGFloat {
        guard visibleToRecorders else { return cheapFeedWidth }
        let pixels = (bubbleWidthPoints * max(backingScale, 1)).rounded(.up)
        return min(max(pixels, 1), compositorCameraWidth)
    }

    /// Fade after the pointer lets go, while recorders can see the bubble.
    static let chromeFade: TimeInterval = 0.5

    /// Outline, handles and labels. Hidden from recorders: on hover as ever.
    /// Visible to recorders: only while the pointer is down or dragging (and
    /// through the fade after), never on mere hover.
    static func showsChrome(visibleToRecorders: Bool, hovering: Bool, interacting: Bool) -> Bool {
        visibleToRecorders ? interacting : (hovering || interacting)
    }
}
