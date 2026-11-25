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
    /// where the editor is adding now; `hasSecondDisplay` is whether the layout has a second arrangement.
    static func blockReason(slot: LayoutSlot, existing: [LayoutPiece.Kind], hasSecondDisplay: Bool) -> String? {
        if canAdd(to: slot, existing: existing) { return nil }
        if existing.contains(where: { $0.isRoomScreen }) { return "Already in this layout" }
        if slot == .main {
            return hasSecondDisplay
                ? "The Room screen goes on the second display"
                : "Needs a second display, set as extended, not mirrored. Add a second display first."
        }
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
        /// The compositor's picture without the owner's camera (R47, "Show my camera" off).
        case compositorWithoutCamera
        /// The Room screen's own capture of the shared display, same filter.
        case ownDisplay
    }

    /// A live compositor is the one source of truth; without one the screen runs
    /// its own capture.
    /// "Show my camera" off takes the compositor's camera-less picture. The own capture never has the
    /// camera: the bubble is a Greenroom window, left out with the whole app.
    static func source(compositorRunning: Bool, showsMyCamera: Bool = true) -> Source {
        guard compositorRunning else { return .ownDisplay }
        return showsMyCamera ? .compositor : .compositorWithoutCamera
    }

    /// The Room screen inspector's one row (R47).
    static let showMyCameraLabel = "Show my camera"
    static let showMyCameraTip = "Draws your webcam on the screen in the room, as everyone in the meeting sees it. Off, the room sees the same picture without your camera."

    /// Which display the own capture takes: the shared one, never the room display
    /// itself (it would show itself), else the main one.
    static func captureDisplay(preferred: String, roomDisplay: String, main: String?) -> String {
        if !preferred.isEmpty, preferred != roomDisplay { return preferred }
        return main ?? preferred
    }

    /// True when the piece fills the whole display (the layout builder's "full" rectangle, a hair of
    /// rounding allowed): the window then goes into native full screen on that display.
    static func isFullDisplay(_ rect: UnitRect) -> Bool {
        let t = 0.005
        return rect.x <= t && rect.y <= t && rect.maxX >= 1 - t && rect.maxY >= 1 - t
    }

    /// One thing `RoomScreen.place` does to the window.
    enum PlaceStep: Equatable {
        case setFrame(CGRect)
        case enterFullScreen
        case leaveFullScreen
    }

    /// What placing the piece does to the window (R46). It is a real window: a full piece goes into
    /// macOS full screen on its display (framed there first, so leaving full screen lands on that
    /// display), a smaller piece is a window at its rect. Once the owner has moved, resized or
    /// changed its full screen by hand, nothing: Greenroom leaves it where they put it.
    static func placeSteps(rect: UnitRect, pieceFrame: CGRect, currentFrame: CGRect?,
                           isFullScreen: Bool, ownerTookOver: Bool) -> [PlaceStep] {
        if ownerTookOver { return [] }
        let alreadyThere = currentFrame.map { !LayoutResolver.differs($0, from: pieceFrame, tolerance: 0.5) } ?? false
        let frame: [PlaceStep] = alreadyThere ? [] : [.setFrame(pieceFrame)]
        if isFullDisplay(rect) { return isFullScreen ? [] : frame + [.enterFullScreen] }
        return (isFullScreen ? [.leaveFullScreen] : []) + (isFullScreen ? [.setFrame(pieceFrame)] : frame)
    }

    /// Tells the owner's changes to the window from Greenroom's own. Our `setFrame` calls run
    /// between `beginPlacing` and `endPlacing`; full screen animates, so a change we asked for is expected until it ends.
    struct Ownership {
        enum Change { case moveOrResize, fullScreenWillChange, fullScreenDidChange }

        private(set) var ownerTookOver = false
        private var placingNow = false
        private var oursExpected = false
        private var inTransition = false

        /// Around our own `setFrame`. Two calls, not a closure: the window reports the resize through the
        /// same shared value while `setFrame` runs, and a mutating closure would hold it open (exclusivity
        /// crash at Start, 2026-11-26).
        mutating func beginPlacing() { placingNow = true }
        mutating func endPlacing() { placingNow = false }

        mutating func expectOurFullScreenChange() { oursExpected = true }

        mutating func windowChanged(_ change: Change) {
            switch change {
            case .moveOrResize:
                if !placingNow && !inTransition { ownerTookOver = true }
            case .fullScreenWillChange:
                if !oursExpected { ownerTookOver = true }
                inTransition = true
            case .fullScreenDidChange:
                inTransition = false
                oursExpected = false
            }
        }
    }

    /// The capture's largest size: the room display's pixels.
    static func streamSize(roomPoints: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: max(2, (roomPoints.width * max(scale, 1)).rounded()),
               height: max(2, (roomPoints.height * max(scale, 1)).rounded()))
    }
}
