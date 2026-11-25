//
//  LayoutDisplayCrossing.swift
//  Greenroom
//
//  Two pure rules of a layout's two-display version, Foundation only so the
//  tests compile them:
//    1. moving a piece from one display's canvas to the other (drag, or
//       Option-arrow), and
//    2. "Everyone sees": which display the meeting sees and recordings film.
//
import CoreGraphics
import Foundation

/// Why a piece could not cross to the other display. `message` is the short
/// reason the target canvas shows.
enum LayoutPieceMoveRefusal: Error, Equatable {
    case notFound, needsTwoDisplays, sameDisplay, roomScreenOnSecondOnly, roomScreenOnSharedDisplay, noRoom

    var message: String {
        switch self {
        case .notFound: return "That piece is not in this layout."
        case .needsTwoDisplays: return "Add a second display first."
        case .sameDisplay: return "It is already on that display."
        case .roomScreenOnSecondOnly: return "The Room screen can only sit on the second display."
        case .roomScreenOnSharedDisplay: return "Everyone sees the second display, so the Room screen would show itself."
        case .noRoom: return "No room there. Make some space first."
        }
    }
}

extension LayoutTemplate {

    /// Where `id` would land on display `to` if dropped with its middle at `pointer`
    /// (0...1 of that display), or why not. It keeps its size in points where the
    /// other display's grid allows (never below its minimum, never past the
    /// display), snaps to the grid and, if the spot is taken, goes to the largest
    /// free space under the pointer. A Meeting that fills its display stops filling
    /// and gets the size of a new Meeting.
    func placementForMove(_ id: UUID, from: LayoutSlot, to: LayoutSlot, at pointer: CGPoint,
                          fromDisplay: CGSize, toDisplay: CGSize,
                          snapThreshold: Double = 0) -> Result<UnitRect, LayoutPieceMoveRefusal> {
        guard twoDisplays != nil else { return .failure(.needsTwoDisplays) }
        guard from != to else { return .failure(.sameDisplay) }
        guard let piece = pieces(for: from).first(where: { $0.id == id }) else { return .failure(.notFound) }
        if piece.kind.isRoomScreen {
            guard to == .second else { return .failure(.roomScreenOnSecondOnly) }
            if twoDisplays?.sharedSlot == .second { return .failure(.roomScreenOnSharedDisplay) }
        }
        let cell = LayoutGeometry.cell
        let minimum = LayoutGeometry.minimumCells(for: piece.kind, display: toDisplay)
        var cols: Int, rows: Int
        if case .meeting(true, _) = piece.kind {
            let wanted = LayoutGeometry.defaultCells(for: piece.kind)
            cols = wanted.cols; rows = wanted.rows
        } else {
            cols = Int((piece.rect.w * Double(fromDisplay.width) / (max(toDisplay.width, 1) / Double(LayoutGeometry.divisions))).rounded())
            rows = Int((piece.rect.h * Double(fromDisplay.height) / (max(toDisplay.height, 1) / Double(LayoutGeometry.divisions))).rounded())
        }
        cols = min(max(cols, minimum.cols), LayoutGeometry.divisions)
        rows = min(max(rows, minimum.rows), LayoutGeometry.divisions)
        let w = Double(cols) * cell, h = Double(rows) * cell
        let origin = CGPoint(x: min(max(Double(pointer.x) - w / 2, 0), 1 - w),
                             y: min(max(Double(pointer.y) - h / 2, 0), 1 - h))
        let others = pieces(for: to).map(\.rect)
        let snapped = LayoutGeometry.snapMove(UnitRect(x: 0, y: 0, w: w, h: h), toOrigin: origin,
                                              neighbours: others, threshold: snapThreshold).rect
        // The grid, so a drop never leaves an off-grid rectangle behind.
        let onGrid = UnitRect(x: min(max(LayoutGeometry.gridLine(nearest: snapped.x), 0), 1 - w),
                              y: min(max(LayoutGeometry.gridLine(nearest: snapped.y), 0), 1 - h), w: w, h: h)
        let rect = snapThreshold > 0 && !LayoutGeometry.hasOverlap(snapped, with: others) ? snapped : onGrid
        let minUnit = LayoutGeometry.minimumUnitSize(for: piece.kind, display: toDisplay)
        guard let landed = LayoutGeometry.resolveDrop(rect, pointer: pointer, others: others, minimum: minUnit) else {
            return .failure(.noRoom)
        }
        return .success(landed)
    }

    /// The template with `id` moved to the other display, or why not. The piece keeps
    /// its id and settings; only its place (and a Meeting's "fills the display") change.
    func movingPiece(_ id: UUID, from: LayoutSlot, to: LayoutSlot, at pointer: CGPoint,
                     fromDisplay: CGSize, toDisplay: CGSize,
                     snapThreshold: Double = 0) -> Result<LayoutTemplate, LayoutPieceMoveRefusal> {
        placementForMove(id, from: from, to: to, at: pointer, fromDisplay: fromDisplay, toDisplay: toDisplay,
                         snapThreshold: snapThreshold).map { rect in
            var out = self
            var source = out.pieces(for: from)
            guard let i = source.firstIndex(where: { $0.id == id }) else { return self }
            var piece = source.remove(at: i)
            piece.rect = rect
            if case let .meeting(true, hidden) = piece.kind { piece.kind = .meeting(fillsDisplay: false, startsHidden: hidden) }
            out.setPieces(source, for: from)
            out.setPieces(out.pieces(for: to) + [piece], for: to)
            return out
        }
    }

    /// The second arrangement has pieces: the layout does something on a second display.
    var usesSecondDisplay: Bool { !(twoDisplays?.second.isEmpty ?? true) }

    // MARK: Everyone sees

    /// A Room screen on the second display shows what everyone sees, so that display
    /// cannot be the one that is shared.
    var canShareSecondDisplay: Bool {
        !(twoDisplays?.second.contains { $0.kind.isRoomScreen } ?? false)
    }

    /// The chosen display, with a hand-edited file that asks for the impossible kept on main.
    var effectiveSharedSlot: LayoutSlot {
        twoDisplays?.sharedSlot == .second && canShareSecondDisplay ? .second : .main
    }

    /// Why the Room screen cannot be added to the second display because of "Everyone sees".
    var roomScreenBlockReason: String? {
        twoDisplays?.sharedSlot == .second ? LayoutPieceMoveRefusal.roomScreenOnSharedDisplay.message : nil
    }
}

/// Which display the meeting sees and recordings film, for a layout's two-display version.
enum LayoutSharedDisplay {

    /// The display to capture while this layout's two-display version is in use, or nil
    /// (leave the Screen choice alone): no layout, a one-display layout, or no second
    /// display connected (the one-display version then runs on the main display, which is
    /// what is shared). Picks the second display exactly as `LayoutResolver.resolve` does.
    static func uuid(template: LayoutTemplate?, screens: [LayoutScreen]) -> String? {
        guard let two = template?.twoDisplays, let template,
              let main = screens.first(where: \.isMain) ?? screens.first else { return nil }
        let others = screens.filter { $0.id != main.id }
        guard let second = (!two.secondUUID.isEmpty ? others.first { $0.id == two.secondUUID } : nil) ?? others.first
        else { return nil }
        return template.effectiveSharedSlot == .second ? second.id : main.id
    }

    /// The canvas the camera overlay belongs on: the display everyone sees. A layout with no second
    /// arrangement has only main; a shared second that is not connected falls back to main,
    /// as the capture does (`uuid` is nil then).
    static func cameraSlot(template: LayoutTemplate, secondConnected: Bool) -> LayoutSlot {
        guard template.twoDisplays != nil else { return .main }
        return template.effectiveSharedSlot == .second && secondConnected ? .second : .main
    }

    /// The display the stage captures: the layout's choice for a whole-screen share,
    /// else the Screen choice. A window or app is captured where it is.
    static func resolved(wholeScreen: Bool, layout: String?, chosen: String) -> String {
        guard wholeScreen, let layout else { return chosen }
        return layout
    }
}

// MARK: - Canvas keys

enum LayoutKey: Equatable { case delete, deleteForward, left, right, up, down, tab, escape }

enum LayoutKeyAction: Equatable {
    case remove, deselect, sendToOtherDisplay, ignore, cancelDrag
    case nudge(cols: Int, rows: Int)
    case grow(cols: Int, rows: Int)
    case cycle(backwards: Bool)
}

/// What each key does on a layout canvas (the hint row: "Arrows move it, Shift-arrows resize it,
/// Option-arrows send it to the other display, Delete removes it").
enum LayoutKeyRules {
    static func action(for key: LayoutKey, shift: Bool, option: Bool,
                       hasSelection: Bool, hasOtherDisplay: Bool,
                       isDragging: Bool = false) -> LayoutKeyAction {
        switch key {
        case .tab: return .cycle(backwards: shift)
        case .escape: return isDragging ? .cancelDrag : (hasSelection ? .deselect : .ignore)
        case .delete, .deleteForward: return hasSelection ? .remove : .ignore
        case .left, .right, .up, .down:
            guard hasSelection else { return .ignore }
            if option, hasOtherDisplay, key == .left || key == .right { return .sendToOtherDisplay }
            let dx = key == .left ? -1 : (key == .right ? 1 : 0)
            let dy = key == .up ? -1 : (key == .down ? 1 : 0)
            return shift ? .grow(cols: dx, rows: dy) : .nudge(cols: dx, rows: dy)
        }
    }

    /// Reading order: top to bottom, then left to right, so Tab walks a canvas the way the eye does.
    static func readingOrder(_ pieces: [LayoutPiece]) -> [UUID] {
        pieces.sorted { ($0.rect.y, $0.rect.x) < ($1.rect.y, $1.rect.x) }.map(\.id)
    }

    /// Where Tab (or Shift-Tab) goes from `current` along `order`. nil means let go,
    /// so the keyboard moves on to the next canvas and is never trapped.
    static func cycleTarget(order: [UUID], current: UUID?, backwards: Bool) -> UUID? {
        guard !order.isEmpty else { return nil }
        guard let current, let at = order.firstIndex(of: current) else {
            return backwards ? order.last : order.first
        }
        let next = at + (backwards ? -1 : 1)
        return order.indices.contains(next) ? order[next] : nil
    }

    enum Removal: Equatable {
        case piece(UUID)
        /// The camera is not a piece; say so, and where to hide it instead.
        case notice(String)
        case nothing
    }

    static let cameraCannotBeRemoved = "Your camera can\u{2019}t be removed. Hide it on your screen instead."

    static func removal(selection: UUID?, cameraID: UUID) -> Removal {
        guard let selection else { return .nothing }
        return selection == cameraID ? .notice(cameraCannotBeRemoved) : .piece(selection)
    }
}
