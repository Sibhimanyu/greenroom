//
//  ShareTargetModel.swift
//  Greenroom
//
//  The saved shape of a share target: what to share, nothing resolved. Split from
//  ShareTarget.swift so a layout can save one and the test target can compile it
//  without the window lookups.
//
import CoreGraphics
import Foundation

struct ShareTarget: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case display, app, window
        /// A white 16:9 page the user draws on (Whiteboard, phase 5 of the
        /// Recorditor port). It is the "screen" of the picture, so the camera
        /// composites over it with the user's own shape and position, but
        /// nothing is captured from the Mac.
        case whiteboard
        /// No shared content: the camera fills the frame on the backdrop.
        /// For a talking-head recording, or a meeting where the screen is
        /// shared some other way. The compositor lets the screen go and
        /// draws the camera alone - see `StageLayout.showsContent`.
        case nothing
        var id: String { rawValue }
        /// What the pickers offer. One app is gone (owner, 2026-11-16): one
        /// window says the same thing more simply. `.app` stays so a saved
        /// choice still decodes; it is read back as the whole screen.
        static var pickable: [Kind] { allCases.filter { $0 != .app } }

        var label: String {
            switch self {
            case .display: return "Whole screen"
            case .app: return "One app"
            case .window: return "One window"
            case .whiteboard: return "Whiteboard"
            case .nothing: return "Nothing"
            }
        }

        /// A picture comes from ScreenCaptureKit (a display, an app or a
        /// window). The whiteboard has content but captures nothing.
        var capturesScreen: Bool {
            switch self {
            case .display, .app, .window: return true
            case .whiteboard, .nothing: return false
            }
        }

    }

    var kind: Kind = .display
    /// Just my camera: nothing shared, the camera fills the picture.
    var sharesNothing: Bool { kind == .nothing }
    /// The app for `.app` and `.window`.
    var appBundleID: String = ""
    /// Kept so a saved app that is not running can still be named.
    var appName: String = ""
    /// `.window` only. Empty means the app's front window.
    var windowTitle: String = ""
    /// `.window` only: when the app opens a full-screen window (a slide show),
    /// the capture moves to it, and back when it ends. Phase 6 of the
    /// Recorditor port; see `SlideShowFollow`. On unless turned off.
    var followsSlideShow: Bool = true

    private enum CodingKeys: String, CodingKey {
        case kind, appBundleID, appName, windowTitle, followsSlideShow
    }

    init() {}

    /// Older saved targets have no `followsSlideShow`; they get the default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .display
        appBundleID = try c.decodeIfPresent(String.self, forKey: .appBundleID) ?? ""
        appName = try c.decodeIfPresent(String.self, forKey: .appName) ?? ""
        windowTitle = try c.decodeIfPresent(String.self, forKey: .windowTitle) ?? ""
        followsSlideShow = try c.decodeIfPresent(Bool.self, forKey: .followsSlideShow) ?? true
    }
}
