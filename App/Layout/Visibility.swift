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
//  Another app's broadcast badge is a real switch (on by default): off keeps that
//  app out of everyone's picture on a whole-display share (`hiddenAppIDs`, what the
//  capture excludes), and its eye off means it opens minimised (`opensMinimised`).
//  The Greenroom Browser always is in (ShareVisibilityRules.alwaysShared).
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
        /// The rule's view of a capture's own kind (what the DEBUG cross-check asks about).
        init(captureKind: ShowOnShare.ShareKind) {
            switch captureKind {
            case .display: self = .wholeScreen
            case .window, .app: self = .window(bundleID: nil)
            case .other: self = .justMe
            }
        }

        var shareKind: ShowOnShare.ShareKind {
            switch self {
            case .wholeScreen: return .display
            case .window: return .window
            case .whiteboard, .justMe: return .other
            }
        }
    }

    static let browserReason = "The Greenroom Browser is always in the picture"
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
                return piece.showsToEveryone ? .on : .off
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
        case let .app(app):
            if app.bundleID == builtInBrowserID { return .fixedOn(onYourScreenReason) }
            return app.opensMinimised ? .off : .on
        case .chat: return .fixedOn(onYourScreenReason)
        case .roomScreen: return .fixedOn("It sits on the room display")
        }
    }

    /// Another app whose eye is off opens (or is placed) minimised at Start.
    static func opensMinimised(piece: LayoutPiece) -> Bool {
        guard case let .app(app) = piece.kind, app.bundleID != builtInBrowserID else { return false }
        return app.opensMinimised
    }

    // MARK: The capture's app exclusion

    /// The bundle ids the capture leaves out of a whole-display share (and so out of
    /// recordings and the Room screen): other apps whose badge answer is off. An app
    /// with several pieces leaves only when every one of them says off. Derived from
    /// `everyoneSees` alone; other targets have no display filter, so nothing.
    static func hiddenAppIDs(pieces: [LayoutPiece], target: Target) -> Set<String> {
        guard case .wholeScreen = target else { return [] }
        var off: [String: Bool] = [:]
        for p in pieces {
            guard case let .app(app) = p.kind, !app.bundleID.isEmpty else { continue }
            let isOff = !everyoneSees(piece: p, target: target).isOn
            off[app.bundleID] = (off[app.bundleID] ?? true) && isOff
        }
        return Set(off.filter(\.value).keys)
    }

    // MARK: Camera

    static let justMeCameraReason = "Only your camera is shared, so everyone sees it"

    /// Does the meeting see the owner's camera? The one answer for every reader (the badge,
    /// the picture, the camera cards). Off and Only me hide it. The exception is Just my
    /// camera: the camera is then the whole picture, so it is always in (an empty backdrop
    /// would be no picture at all).
    static func cameraEveryoneSees(state: CameraState, target: Target) -> Badge {
        if target == .justMe { return .fixedOn(justMeCameraReason) }
        return state.everyoneSees ? .on : .off
    }

    static func cameraOnMyScreen(state: CameraState) -> Badge { state.iSee ? .on : .off }

    /// Only me: a mirror. The camera runs for the owner's bubble while the Stage leaves it out of
    /// everyone's picture (R6.4). Asked of the same two answers above, never of the state itself.
    static func cameraMirrorOnly(state: CameraState, target: Target) -> Bool {
        !cameraEveryoneSees(state: state, target: target).isOn && cameraOnMyScreen(state: state).isOn
    }

    /// Does the camera need to be open at all? For everyone's picture, or for the owner's mirror.
    /// Only Off closes it.
    static func cameraRuns(state: CameraState, target: Target) -> Bool {
        cameraEveryoneSees(state: state, target: target).isOn || cameraMirrorOnly(state: state, target: target)
    }

    // MARK: Flipping a badge

    enum Side { case me, everyone }

    /// The piece after a click on one of its badges. A fixed badge does not move. Turning 📡
    /// on turns 👁 on, since a window can't be everyone-but-not-me (R2.3); turning an own
    /// window's 👁 off turns its 📡 off. Another app's 👁 (opens minimised) never switches
    /// its 📡 off: that badge decides the capture filter alone.
    static func flipped(_ piece: LayoutPiece, side: Side) -> LayoutPiece {
        var p = piece
        switch side {
        case .everyone:
            guard !everyoneSees(piece: piece, target: .wholeScreen).isFixed else { return piece }
            p.showsToEveryone.toggle()
            if p.showsToEveryone {
                switch p.kind {
                case let .meeting(fills, _): p.kind = .meeting(fillsDisplay: fills, startsHidden: false)
                case let .view(view, _): p.kind = .view(view, startsHidden: false)
                case var .app(app): app.opensMinimised = false; p.kind = .app(app)
                case .chat, .roomScreen: break
                }
            }
        case .me:
            guard !onMyScreen(piece: piece).isFixed else { return piece }
            switch p.kind {
            case let .meeting(fills, hidden): p.kind = .meeting(fillsDisplay: fills, startsHidden: !hidden)
            case let .view(view, hidden): p.kind = .view(view, startsHidden: !hidden)
            case var .app(app): app.opensMinimised.toggle(); p.kind = .app(app); return p
            case .chat, .roomScreen: return piece
            }
            if !onMyScreen(piece: p).isOn { p.showsToEveryone = false }
        }
        return p
    }

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
