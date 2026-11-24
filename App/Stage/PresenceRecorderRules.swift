//
//  PresenceRecorderRules.swift
//  Greenroom
//
//  Whether other apps' screen recordings (QuickTime, Loom, OBS, a native Zoom
//  share) may capture Greenroom's on-screen windows, and what follows from it.
//  One switch ("Show Greenroom on screen in other apps' recordings", Settings
//  -> Webcam, default on) and one place for the decisions: each window kind's
//  sharingType (`sharing(for:visibleToRecorders:)`), the mirror the camera
//  bubble really draws, how sharp its picture is, and when its hover chrome
//  shows. The rule: other apps record Greenroom as the person sees it, except
//  windows that hold credentials, which are never recordable.
//  Greenroom's own capture is unaffected either way: StageScreenSource
//  excludes the whole app and lets back in only ShareVisibleWindows, and the
//  compositor draws the camera and drawings itself. `sharingType` only
//  controls OTHER apps. Foundation only (tests compile it).
//
import Foundation

enum PresenceRecorderRules {
    /// Settings -> Webcam -> "Show Greenroom on screen in other apps' recordings".
    /// Default on. The key predates the generalisation (it began as the camera
    /// bubble's switch in 1.9.1), so existing users keep their choice.
    static let key = "presence.visibleToRecorders"

    static var storedVisibleToRecorders: Bool {
        visibleToRecorders(stored: UserDefaults.standard.object(forKey: key) as? Bool)
    }

    static func visibleToRecorders(stored: Bool?) -> Bool { stored ?? true }

    /// What the bubble panel's `NSWindow.sharingType` should be.
    enum Sharing: Equatable { case readOnly, none }
    static func sharing(visibleToRecorders: Bool) -> Sharing { visibleToRecorders ? .readOnly : .none }

    /// Every Greenroom window whose sharingType this switch decides, plus the
    /// ones it never does. The meeting bar, notch island, Home, Settings and
    /// the other ordinary windows set no sharingType and stay as they are.
    enum WindowKind: CaseIterable {
        case annotationCanvas, annotationToolbar, annotationChrome
        case menuPanel, recordingControlBar, recordingBorder
        case whiteboard, cameraBubble, cameraBubbleStrip
        /// Credentials are typed here: always hidden.
        case setupGuide

        /// Windows that hold secrets ignore the switch.
        var alwaysHidden: Bool { self == .setupGuide }
    }

    static func sharing(for kind: WindowKind, visibleToRecorders: Bool) -> Sharing {
        kind.alwaysHidden ? .none : sharing(visibleToRecorders: visibleToRecorders)
    }

    /// The mirror the bubble draws. Others would record a reversed picture, so
    /// a bubble they can record is never mirrored.
    static func effectiveMirror(userMirror: Bool, visibleToRecorders: Bool) -> Bool {
        userMirror && !visibleToRecorders
    }

    /// "Mirror my camera" can be changed only while nobody can record the bubble.
    static func mirrorSettingEnabled(visibleToRecorders: Bool) -> Bool { !visibleToRecorders }
    static let mirrorDisabledNote = "Off while other apps can record Greenroom\u{2019}s windows."
    static let settingTitle = "Show Greenroom on screen in other apps\u{2019} recordings"
    static let settingNote = "Screen recorders like QuickTime and Loom see Greenroom as you do: your camera bubble, drawings, menus, bars and the whiteboard. Greenroom\u{2019}s own picture is unchanged."

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
