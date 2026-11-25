//
//  Visibility.swift
//  Greenroom
//
//  One truth for who sees what. The canvas badges (eye = you, broadcast = everyone),
//  Preview: Everyone and the capture's exception list all read this and nothing
//  else; no call site keeps its own rule. The switches over piece kinds and
//  window kinds have no `default`, so a new kind does not compile until it has an
//  answer. Foundation only, so the test target compiles this file as it is.
//
//  Other apps are always in a whole-display share for now (their own switch is a
//  later phase); the Greenroom Browser always is (ShareVisibilityRules.alwaysShared).
//
import Foundation

enum Visibility {
    /// An answer for one piece. `fixed` answers cannot be flipped: they are drawn
    /// as facts, with their reason, never as buttons.
    enum Badge: Equatable {
        case on, off
        case fixedOn(String), fixedOff(String)

        var isOn: Bool {
            switch self {
            case .on, .fixedOn: return true
            case .off, .fixedOff: return false
            }
        }

        var isFixed: Bool {
            switch self {
            case .on, .off: return false
            case .fixedOn, .fixedOff: return true
            }
        }

        var reason: String? {
            switch self {
            case let .fixedOn(r), let .fixedOff(r): return r
            case .on, .off: return nil
            }
        }
    }

    /// What is shared, as far as this rule cares.
    enum Target: Equatable {
        case wholeScreen
        /// One window (or the old "one app"); nil until one is chosen.
        case window(bundleID: String?)
        case whiteboard
        /// Just the camera (Share: Nothing).
        case justMe

        /// The same answer in the capture's own words.
        var shareKind: ShowOnShare.ShareKind {
            switch self {
            case .wholeScreen: return .display
            case .window: return .window
            case .whiteboard, .justMe: return .other
            }
        }
    }

    static let browserReason = "The Greenroom Browser is always in the picture"
    static let otherAppReason = "Other apps are always in the picture for now"
    static let roomScreenReason = "The Room screen shows the picture; it is never in it"
    static let whiteboardReason = "The whiteboard is the whole picture"
    static let justMeReason = "Only your camera is shared"
    static let chosenWindowReason = "This is the shared window"
    static let otherWindowReason = "Only the shared window is in the picture"
    static let onYourScreenReason = "Always on your screen"

    // MARK: Everyone

    /// Does the meeting see this piece?
    static func everyoneSees(piece: LayoutPiece, target: Target) -> Badge {
        switch piece.kind {
        case .meeting: return windowBadge(.meetingWindow, marked: piece.showsToEveryone, target: target)
        case .chat: return windowBadge(.meetingChat, marked: piece.showsToEveryone, target: target)
        case .view: return windowBadge(.meetingView, marked: piece.showsToEveryone, target: target)
        case .roomScreen: return .fixedOff(roomScreenReason)
        case let .app(app):
            switch target {
            case let .window(chosen):
                return app.bundleID == chosen ? .fixedOn(chosenWindowReason) : .fixedOff(otherWindowReason)
            case .whiteboard, .justMe:
                return nothingElse(target)
            case .wholeScreen:
                if app.bundleID == builtInBrowserID { return windowBadge(.browser, marked: true, target: target) }
                return .fixedOn(otherAppReason)
            }
        }
    }

    /// Does the meeting see one of Greenroom's own windows? The capture's exception
    /// list (`ShowOnShare.exceptionIDs`) asks this too, per window.
    static func windowBadge(_ window: ShareableWindow, marked: Bool, target: Target) -> Badge {
        switch target {
        case .whiteboard, .justMe: return nothingElse(target)
        case .window: return .fixedOff(ShowOnShare.unavailableTip)
        case .wholeScreen:
            switch window {
            case .main, .settings, .meetingChat, .participants, .meetingWindow, .meetingView:
                return marked ? .on : .off
            case .browser:
                return ShareVisibilityRules.alwaysShared(windowKind: window) ? .fixedOn(browserReason) : (marked ? .on : .off)
            case .setupGuide, .controlBar, .island, .recordingChrome, .annotation, .drawingToolbar, .whiteboard:
                return .fixedOff(window.exclusionReason ?? "Never in the picture")
            }
        }
    }

    private static func nothingElse(_ target: Target) -> Badge {
        switch target {
        case .whiteboard: return .fixedOff(whiteboardReason)
        case .justMe: return .fixedOff(justMeReason)
        case .wholeScreen, .window: return .fixedOff(ShowOnShare.unavailableTip)
        }
    }

    // MARK: Me

    /// Is this piece on the owner's own screen? Only "Starts hidden" is a choice.
    static func onMyScreen(piece: LayoutPiece) -> Badge {
        switch piece.kind {
        case let .meeting(_, hidden), let .view(_, hidden): return hidden ? .off : .on
        case .chat, .app: return .fixedOn(onYourScreenReason)
        case .roomScreen: return .fixedOn("It sits on the room display")
        }
    }

    // MARK: Camera

    static func cameraEveryoneSees(state: CameraState, target: Target) -> Badge {
        state.everyoneSees ? .on : .off
    }

    static func cameraOnMyScreen(state: CameraState) -> Badge { state.iSee ? .on : .off }

    // MARK: Cross-check

    /// The pieces whose live window the capture's list disagrees with the rule
    /// about. Only fixed answers are demanded: a switchable window may have been
    /// flipped live, away from what the layout says.
    static func mismatches(windows: [(piece: LayoutPiece, number: Int)], target: Target, exceptionList: Set<Int>) -> [UUID] {
        windows.compactMap { w in
            let badge = everyoneSees(piece: w.piece, target: target)
            // A window or whiteboard share has no exception list; the rule still answers.
            let inList = exceptionList.contains(w.number)
            switch target {
            case .wholeScreen: return badge.isFixed && badge.isOn != inList ? w.piece.id : nil
            case .window, .whiteboard, .justMe: return inList ? w.piece.id : nil
            }
        }
    }

    /// AppCatalog.builtInBrowserID, repeated because this file must not need AppKit.
    static let builtInBrowserID = "com.sibhimanyu.greenroom.browser"
}
