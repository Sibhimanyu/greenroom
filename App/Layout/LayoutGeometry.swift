//
//  LayoutGeometry.swift
//  Greenroom
//
//  The arithmetic of the layout editor, with no AppKit and no views so it can
//  be tested on its own: a 12x12 grid, snapping to grid lines / display edges
//  / neighbour edges, overlap, the largest free rectangle, per-display
//  minimums, and unit rect -> NS / AX frames.
//
//  Everything works in UnitRects (0...1 of a display's usable area, origin at
//  the top-left). Rects are stored as plain Doubles; snapping happens only
//  while editing, so a migrated off-grid layout is kept exactly until touched.
//
import Foundation
import CoreGraphics

enum LayoutGeometry {

    static let divisions = 12
    static let cell = 1.0 / Double(divisions)
    static let epsilon = 1e-6

    // MARK: Handles

    /// The eight resize handles.
    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
        var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    }

    struct SnapResult: Equatable {
        var rect: UnitRect
        /// Lines the edit snapped to that are NOT plain grid lines (a display
        /// edge or a neighbour's edge): the editor draws a guide on each.
        var guidesX: [Double] = []
        var guidesY: [Double] = []
    }

    // MARK: Minimums

    /// Smallest sizes the pieces are usable at, in points: the meeting window's
    /// own minimum (ParticipantGridWindow), the chat's (ChatWindow) and a
    /// working size for an app.
    static func minimumPoints(for kind: LayoutPiece.Kind) -> CGSize {
        switch kind {
        case .meeting: return CGSize(width: 320, height: 200)
        case .chat: return CGSize(width: 280, height: 200)
        case .app: return CGSize(width: 400, height: 300)
        }
    }

    /// The minimum as whole grid cells on a display of `display` points, never
    /// more than the whole grid.
    static func minimumCells(for kind: LayoutPiece.Kind, display: CGSize) -> (cols: Int, rows: Int) {
        let min = minimumPoints(for: kind)
        let cols = Int((min.width / (max(display.width, 1) / Double(divisions))).rounded(.up))
        let rows = Int((min.height / (max(display.height, 1) / Double(divisions))).rounded(.up))
        return (Swift.min(max(cols, 1), divisions), Swift.min(max(rows, 1), divisions))
    }

    static func minimumUnitSize(for kind: LayoutPiece.Kind, display: CGSize) -> (w: Double, h: Double) {
        let c = minimumCells(for: kind, display: display)
        return (Double(c.cols) * cell, Double(c.rows) * cell)
    }

    /// A first size for a piece added from the palette, in cells.
    static func defaultCells(for kind: LayoutPiece.Kind) -> (cols: Int, rows: Int) {
        switch kind {
        case .meeting: return (4, 5)
        case .chat: return (3, 7)
        case .app: return (8, 12)
        }
    }

    // MARK: Grid

    static func gridLine(nearest value: Double) -> Double {
        (value * Double(divisions)).rounded() / Double(divisions)
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        Swift.min(Swift.max(v, lo), Swift.max(lo, hi))
    }

    /// 1-based cells a rect covers, for "columns 9 to 12, rows 6 to 12".
    static func cellSpan(of rect: UnitRect) -> (cols: ClosedRange<Int>, rows: ClosedRange<Int>) {
        func span(_ lo: Double, _ hi: Double) -> ClosedRange<Int> {
            let a = clamp((lo * Double(divisions)).rounded(), 0, Double(divisions - 1)) + 1
            let b = clamp((hi * Double(divisions)).rounded(), a, Double(divisions))
            return Int(a)...Int(b)
        }
        return (span(rect.x, rect.maxX), span(rect.y, rect.maxY))
    }

    /// The real size in points the piece will get on a display of `display`.
    static func pointSize(of rect: UnitRect, display: CGSize) -> (w: Int, h: Int) {
        (Int((rect.w * display.width).rounded()), Int((rect.h * display.height).rounded()))
    }

    // MARK: Snapping

    /// The lines a drag can stick to besides the grid: the display edges and
    /// every neighbour's edges.
    static func stickyLines(_ neighbours: [UnitRect], horizontal: Bool) -> [Double] {
        var lines: [Double] = [0, 1]
        for n in neighbours {
            lines += horizontal ? [n.x, n.maxX] : [n.y, n.maxY]
        }
        return lines
    }

    private static func nearest(_ value: Double, in lines: [Double]) -> (line: Double, delta: Double)? {
        lines.map { (line: $0, delta: $0 - value) }.min { abs($0.delta) < abs($1.delta) }
    }

    /// Snaps one edge: to a sticky line within `threshold` if there is one,
    /// otherwise to the nearest grid line.
    private static func snapEdge(_ value: Double, sticky: [Double], threshold: Double) -> (value: Double, guide: Double?) {
        if let n = nearest(value, in: sticky), abs(n.delta) <= threshold { return (n.line, n.line) }
        return (gridLine(nearest: value), nil)
    }

    /// One axis of a move: whichever of the two edges is nearer a sticky line
    /// wins, else whichever is nearer a grid line.
    private static func snapSpan(start: Double, length: Double, sticky: [Double], threshold: Double)
        -> (start: Double, guide: Double?) {
        var best: (delta: Double, guide: Double)?
        for edge in [start, start + length] {
            if let n = nearest(edge, in: sticky), abs(n.delta) <= threshold,
               best == nil || abs(n.delta) < abs(best!.delta) {
                best = (n.line - edge, n.line)
            }
        }
        var snapped: Double
        var guide: Double?
        if let best {
            snapped = start + best.delta
            guide = best.guide
        } else {
            let dl = gridLine(nearest: start) - start
            let dr = gridLine(nearest: start + length) - (start + length)
            snapped = start + (abs(dl) <= abs(dr) ? dl : dr)
        }
        snapped = clamp(snapped, 0, 1 - length)
        return (snapped, guide)
    }

    /// A drag of the whole piece: `origin` is where the pointer would put its
    /// top-left corner, unsnapped.
    static func snapMove(_ rect: UnitRect, toOrigin origin: CGPoint, neighbours: [UnitRect],
                         threshold: Double) -> SnapResult {
        let x = snapSpan(start: Double(origin.x), length: rect.w,
                         sticky: stickyLines(neighbours, horizontal: true), threshold: threshold)
        let y = snapSpan(start: Double(origin.y), length: rect.h,
                         sticky: stickyLines(neighbours, horizontal: false), threshold: threshold)
        var result = SnapResult(rect: UnitRect(x: x.start, y: y.start, w: rect.w, h: rect.h))
        if let g = x.guide { result.guidesX = [g] }
        if let g = y.guide { result.guidesY = [g] }
        return result
    }

    /// A drag of one handle by `delta` (unit space). Moving edges snap, the
    /// minimum size holds, and the piece stops at a neighbour's edge.
    static func snapResize(_ start: UnitRect, handle: Handle, delta: CGPoint, neighbours: [UnitRect],
                           minimum: (w: Double, h: Double), threshold: Double) -> SnapResult {
        var left = start.x, right = start.maxX, top = start.y, bottom = start.maxY
        var result = SnapResult(rect: start)
        let stickyX = stickyLines(neighbours, horizontal: true)
        let stickyY = stickyLines(neighbours, horizontal: false)

        func apply(_ value: Double, sticky: [Double], guides: inout [Double]) -> Double {
            let s = snapEdge(clamp(value, 0, 1), sticky: sticky, threshold: threshold)
            if let g = s.guide { guides.append(g) }
            return s.value
        }
        if handle.movesLeft { left = apply(start.x + Double(delta.x), sticky: stickyX, guides: &result.guidesX) }
        if handle.movesRight { right = apply(start.maxX + Double(delta.x), sticky: stickyX, guides: &result.guidesX) }
        if handle.movesTop { top = apply(start.y + Double(delta.y), sticky: stickyY, guides: &result.guidesY) }
        if handle.movesBottom { bottom = apply(start.maxY + Double(delta.y), sticky: stickyY, guides: &result.guidesY) }

        // Minimum size: the edge being dragged yields, the other holds.
        if handle.movesLeft { left = Swift.min(left, right - minimum.w) }
        if handle.movesRight { right = Swift.max(right, left + minimum.w) }
        if handle.movesTop { top = Swift.min(top, bottom - minimum.h) }
        if handle.movesBottom { bottom = Swift.max(bottom, top + minimum.h) }
        left = Swift.max(left, 0); top = Swift.max(top, 0)
        right = Swift.min(right, 1); bottom = Swift.min(bottom, 1)

        var proposed = UnitRect(x: left, y: top, w: right - left, h: bottom - top)
        let limited = limitResize(from: start, to: proposed, neighbours: neighbours)
        if limited != proposed {
            // The neighbour's edge, not a sticky line the drag chose: no guide.
            result.guidesX = result.guidesX.filter { limited.x == $0 || limited.maxX == $0 }
            result.guidesY = result.guidesY.filter { limited.y == $0 || limited.maxY == $0 }
            proposed = limited
        }
        result.rect = proposed
        return result
    }

    /// Stops a growing edge at the first neighbour in its way. A final overlap
    /// check falls back to the original rect rather than ever overlapping.
    static func limitResize(from original: UnitRect, to proposed: UnitRect, neighbours: [UnitRect]) -> UnitRect {
        var r = proposed
        let e = epsilon

        func overlapsY(_ n: UnitRect, _ rect: UnitRect) -> Bool { n.y < rect.maxY - e && n.maxY > rect.y + e }
        func overlapsX(_ n: UnitRect, _ rect: UnitRect) -> Bool { n.x < rect.maxX - e && n.maxX > rect.x + e }

        if r.maxX > original.maxX + e {
            if let limit = neighbours.filter({ overlapsY($0, r) && $0.x >= original.maxX - e }).map(\.x).min() {
                r.w = Swift.max(Swift.min(r.maxX, limit) - r.x, 0)
            }
        }
        if r.x < original.x - e {
            if let limit = neighbours.filter({ overlapsY($0, r) && $0.maxX <= original.x + e }).map(\.maxX).max() {
                let right = r.maxX
                r.x = Swift.max(r.x, limit)
                r.w = right - r.x
            }
        }
        if r.maxY > original.maxY + e {
            if let limit = neighbours.filter({ overlapsX($0, r) && $0.y >= original.maxY - e }).map(\.y).min() {
                r.h = Swift.max(Swift.min(r.maxY, limit) - r.y, 0)
            }
        }
        if r.y < original.y - e {
            if let limit = neighbours.filter({ overlapsX($0, r) && $0.maxY <= original.y + e }).map(\.maxY).max() {
                let bottom = r.maxY
                r.y = Swift.max(r.y, limit)
                r.h = bottom - r.y
            }
        }
        return hasOverlap(r, with: neighbours) ? original : r
    }

    // MARK: Overlap

    static func same(_ a: UnitRect, _ b: UnitRect) -> Bool {
        abs(a.x - b.x) < epsilon && abs(a.y - b.y) < epsilon && abs(a.w - b.w) < epsilon && abs(a.h - b.h) < epsilon
    }

    /// Rectangles that only share an edge do not overlap.
    static func overlaps(_ a: UnitRect, _ b: UnitRect) -> Bool {
        a.x < b.maxX - epsilon && b.x < a.maxX - epsilon
            && a.y < b.maxY - epsilon && b.y < a.maxY - epsilon
    }

    static func hasOverlap(_ rect: UnitRect, with others: [UnitRect]) -> Bool {
        others.contains { overlaps(rect, $0) }
    }

    // MARK: Free space

    /// Which of the 12x12 cells any rect touches.
    static func occupancy(of rects: [UnitRect]) -> [[Bool]] {
        var grid = Array(repeating: Array(repeating: false, count: divisions), count: divisions)
        for row in 0..<divisions {
            for col in 0..<divisions {
                let c = UnitRect(x: Double(col) * cell, y: Double(row) * cell, w: cell, h: cell)
                grid[row][col] = rects.contains { overlaps($0, c) }
            }
        }
        return grid
    }

    /// The largest rectangle of untouched cells, optionally one that contains
    /// the cell under `point` (unit space), at least `minCols` x `minRows`.
    /// Ties go to the one nearest the point, then the top-left.
    static func largestFreeRect(avoiding rects: [UnitRect], containing point: CGPoint? = nil,
                                minCols: Int = 1, minRows: Int = 1) -> UnitRect? {
        let grid = occupancy(of: rects)
        let n = divisions
        // Prefix sums of occupied cells: a candidate is free when its sum is 0.
        var sum = Array(repeating: Array(repeating: 0, count: n + 1), count: n + 1)
        for r in 0..<n { for c in 0..<n {
            sum[r + 1][c + 1] = sum[r][c + 1] + sum[r + 1][c] - sum[r][c] + (grid[r][c] ? 1 : 0)
        } }
        func occupied(_ r0: Int, _ c0: Int, _ r1: Int, _ c1: Int) -> Int {
            sum[r1][c1] - sum[r0][c1] - sum[r1][c0] + sum[r0][c0]
        }
        let pc = point.map { Int(clamp(Double($0.x) * Double(n), 0, Double(n - 1)).rounded(.down)) }
        let pr = point.map { Int(clamp(Double($0.y) * Double(n), 0, Double(n - 1)).rounded(.down)) }

        var best: (r0: Int, c0: Int, r1: Int, c1: Int)?
        var bestArea = 0
        var bestDistance = Double.infinity
        for r0 in 0..<n { for c0 in 0..<n { for r1 in (r0 + 1)...n {
            for c1 in (c0 + 1)...n {
                guard occupied(r0, c0, r1, c1) == 0 else { break }   // wider only gets worse
                guard c1 - c0 >= minCols, r1 - r0 >= minRows else { continue }
                if let pc, let pr, !(c0 <= pc && pc < c1 && r0 <= pr && pr < r1) { continue }
                let area = (r1 - r0) * (c1 - c0)
                let cx = Double(c0 + c1) / 2, cy = Double(r0 + r1) / 2
                let d = point.map { hypot(cx / Double(n) - Double($0.x), cy / Double(n) - Double($0.y)) } ?? 0
                if area > bestArea || (area == bestArea && d < bestDistance - 1e-9) {
                    best = (r0, c0, r1, c1); bestArea = area; bestDistance = d
                }
            }
        } } }
        guard let b = best else { return nil }
        return UnitRect(x: Double(b.c0) * cell, y: Double(b.r0) * cell,
                        w: Double(b.c1 - b.c0) * cell, h: Double(b.r1 - b.r0) * cell)
    }

    /// A piece of `size` placed inside `free`, as near `origin` as it fits, on
    /// the grid.
    static func fit(size: (w: Double, h: Double), into free: UnitRect, near origin: CGPoint) -> UnitRect {
        let w = Swift.min(size.w, free.w), h = Swift.min(size.h, free.h)
        let x = clamp(gridLine(nearest: Double(origin.x)), free.x, free.maxX - w)
        let y = clamp(gridLine(nearest: Double(origin.y)), free.y, free.maxY - h)
        return UnitRect(x: x, y: y, w: w, h: h)
    }

    /// Where a dropped piece ends up. A clear spot is kept. An overlapping one
    /// goes to the largest free rectangle under the pointer. With none, nil:
    /// the piece springs back.
    static func resolveDrop(_ rect: UnitRect, pointer: CGPoint, others: [UnitRect],
                            minimum: (w: Double, h: Double)) -> UnitRect? {
        if !hasOverlap(rect, with: others) { return rect }
        let minCols = Int((minimum.w / cell).rounded(.up)), minRows = Int((minimum.h / cell).rounded(.up))
        guard let free = largestFreeRect(avoiding: others, containing: pointer,
                                         minCols: minCols, minRows: minRows) else { return nil }
        return fit(size: (rect.w, rect.h), into: free, near: CGPoint(x: rect.x, y: rect.y))
    }

    /// A new piece from the palette: its default size, or what fits, in the
    /// largest free rectangle. nil when there is no room for the minimum.
    static func placeNew(_ kind: LayoutPiece.Kind, avoiding rects: [UnitRect], display: CGSize) -> UnitRect? {
        let minimum = minimumCells(for: kind, display: display)
        guard let free = largestFreeRect(avoiding: rects, minCols: minimum.cols, minRows: minimum.rows) else { return nil }
        let wanted = defaultCells(for: kind)
        let w = Swift.min(Double(Swift.max(wanted.cols, minimum.cols)) * cell, free.w)
        let h = Swift.min(Double(Swift.max(wanted.rows, minimum.rows)) * cell, free.h)
        return UnitRect(x: free.x, y: free.y, w: w, h: h)
    }

    // MARK: Keyboard

    /// One cell in a direction. nil when it would leave the display or touch a
    /// neighbour.
    static func moved(_ rect: UnitRect, cols: Int, rows: Int, neighbours: [UnitRect]) -> UnitRect? {
        var r = rect
        if cols != 0 { r.x = clamp(gridLine(nearest: rect.x) + Double(cols) * cell, 0, 1 - rect.w) }
        if rows != 0 { r.y = clamp(gridLine(nearest: rect.y) + Double(rows) * cell, 0, 1 - rect.h) }
        guard !same(r, rect), !hasOverlap(r, with: neighbours) else { return nil }
        return r
    }

    /// The right or bottom edge by one cell. nil below the minimum, past the
    /// display or into a neighbour.
    static func resized(_ rect: UnitRect, cols: Int, rows: Int, neighbours: [UnitRect],
                        minimum: (w: Double, h: Double)) -> UnitRect? {
        var r = rect
        if cols != 0 {
            r.w = gridLine(nearest: rect.maxX) + Double(cols) * cell - rect.x
        }
        if rows != 0 {
            r.h = gridLine(nearest: rect.maxY) + Double(rows) * cell - rect.y
        }
        guard r.w >= minimum.w - epsilon, r.h >= minimum.h - epsilon,
              r.maxX <= 1 + epsilon, r.maxY <= 1 + epsilon,
              !same(r, rect), !hasOverlap(r, with: neighbours) else { return nil }
        return r
    }

    // MARK: Frames

    /// AppKit's frame (bottom-left origin, what NSWindow.setFrame takes) for a
    /// rect on a display whose usable area is `visibleFrame` (NSScreen.visibleFrame).
    static func nsFrame(for rect: UnitRect, visibleFrame: CGRect) -> CGRect {
        CGRect(x: visibleFrame.minX + rect.x * visibleFrame.width,
               y: visibleFrame.minY + (1 - rect.maxY) * visibleFrame.height,
               width: rect.w * visibleFrame.width,
               height: rect.h * visibleFrame.height)
    }

    /// The Accessibility / AppleScript frame (top-left origin of the PRIMARY
    /// display, y growing downward). `primaryHeight` is the menu-bar display's
    /// full frame height: Cocoa and AX agree on x, and differ on y by that flip
    /// for every display, not just the primary one.
    static func axFrame(for rect: UnitRect, visibleFrame: CGRect, primaryHeight: CGFloat) -> CGRect {
        let ns = nsFrame(for: rect, visibleFrame: visibleFrame)
        return CGRect(x: ns.minX, y: primaryHeight - ns.maxY, width: ns.width, height: ns.height)
    }
}

// MARK: - Resolving a template against the displays (phase B)

/// One connected display as the resolver sees it: plain values, so the choice
/// of variant can be tested without a screen.
struct LayoutScreen: Equatable {
    var id: String            // DisplayResolver's stable UUID string
    var name: String
    var visibleFrame: CGRect  // NSScreen.visibleFrame (bottom-left origin)
    var isMain: Bool
}

/// A piece's frame in both coordinate spaces: AppKit's (NSWindow.setFrame) and
/// the Accessibility / AppleScript one (top-left origin of the primary display).
struct LayoutFrames: Equatable {
    var ns: CGRect
    var ax: CGRect
}

enum LayoutResolver {

    enum Variant: Equatable { case oneDisplay, twoDisplays }

    struct Placed: Equatable {
        var piece: LayoutPiece
        var slot: LayoutSlot
        var screen: LayoutScreen
        var frames: LayoutFrames
        var fillsDisplay: Bool {
            if case .meeting(let fills, _) = piece.kind { return fills }
            return false
        }
    }

    struct Result: Equatable {
        var variant: Variant
        var placed: [Placed]
        /// Things worth a line in the status log: a fallback that was taken.
        var notes: [String]
        var primaryHeight: CGFloat

        var meeting: Placed? { placed.first { $0.piece.kind.isMeeting } }
        var chat: Placed? { placed.first { $0.piece.kind.isChat } }
        var apps: [Placed] { placed.filter { $0.piece.kind.app != nil } }
    }

    /// Re-resolved on every call, never cached: displays come and go and a
    /// screen's usable area changes with the Dock and the menu bar.
    ///
    /// The two-display version is used when the template has one AND a second
    /// display is connected - `secondUUID` if it is, else the first display that
    /// is not the main one. Otherwise the one-display version, on the main one.
    static func resolve(_ template: LayoutTemplate, screens: [LayoutScreen], primaryHeight: CGFloat) -> Result {
        guard let main = screens.first(where: \.isMain) ?? screens.first else {
            return Result(variant: .oneDisplay, placed: [], notes: ["No display is available to place windows on."],
                          primaryHeight: primaryHeight)
        }
        func place(_ pieces: [LayoutPiece], _ slot: LayoutSlot, on screen: LayoutScreen) -> [Placed] {
            pieces.map { piece in
                Placed(piece: piece, slot: slot, screen: screen,
                       frames: LayoutFrames(
                           ns: LayoutGeometry.nsFrame(for: piece.rect, visibleFrame: screen.visibleFrame),
                           ax: LayoutGeometry.axFrame(for: piece.rect, visibleFrame: screen.visibleFrame,
                                                      primaryHeight: primaryHeight)))
            }
        }
        var notes: [String] = []
        if let two = template.twoDisplays {
            let others = screens.filter { $0.id != main.id }
            let chosen = (!two.secondUUID.isEmpty ? others.first { $0.id == two.secondUUID } : nil) ?? others.first
            if let second = chosen {
                if !two.secondUUID.isEmpty, second.id != two.secondUUID {
                    notes.append("The saved second display isn\u{2019}t connected; using \u{201C}\(second.name)\u{201D}.")
                }
                return Result(variant: .twoDisplays,
                              placed: place(two.main, .main, on: main) + place(two.second, .second, on: second),
                              notes: notes, primaryHeight: primaryHeight)
            }
            notes.append("Only one display is connected, so the one-display version of \u{201C}\(template.name)\u{201D} is used.")
        }
        return Result(variant: .oneDisplay, placed: place(template.oneDisplay, .one, on: main),
                      notes: notes, primaryHeight: primaryHeight)
    }

    // MARK: Hiding the meeting

    /// The neighbour that, joined to `rect`, makes a rectangle: the same extent
    /// along one axis and touching along the other. The largest such neighbour.
    static func absorbingNeighbour(of rect: UnitRect, among neighbours: [(id: UUID, rect: UnitRect)])
        -> (id: UUID, joined: UnitRect)? {
        let e = LayoutGeometry.epsilon * 100
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < e }
        var best: (id: UUID, joined: UnitRect, area: Double)?
        for n in neighbours {
            var joined: UnitRect?
            if near(n.rect.x, rect.x), near(n.rect.w, rect.w), near(n.rect.maxY, rect.y) || near(n.rect.y, rect.maxY) {
                joined = UnitRect(x: rect.x, y: Swift.min(n.rect.y, rect.y), w: rect.w, h: n.rect.h + rect.h)
            } else if near(n.rect.y, rect.y), near(n.rect.h, rect.h), near(n.rect.maxX, rect.x) || near(n.rect.x, rect.maxX) {
                joined = UnitRect(x: Swift.min(n.rect.x, rect.x), y: rect.y, w: n.rect.w + rect.w, h: rect.h)
            }
            guard let joined else { continue }
            let area = n.rect.w * n.rect.h
            if best == nil || area > best!.area { best = (n.id, joined, area) }
        }
        return best.map { ($0.id, $0.joined) }
    }

    /// Every piece's frames with the Meeting hidden or not. Hidden, the one
    /// neighbour that joins the Meeting's rect into a rectangle grows into the
    /// gap; shown, it is back at its own rect.
    static func frames(of result: Result, meetingHidden: Bool) -> [UUID: LayoutFrames] {
        var out: [UUID: LayoutFrames] = [:]
        for p in result.placed { out[p.piece.id] = p.frames }
        guard meetingHidden, let meeting = result.meeting, !meeting.fillsDisplay else { return out }
        let neighbours = result.placed
            .filter { $0.piece.id != meeting.piece.id && $0.screen.id == meeting.screen.id && !$0.fillsDisplay }
            .map { (id: $0.piece.id, rect: $0.piece.rect) }
        guard let absorber = absorbingNeighbour(of: meeting.piece.rect, among: neighbours) else { return out }
        out[absorber.id] = LayoutFrames(
            ns: LayoutGeometry.nsFrame(for: absorber.joined, visibleFrame: meeting.screen.visibleFrame),
            ax: LayoutGeometry.axFrame(for: absorber.joined, visibleFrame: meeting.screen.visibleFrame,
                                       primaryHeight: result.primaryHeight))
        return out
    }

    // MARK: Zoom's own window

    /// `neighbour` (AppKit frame) fitted around the frame the meeting window was
    /// ACTUALLY given. Zoom clamps a resize to its minimum window size, so the
    /// planned rect and reality can differ; the neighbour yields along the edge
    /// it shares with the planned rect and keeps its far edge. Only ever
    /// smaller. Used for the Meeting only: no other app's size is ever
    /// compensated for.
    static func fit(_ neighbour: CGRect, aroundActual actual: CGRect, planned: CGRect,
                    minimum: CGFloat = 200) -> CGRect {
        let tolerance: CGFloat = 2
        var r = neighbour
        if neighbour.maxY <= planned.minY + tolerance {            // below the meeting
            let top = Swift.min(neighbour.maxY, actual.minY)
            r.size.height = Swift.max(top - neighbour.minY, Swift.min(minimum, neighbour.height))
        } else if neighbour.minY >= planned.maxY - tolerance {     // above it
            let bottom = Swift.max(neighbour.minY, actual.maxY)
            let height = Swift.max(neighbour.maxY - bottom, Swift.min(minimum, neighbour.height))
            r.origin.y = neighbour.maxY - height
            r.size.height = height
        } else if neighbour.maxX <= planned.minX + tolerance {     // left of it
            let right = Swift.min(neighbour.maxX, actual.minX)
            r.size.width = Swift.max(right - neighbour.minX, Swift.min(minimum, neighbour.width))
        } else if neighbour.minX >= planned.maxX - tolerance {     // right of it
            let left = Swift.max(neighbour.minX, actual.maxX)
            let width = Swift.max(neighbour.maxX - left, Swift.min(minimum, neighbour.width))
            r.origin.x = neighbour.maxX - width
            r.size.width = width
        }
        return r
    }

    // MARK: Small decisions

    /// Smaller than this, the placed meeting window is the Speaker view with its
    /// toolbar on hover; at or above it, the full meeting form.
    static let fullMeetingSize = CGSize(width: 760, height: 520)

    static func isCompactMeeting(_ size: CGSize) -> Bool {
        size.width < fullMeetingSize.width || size.height < fullMeetingSize.height
    }

    /// The app piece that gets focus at the end of a start: the largest one on
    /// the main display.
    static func largestAppOnMain(_ result: Result) -> Placed? {
        result.apps.filter { $0.screen.isMain }
            .max { $0.frames.ns.width * $0.frames.ns.height < $1.frames.ns.width * $1.frames.ns.height }
    }

    /// An AX-measured frame that differs from the one asked for by more than a
    /// couple of points: the app kept its own size.
    static func differs(_ actual: CGRect, from requested: CGRect, tolerance: CGFloat = 3) -> Bool {
        abs(actual.width - requested.width) > tolerance || abs(actual.height - requested.height) > tolerance
            || abs(actual.minX - requested.minX) > tolerance || abs(actual.minY - requested.minY) > tolerance
    }
}

// MARK: - The Meeting piece's flags, read and written on a template

extension LayoutTemplate {
    /// Whether any Meeting piece starts hidden. The Settings "Quick-hide mode"
    /// row reads and writes this on the active template.
    var meetingStartsHidden: Bool? {
        let flags = (oneDisplay + (twoDisplays.map { $0.main + $0.second } ?? [])).compactMap { piece -> Bool? in
            if case .meeting(_, let hidden) = piece.kind { return hidden }
            return nil
        }
        return flags.isEmpty ? nil : flags.contains(true)
    }

    mutating func setMeetingStartsHidden(_ hidden: Bool) {
        func apply(_ pieces: [LayoutPiece]) -> [LayoutPiece] {
            pieces.map { p in
                var p = p
                if case .meeting(let fills, _) = p.kind { p.kind = .meeting(fillsDisplay: fills, startsHidden: hidden) }
                return p
            }
        }
        oneDisplay = apply(oneDisplay)
        if var two = twoDisplays {
            two.main = apply(two.main)
            two.second = apply(two.second)
            twoDisplays = two
        }
    }

    /// A Meeting piece that fills a whole display: the participants form.
    var hasFillsDisplayMeeting: Bool {
        (twoDisplays.map { $0.main + $0.second } ?? []).contains {
            if case .meeting(true, _) = $0.kind { return true } else { return false }
        } || oneDisplay.contains {
            if case .meeting(true, _) = $0.kind { return true } else { return false }
        }
    }
}
