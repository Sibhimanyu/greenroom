//
//  RoomScreenRules.swift
//  Greenroom
//
//  The pure rules of the Room screen piece: a window on a second display (a big
//  screen behind the teacher, set as extended, not mirrored) that shows what the
//  meeting sees, with Greenroom's private windows left out. Foundation only, so
//  the tests compile it.
//
import CoreGraphics
import Foundation

enum RoomScreenRules {

    /// The hide shortcut and "Starts hidden" are about the owner's own screen; the people in the
    /// room keep their view from Start to Stop, so the layout's hide never reaches the Room screen.
    static func isHidden(layoutHidden: Bool) -> Bool { false }

    /// The hint under the tile in the Add panel.
    static let hint = "What the meeting sees, for a screen in the room"
    static let title = "Room screen"
    static let symbol = "tv"

    /// At most one per layout, and only on the second display's arrangement: on the display it copies it would show itself.
    static func canAdd(to slot: LayoutSlot, existing: [LayoutPiece.Kind]) -> Bool {
        slot == .second && !existing.contains { $0.isRoomScreen }
    }

    /// Why the Add panel's tile is disabled, or nil when it can be added. `slot` is
    /// where the editor is adding now.
    static func blockReason(slot: LayoutSlot, existing: [LayoutPiece.Kind]) -> String? {
        if canAdd(to: slot, existing: existing) { return nil }
        if existing.contains(where: { $0.isRoomScreen }) { return "Already in this layout" }
        if slot == .main { return "Needs a second display, set as extended, not mirrored. Add a second display first." }
        return "Put it on the second display: on the main display it would show itself."
    }

    /// The Room screen to draw right now, or nil. Only the two-display variant
    /// qualifies, on its second slot, on a display that is not the main one. A
    /// mirrored set is one display, so the resolver gives the one-display variant
    /// and there is nothing to place; so does an unplugged second display.
    static func placement(in result: LayoutResolver.Result) -> LayoutResolver.Placed? {
        guard result.variant == .twoDisplays else { return nil }
        return result.placed.first { $0.piece.kind.isRoomScreen && $0.slot == .second && !$0.screen.isMain }
    }

    enum Source: Equatable {
        /// The compositor's own output frames: what the meeting gets, camera included.
        case compositor
        /// The Room screen's own capture of the shared display, same filter.
        case ownDisplay
    }

    /// A live compositor is the one source of truth; without one the screen runs
    /// its own capture.
    static func source(compositorRunning: Bool) -> Source { compositorRunning ? .compositor : .ownDisplay }

    /// Which display the own capture takes: the shared one, never the room display
    /// itself (it would show itself), else the main one.
    static func captureDisplay(preferred: String, roomDisplay: String, main: String?) -> String {
        if !preferred.isEmpty, preferred != roomDisplay { return preferred }
        return main ?? preferred
    }

    /// True when the piece fills the whole display (the layout builder's "full" rectangle, a hair of
    /// rounding allowed): the window then covers the display's entire frame, above the menu bar.
    static func isFullDisplay(_ rect: UnitRect) -> Bool {
        let t = 0.005
        return rect.x <= t && rect.y <= t && rect.maxX >= 1 - t && rect.maxY >= 1 - t
    }

    /// The window's frame: the display's whole frame (menu bar and Dock strips included) for a full
    /// piece, else the piece's own frame inside the usable area.
    static func windowFrame(pieceFrame: CGRect, rect: UnitRect, screenFrame: CGRect) -> CGRect {
        isFullDisplay(rect) ? screenFrame : pieceFrame
    }

    /// The capture's largest size: the room display's pixels.
    static func streamSize(roomPoints: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: max(2, (roomPoints.width * max(scale, 1)).rounded()),
               height: max(2, (roomPoints.height * max(scale, 1)).rounded()))
    }
}
