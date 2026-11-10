//
//  ScreenWindowRules.swift
//  Greenroom
//
//  Which windows can give a picture, and where they are. Pure, so it can be
//  tested without a screen.
//
//  A window on another Space (or full screen on its own Space) is listed by
//  macOS as "not on screen", but ScreenCaptureKit's per-window filter follows
//  it there. So off-screen is no longer a reason to drop a window. What still
//  is: not an ordinary window (menus, the Dock), too small to be one, fully
//  transparent, or an off-screen window with no title, which is how every
//  app's hidden helper windows look. A minimised window looks like one on
//  another Space to these APIs and cannot be told apart here; the capture
//  itself reports it (see the no-picture check in StageScreenSource).
//
import CoreGraphics
import Foundation

enum ScreenWindowRules {
    /// Where a shareable window is, in the picker's words.
    enum Placement: Equatable {
        case here
        case fullScreenElsewhere
        case otherDesktop

        /// Appended to the window's name in the picker menu.
        var menuSuffix: String {
            switch self {
            case .here: return ""
            case .fullScreenElsewhere: return " \u{2014} full screen"
            case .otherDesktop: return " \u{2014} on another desktop"
            }
        }
    }

    /// The picker's size floor; drops toolbars, palettes, helper windows.
    static let minPickerSize = CGSize(width: 200, height: 150)

    /// Can this window be offered in the picker?
    static func isCandidate(layer: Int, size: CGSize, alpha: Double, onScreen: Bool, title: String) -> Bool {
        guard layer == 0, alpha > 0,
              size.width >= minPickerSize.width, size.height >= minPickerSize.height else { return false }
        return onScreen || !title.isEmpty
    }

    static func placement(onScreen: Bool, size: CGSize, displaySizes: [CGSize]) -> Placement {
        if onScreen { return .here }
        let full = displaySizes.contains { abs($0.width - size.width) < 2 && abs($0.height - size.height) < 2 }
        return full ? .fullScreenElsewhere : .otherDesktop
    }

    /// Can ScreenCaptureKit be asked for this window at all? (Zero-size and
    /// non-normal windows cannot give a picture.)
    static func isCapturable(layer: Int, size: CGSize) -> Bool {
        layer == 0 && size.width >= 50 && size.height >= 50
    }
}
