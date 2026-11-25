//
//  VisibilitySymbols.swift
//  Greenroom
//
//  The one icon language for "who sees it" (owner decisions Q28 to Q33, spec R17).
//  Every surface (title bars, the Layouts canvas, the bar, Home, menus) asks this enum
//  for a symbol, a tint token and the spoken words; none spells an SF Symbol name for
//  these meanings itself (VisibilitySymbolsTests greps App/ for stragglers). The eye
//  means "everyone sees it" and nothing else. Foundation only, so the test target
//  compiles this file as it is; views map `Tint` onto MeetingTheme / Brand tokens.
//
import Foundation

enum VisibilitySymbol: Equatable {
    /// The eye: in the meeting's picture (open, amber) or only you (struck, neutral).
    case everyoneSees(Bool)
    /// A piece that starts hidden on the owner's screen. A dashed outline, never an icon.
    case startsHidden
    /// The camera's four states, in Zoom's icons.
    case camera(CameraState)
    case cameraOn, cameraOff
    /// "No camera connected": a camera with a question badge.
    case noCameraDevice
    case share, stopShare
    /// "Show on screen": bring the layout's windows up.
    case showOnScreen
    case blur
    /// Share nothing: just my camera.
    case shareNothing
    case hideMeetingWindow
    case screenRecordingPermission
    /// The camera picture has nobody in it ("Can't see you"). Never the eye: the eye is who sees the piece.
    case nobodyInCamera
    /// A layout with a second display.
    case twoDisplays
    /// A layout (or canvas) with no pieces: "Nothing moves".
    case noPieces

    enum Tint: Equatable {
        /// Amber: `MeetingTheme.netNS` in the meeting, `Brand.netText` in the app (DESIGN.md).
        case net
        /// Quiet: only you, or off.
        case neutral
        /// Ordinary control colour.
        case primary
    }

    /// The SF Symbol. Nil only for `startsHidden`, which is drawn as a dashed outline.
    var symbol: String? {
        switch self {
        case let .everyoneSees(on): return on ? "eye" : "eye.slash"
        case .startsHidden: return nil
        case let .camera(state): return state == .off ? "video.slash" : "video.fill"
        case .cameraOn: return "video.fill"
        case .cameraOff: return "video.slash"
        case .noCameraDevice: return "video"
        case .share: return "rectangle.on.rectangle"
        case .stopShare: return "rectangle.on.rectangle.slash"
        case .showOnScreen: return "rectangle.dashed"
        // SF Symbols 4 (macOS 13): dots thinning out, like a blur.
        case .blur: return "aqi.medium"
        case .shareNothing: return "video"
        // SF Symbols (macOS 12+): a rectangle struck through, "this window out of the way".
        case .hideMeetingWindow: return "rectangle.slash"
        case .screenRecordingPermission: return "rectangle.dashed.badge.record"
        // "The camera finds nobody": a person with a question mark (SF Symbols 2, macOS 11).
        case .nobodyInCamera: return "person.fill.questionmark"
        // Two monitors (SF Symbols 2). Not Share's glyph: a layout that spans two displays shares nothing extra.
        case .twoDisplays: return "display.2"
        // An empty layout: the same dashed rectangle as Show on screen, a placeholder rather than an action.
        case .noPieces: return "rectangle.dashed"
        }
    }

    /// A plain string for views that take a symbol name (empty for `startsHidden`, which has none).
    var name: String { symbol ?? "" }

    /// A small second symbol drawn on the corner of the first.
    var badge: String? {
        switch self {
        case .camera(.onlyMe): return "eye.slash"
        case .noCameraDevice: return "questionmark.circle.fill"
        default: return nil
        }
    }

    /// Drawn with a dashed outline: starts hidden on the owner's screen, or the camera
    /// that only everyone sees.
    var dashed: Bool {
        switch self {
        case .startsHidden, .camera(.onlyEveryone): return true
        default: return false
        }
    }

    var tint: Tint {
        switch self {
        case .everyoneSees(true): return .net
        case .everyoneSees(false), .cameraOff, .noCameraDevice, .startsHidden, .nobodyInCamera: return .neutral
        case let .camera(state): return state == .off ? .neutral : .primary
        default: return .primary
        }
    }

    /// Tooltips and VoiceOver. Never "class".
    var words: String {
        switch self {
        case let .everyoneSees(on): return on ? "Everyone sees this" : "Only you"
        case .startsHidden: return "Starts hidden on your screen"
        case let .camera(state): return state.name
        case .cameraOn: return "Camera on"
        case .cameraOff: return "Camera off"
        case .noCameraDevice: return "No camera connected"
        case .share: return "Share"
        case .stopShare: return "Stop sharing"
        case .showOnScreen: return "Show on screen"
        case .blur: return "Blur"
        case .shareNothing: return "Just my camera"
        case .hideMeetingWindow: return "Hide the meeting window"
        case .screenRecordingPermission: return "Screen recording"
        case .nobodyInCamera: return "Can\u{2019}t see you"
        case .twoDisplays: return "Two displays"
        case .noPieces: return "Nothing moves"
        }
    }
}
