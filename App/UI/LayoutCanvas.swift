//
//  LayoutCanvas.swift
//  Greenroom
//
//  The layout editor's picture: one display, drawn at its real shape, with the
//  pieces on it as things you can drag, resize and key around.
//
//  How it is built (DESIGN.md, Affordances; the BubbleDragLayer pattern in
//  WebcamShapePreview):
//    - Every gesture is measured in the canvas's own named space, a layer that
//      never moves, so a tile moving under the pointer cannot feed back into
//      the number the drag reads.
//    - The resize handles are siblings of the tiles, not children, so they keep
//      their identity (and the gesture in flight) while the tile resizes.
//    - Keyboard focus lives on a layer UNDER everything. Clicking bare canvas
//      arms the keys; clicking a tile works the tile, and its gesture sets
//      focus itself so the arrows are live straight afterwards.
//    - Gestures go on before `.position`, with an explicit contentShape.
//    - Nothing animates mid-drag. Drops, removals and spring-backs do.
//
//  The arithmetic (snapping, overlap, free space, minimums) is
//  LayoutGeometry's, so this file only draws and routes input.
//
import SwiftUI
import AppKit

// MARK: - What the canvas is told

/// One display as the editor needs it: a name and the usable area in points,
/// which sets the aspect, the real-size readout and the per-display minimums.
struct LayoutDisplaySpace: Equatable {
    var name: String
    var size: CGSize
    var connected = true

    var aspect: CGFloat { min(max(size.width / max(size.height, 1), 1.2), 3.0) }
}

/// How a piece is drawn and named, decided by the page (which knows what is
/// installed and whether Accessibility is granted).
struct LayoutPieceLook {
    var name: String
    var icon: NSImage?
    var symbol: String
    /// An app that is not on this Mac: drawn dashed, "Not on this Mac".
    var missing = false
    /// A reason this piece will not be moved at Start (Accessibility).
    var warning: String?
}

extension LayoutPieceLook {
    /// Thumbnails draw only the app icon; this is the look for a card that has no
    /// page state (onboarding).
    static func thumbnail(_ piece: LayoutPiece) -> LayoutPieceLook {
        LayoutPieceLook(name: "", icon: piece.kind.app.flatMap { LayoutIcons.icon($0.bundleID) }, symbol: "")
    }
}

/// What travels from a palette chip to a canvas when dragged.
enum LayoutPalettePayload {
    private static let prefix = "greenroom-layout-piece:"

    static func string(for kind: LayoutPiece.Kind) -> String {
        switch kind {
        case .meeting: return prefix + "meeting"
        case .chat: return prefix + "chat"
        case let .app(app): return prefix + "app:" + app.bundleID
        }
    }

    static func kind(from string: String) -> LayoutPiece.Kind? {
        guard string.hasPrefix(prefix) else { return nil }
        let rest = String(string.dropFirst(prefix.count))
        if rest == "meeting" { return .meeting(fillsDisplay: false, startsHidden: false) }
        if rest == "chat" { return .chat }
        if rest.hasPrefix("app:") { return .app(AppPiece(bundleID: String(rest.dropFirst(4)))) }
        return nil
    }
}

extension LayoutPiece {
    /// A Meeting that fills its display is the Participants form: not placed
    /// by hand.
    var isFixed: Bool {
        if case .meeting(true, _) = kind { return true }
        return false
    }
}

// MARK: - The canvas

struct LayoutCanvas: View {
    @Binding var pieces: [LayoutPiece]
    @Binding var selection: UUID?
    let display: LayoutDisplaySpace
    let look: (LayoutPiece) -> LayoutPieceLook
    /// Whether the template may take one more of this (limits live on the model).
    let accepts: (LayoutPiece.Kind) -> Bool
    /// Told when the person touches this canvas, so the palette knows where to add.
    let onActivate: () -> Void
    /// A short reason something was not done ("No room for Chat").
    let onNotice: (String) -> Void
    /// Draws the title row above the canvas. Off when the page supplies its own.
    var showsHeader = true

    @State private var drag: DragState?
    @State private var dropTargeted = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let space = "LayoutCanvas.space"
    private static let handleSize: CGFloat = 8
    private static let tileInset: CGFloat = 1

    private struct DragState: Equatable {
        enum Mode: Equatable { case move, resize(LayoutGeometry.Handle) }
        var id: UUID
        var mode: Mode
        var start: UnitRect
        var rect: UnitRect
        var guidesX: [Double] = []
        var guidesY: [Double] = []
        var invalid = false
        var moved = false
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsHeader { header }
            bezel
        }
    }

    private var header: some View {
        HStack {
            Text(display.name.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Brand.text)
            if !display.connected {
                Text("not connected")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(Int(display.size.width))\u{00D7}\(Int(display.size.height))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    /// The display's own shape, in a thin bezel so handles at the edges are not
    /// clipped and the canvas reads as a screen rather than a box.
    private var bezel: some View {
        surface
            .aspectRatio(display.aspect, contentMode: .fit)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))
    }

    private var surface: some View {
        GeometryReader { geo in
            let canvas = geo.size
            ZStack(alignment: .topLeading) {
                // Focus layer: under the controls (see the file note).
                Color.clear
                    .contentShape(Rectangle())
                    .focusable()
                    .focusEffectDisabled()
                    .focused($focused)
                    .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow,
                                       .delete, .deleteForward, .tab, .escape], action: handleKey)
                    .onTapGesture {
                        selection = nil
                        focused = true
                        onActivate()
                    }

                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.5))
                    .allowsHitTesting(false)

                if drag != nil || dropTargeted { gridDots(canvas) }
                if pieces.isEmpty { emptyHint }

                ForEach(pieces) { piece in tile(piece, canvas: canvas) }

                guides(canvas)

                if let selected = pieces.first(where: { $0.id == selection }), !selected.isFixed {
                    ForEach(LayoutGeometry.Handle.allCases, id: \.self) { handle in
                        handleView(handle, piece: selected, canvas: canvas)
                    }
                }

                if let d = drag, d.moved { readout(d, canvas: canvas) }

                // The canvas's own ring: armed for the keyboard, or a drop is coming.
                if focused || dropTargeted {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Brand.green.opacity(dropTargeted ? 0.9 : 0.35),
                                      style: StrokeStyle(lineWidth: 2, dash: dropTargeted ? [5, 3] : []))
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: Self.space)
            .dropDestination(for: String.self) { items, location in
                drop(items, at: location, canvas: canvas)
            } isTargeted: { dropTargeted = $0 }
        }
    }

    // MARK: Pieces

    private func liveRect(_ piece: LayoutPiece) -> UnitRect {
        if let d = drag, d.id == piece.id { return d.rect }
        return piece.rect
    }

    private func frame(of rect: UnitRect, canvas: CGSize) -> CGRect {
        CGRect(x: rect.x * canvas.width, y: rect.y * canvas.height,
               width: rect.w * canvas.width, height: rect.h * canvas.height)
    }

    private func tile(_ piece: LayoutPiece, canvas: CGSize) -> some View {
        let rect = liveRect(piece)
        let box = frame(of: rect, canvas: canvas).insetBy(dx: Self.tileInset, dy: Self.tileInset)
        let isSelected = selection == piece.id
        let isDragging = drag?.id == piece.id
        let readout = LayoutGeometry.pointSize(of: rect, display: display.size)
        let span = LayoutGeometry.cellSpan(of: rect)
        let appearance = look(piece)
        return LayoutPieceTile(piece: piece, look: appearance, size: box.size,
                               pointSize: readout, columns: span.cols.count,
                               selected: isSelected, invalid: isDragging && (drag?.invalid ?? false))
            .frame(width: box.width, height: box.height)
            // Before .position: that modifier fills its parent, so a gesture
            // added after it would answer across the whole canvas.
            .contentShape(Rectangle())
            .gesture(moveGesture(piece, canvas: canvas))
            .onHover { inside in
                (inside ? (piece.isFixed ? NSCursor.arrow : NSCursor.openHand) : NSCursor.arrow).set()
            }
            .zIndex(isDragging ? 2 : (isSelected ? 1 : 0))
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .position(x: box.midX, y: box.midY)
            .modifier(TileAccessibility(
                name: appearance.name, value: spokenSpan(span), selected: isSelected,
                select: { select(piece.id) },
                nudge: { nudge(piece.id, cols: $0, rows: $1) },
                grow: { grow(piece.id, cols: $0, rows: $1) },
                remove: { remove(piece.id) }))
    }

    private func spokenSpan(_ span: (cols: ClosedRange<Int>, rows: ClosedRange<Int>)) -> String {
        "columns \(span.cols.lowerBound) to \(span.cols.upperBound), rows \(span.rows.lowerBound) to \(span.rows.upperBound)"
    }

    private var emptyHint: some View {
        VStack(spacing: 6) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 22, weight: .light))
            Text("Drag a piece here, or click one below")
                .font(.callout)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    // MARK: Grid, guides, readout

    private func gridDots(_ canvas: CGSize) -> some View {
        Canvas { context, size in
            let n = LayoutGeometry.divisions
            for i in 0...n {
                for j in 0...n {
                    let p = CGPoint(x: size.width * CGFloat(i) / CGFloat(n), y: size.height * CGFloat(j) / CGFloat(n))
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 1.2, y: p.y - 1.2, width: 2.4, height: 2.4)),
                                 with: .color(.secondary.opacity(0.45)))
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func guides(_ canvas: CGSize) -> some View {
        if let d = drag {
            ForEach(Array(d.guidesX.enumerated()), id: \.offset) { _, x in
                Rectangle().fill(Brand.green).frame(width: 1, height: canvas.height)
                    .position(x: x * canvas.width, y: canvas.height / 2)
                    .allowsHitTesting(false)
            }
            ForEach(Array(d.guidesY.enumerated()), id: \.offset) { _, y in
                Rectangle().fill(Brand.green).frame(width: canvas.width, height: 1)
                    .position(x: canvas.width / 2, y: y * canvas.height)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The real size in points while a piece is being moved or resized, in mono
    /// because it is a machine fact.
    private func readout(_ d: DragState, canvas: CGSize) -> some View {
        let size = LayoutGeometry.pointSize(of: d.rect, display: display.size)
        let box = frame(of: d.rect, canvas: canvas)
        return Text("\(size.w) \u{00D7} \(size.h)")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.78)))
            .position(x: min(max(box.midX, 44), canvas.width - 44),
                      y: min(max(box.minY + 16, 12), canvas.height - 12))
            .zIndex(5)
            .allowsHitTesting(false)
    }

    // MARK: Handles

    private func handlePoint(_ handle: LayoutGeometry.Handle, in box: CGRect) -> CGPoint {
        let x = handle.movesLeft ? box.minX : (handle.movesRight ? box.maxX : box.midX)
        let y = handle.movesTop ? box.minY : (handle.movesBottom ? box.maxY : box.midY)
        return CGPoint(x: x, y: y)
    }

    private func handleView(_ handle: LayoutGeometry.Handle, piece: LayoutPiece, canvas: CGSize) -> some View {
        let box = frame(of: liveRect(piece), canvas: canvas)
        let isActive = drag?.id == piece.id && drag?.mode == .resize(handle)
        return RoundedRectangle(cornerRadius: 2)
            .fill(isActive ? Brand.green : Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Brand.green, lineWidth: 1.5))
            .frame(width: Self.handleSize, height: Self.handleSize)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .gesture(resizeGesture(piece, handle: handle, canvas: canvas))
            .onHover { inside in (inside ? Self.cursor(for: handle) : NSCursor.arrow).set() }
            .zIndex(4)
            .position(handlePoint(handle, in: box))
            .accessibilityHidden(true)   // the tile itself carries the actions
    }

    private static func cursor(for handle: LayoutGeometry.Handle) -> NSCursor {
        switch handle {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default:
            if #available(macOS 15.0, *) {
                let diagonal: NSCursor.FrameResizePosition = (handle == .topLeft || handle == .bottomRight)
                    ? (handle == .topLeft ? .topLeft : .bottomRight)
                    : (handle == .topRight ? .topRight : .bottomLeft)
                return NSCursor.frameResize(position: diagonal, directions: [.inward, .outward])
            }
            return .crosshair
        }
    }

    // MARK: Gestures

    private func threshold(_ canvas: CGSize) -> Double { 8 / Double(max(canvas.width, canvas.height, 1)) }

    private func neighbours(of id: UUID) -> [UnitRect] { pieces.filter { $0.id != id }.map(\.rect) }

    private func unit(_ point: CGPoint, canvas: CGSize) -> CGPoint {
        CGPoint(x: point.x / max(canvas.width, 1), y: point.y / max(canvas.height, 1))
    }

    private func select(_ id: UUID) {
        selection = id
        focused = true
        onActivate()
    }

    private func moveGesture(_ piece: LayoutPiece, canvas: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if drag == nil {
                    select(piece.id)
                    if !piece.isFixed { drag = DragState(id: piece.id, mode: .move, start: piece.rect, rect: piece.rect) }
                }
                guard var d = drag, d.id == piece.id, d.mode == .move else { return }
                let t = value.translation
                // A click is not a drag: a layout migrated off the grid keeps
                // its numbers until somebody actually moves it.
                if !d.moved && hypot(t.width, t.height) < 3 { return }
                d.moved = true
                let origin = CGPoint(x: d.start.x + t.width / canvas.width, y: d.start.y + t.height / canvas.height)
                let others = neighbours(of: piece.id)
                let snap = LayoutGeometry.snapMove(d.start, toOrigin: origin, neighbours: others,
                                                   threshold: threshold(canvas))
                d.rect = snap.rect
                d.guidesX = snap.guidesX
                d.guidesY = snap.guidesY
                d.invalid = LayoutGeometry.hasOverlap(snap.rect, with: others)
                drag = d
            }
            .onEnded { value in finishMove(piece, pointer: value.location, canvas: canvas) }
    }

    private func finishMove(_ piece: LayoutPiece, pointer: CGPoint, canvas: CGSize) {
        guard let d = drag, d.id == piece.id, d.mode == .move, d.moved else { drag = nil; return }
        guard d.invalid else {
            commit(d.rect, for: piece.id)
            drag = nil
            return
        }
        let minimum = LayoutGeometry.minimumUnitSize(for: piece.kind, display: display.size)
        if let landed = LayoutGeometry.resolveDrop(d.rect, pointer: unit(pointer, canvas: canvas),
                                                   others: neighbours(of: piece.id), minimum: minimum) {
            withAnimation(animation(.snappy(duration: 0.25))) {
                commit(landed, for: piece.id)
                drag = nil
            }
        } else {
            // Nowhere to land: back to where it was.
            withAnimation(animation(.easeInOut(duration: 0.25))) { drag = nil }
        }
    }

    private func resizeGesture(_ piece: LayoutPiece, handle: LayoutGeometry.Handle, canvas: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if drag == nil {
                    focused = true
                    onActivate()
                    drag = DragState(id: piece.id, mode: .resize(handle), start: piece.rect, rect: piece.rect)
                }
                guard var d = drag, d.id == piece.id, d.mode == .resize(handle) else { return }
                let t = value.translation
                if !d.moved && hypot(t.width, t.height) < 2 { return }
                d.moved = true
                let delta = CGPoint(x: t.width / canvas.width, y: t.height / canvas.height)
                let result = LayoutGeometry.snapResize(
                    d.start, handle: handle, delta: delta, neighbours: neighbours(of: piece.id),
                    minimum: LayoutGeometry.minimumUnitSize(for: piece.kind, display: display.size),
                    threshold: threshold(canvas))
                d.rect = result.rect
                d.guidesX = result.guidesX
                d.guidesY = result.guidesY
                drag = d
            }
            .onEnded { _ in
                if let d = drag, d.id == piece.id, d.moved { commit(d.rect, for: piece.id) }
                drag = nil
            }
    }

    private func animation(_ a: Animation) -> Animation? { reduceMotion ? nil : a }

    private func commit(_ rect: UnitRect, for id: UUID) {
        guard let i = pieces.firstIndex(where: { $0.id == id }) else { return }
        pieces[i].rect = rect
    }

    // MARK: Keyboard and VoiceOver

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let shift = press.modifiers.contains(.shift)
        switch press.key {
        case .tab:
            return cycle(backwards: shift)
        case .escape:
            guard selection != nil else { return .ignored }
            selection = nil
            return .handled
        case .delete, .deleteForward:
            guard let id = selection else { return .ignored }
            remove(id)
            return .handled
        case .leftArrow, .rightArrow, .upArrow, .downArrow:
            guard let id = selection else { return .ignored }
            let dx = press.key == .leftArrow ? -1 : (press.key == .rightArrow ? 1 : 0)
            let dy = press.key == .upArrow ? -1 : (press.key == .downArrow ? 1 : 0)
            if shift { grow(id, cols: dx, rows: dy) } else { nudge(id, cols: dx, rows: dy) }
            return .handled
        default:
            return .ignored
        }
    }

    /// Reading order, so Tab walks the canvas the way the eye does. Past the
    /// last piece it lets go, so the keyboard is never trapped here.
    private func cycle(backwards: Bool) -> KeyPress.Result {
        let order = pieces.sorted { ($0.rect.y, $0.rect.x) < ($1.rect.y, $1.rect.x) }
        guard !order.isEmpty else { return .ignored }
        guard let current = order.firstIndex(where: { $0.id == selection }) else {
            selection = (backwards ? order.last : order.first)?.id
            return .handled
        }
        let next = current + (backwards ? -1 : 1)
        guard order.indices.contains(next) else { return .ignored }
        selection = order[next].id
        return .handled
    }

    private func nudge(_ id: UUID, cols: Int, rows: Int) {
        guard let piece = pieces.first(where: { $0.id == id }), !piece.isFixed,
              let moved = LayoutGeometry.moved(piece.rect, cols: cols, rows: rows, neighbours: neighbours(of: id))
        else { return }
        withAnimation(animation(.snappy(duration: 0.25))) { commit(moved, for: id) }
    }

    private func grow(_ id: UUID, cols: Int, rows: Int) {
        guard let piece = pieces.first(where: { $0.id == id }), !piece.isFixed,
              let resized = LayoutGeometry.resized(
                piece.rect, cols: cols, rows: rows, neighbours: neighbours(of: id),
                minimum: LayoutGeometry.minimumUnitSize(for: piece.kind, display: display.size))
        else { return }
        withAnimation(animation(.snappy(duration: 0.25))) { commit(resized, for: id) }
    }

    private func remove(_ id: UUID) {
        withAnimation(animation(.snappy(duration: 0.25))) {
            pieces.removeAll { $0.id == id }
            if selection == id { selection = nil }
        }
    }

    // MARK: Drop from the palette

    private func drop(_ items: [String], at location: CGPoint, canvas: CGSize) -> Bool {
        guard let kind = items.lazy.compactMap(LayoutPalettePayload.kind(from:)).first else { return false }
        onActivate()
        guard accepts(kind) else {
            onNotice("That is already in this layout.")
            return false
        }
        let pointer = unit(location, canvas: canvas)
        let minimum = LayoutGeometry.minimumCells(for: kind, display: display.size)
        let wanted = LayoutGeometry.defaultCells(for: kind)
        let w = Double(max(wanted.cols, minimum.cols)) * LayoutGeometry.cell
        let h = Double(max(wanted.rows, minimum.rows)) * LayoutGeometry.cell
        let origin = CGPoint(x: min(max(Double(pointer.x) - w / 2, 0), 1 - w),
                             y: min(max(Double(pointer.y) - h / 2, 0), 1 - h))
        let others = pieces.map(\.rect)
        let snapped = LayoutGeometry.snapMove(UnitRect(x: 0, y: 0, w: w, h: h), toOrigin: origin,
                                              neighbours: others, threshold: threshold(canvas)).rect
        let minimumUnit = LayoutGeometry.minimumUnitSize(for: kind, display: display.size)
        guard let rect = LayoutGeometry.resolveDrop(snapped, pointer: pointer, others: others, minimum: minimumUnit) else {
            onNotice("There is no room for that here. Make some space first.")
            return false
        }
        let piece = LayoutPiece(kind: kind, rect: rect)
        withAnimation(animation(.snappy(duration: 0.25))) {
            pieces.append(piece)
            selection = piece.id
        }
        focused = true
        return true
    }
}

// MARK: - VoiceOver

/// A tile as one adjustable element: "Chat, columns 9 to 12, rows 6 to 12".
/// Adjust moves it a column; the rest are named actions.
private struct TileAccessibility: ViewModifier {
    let name: String
    let value: String
    let selected: Bool
    let select: () -> Void
    let nudge: (Int, Int) -> Void
    let grow: (Int, Int) -> Void
    let remove: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name)
            .accessibilityValue(value)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, select)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: nudge(1, 0)
                case .decrement: nudge(-1, 0)
                @unknown default: break
                }
            }
            .modifier(TileMoveActions(nudge: nudge))
            .modifier(TileSizeActions(grow: grow, remove: remove))
    }
}

private struct TileMoveActions: ViewModifier {
    let nudge: (Int, Int) -> Void
    func body(content: Content) -> some View {
        content
            .accessibilityAction(named: "Move left") { nudge(-1, 0) }
            .accessibilityAction(named: "Move right") { nudge(1, 0) }
            .accessibilityAction(named: "Move up") { nudge(0, -1) }
            .accessibilityAction(named: "Move down") { nudge(0, 1) }
    }
}

private struct TileSizeActions: ViewModifier {
    let grow: (Int, Int) -> Void
    let remove: () -> Void
    func body(content: Content) -> some View {
        content
            .accessibilityAction(named: "Wider") { grow(1, 0) }
            .accessibilityAction(named: "Narrower") { grow(-1, 0) }
            .accessibilityAction(named: "Taller") { grow(0, 1) }
            .accessibilityAction(named: "Shorter") { grow(0, -1) }
            .accessibilityAction(named: "Remove", remove)
    }
}

// MARK: - A piece, drawn

/// A piece's schematic: Meeting a dark tile like a video tile, Chat a light
/// pane like a chat window, an app showing its own icon. What it says adapts
/// to the room it has.
struct LayoutPieceTile: View {
    let piece: LayoutPiece
    let look: LayoutPieceLook
    let size: CGSize
    let pointSize: (w: Int, h: Int)
    let columns: Int
    let selected: Bool
    var invalid = false

    private var isMeeting: Bool { piece.kind.isMeeting }
    private var primary: Color { isMeeting ? .white.opacity(0.92) : .primary }
    private var secondary: Color { isMeeting ? .white.opacity(0.62) : .secondary }

    private var roomy: Bool { size.height >= 64 && size.width >= 96 }
    private var tiny: Bool { size.height < 40 || size.width < 56 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(isMeeting ? Color.black.opacity(0.78) : Color(nsColor: .controlBackgroundColor))
            content
                .padding(4)
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(border, style: StrokeStyle(lineWidth: selected ? 2 : 1,
                                                         dash: (look.missing || invalid) ? [4, 3] : []))
        }
        .overlay(alignment: .topTrailing) {
            if look.warning != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(5)
                    .help(look.warning ?? "")
            }
        }
        .opacity(invalid ? 0.55 : 1)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var border: Color {
        if selected { return Brand.green }
        return isMeeting ? .white.opacity(0.15) : Color.secondary.opacity(0.35)
    }

    @ViewBuilder
    private var content: some View {
        if tiny {
            glyph(18)
        } else {
            VStack(spacing: 3) {
                glyph(roomy ? min(max(min(size.width, size.height) * 0.34, 24), 44) : 18)
                Text(look.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(primary)
                    .lineLimit(1)
                if roomy {
                    Text(caption)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
    }

    private var caption: String {
        if look.missing { return "Not on this Mac" }
        if piece.isFixed { return "Fills this display" }
        return "\(columns) of 12 \u{00B7} \(pointSize.w)\u{00D7}\(pointSize.h)"
    }

    @ViewBuilder
    private func glyph(_ side: CGFloat) -> some View {
        if let icon = look.icon, !look.missing {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: side, height: side)
        } else {
            Image(systemName: look.symbol)
                .font(.system(size: side * 0.8, weight: .regular))
                .foregroundStyle(secondary)
                .frame(width: side, height: side)
        }
    }
}

// MARK: - Thumbnail

/// A layout as a small picture, for the card strip: schematic only, never a
/// screen capture.
struct LayoutThumbnail: View {
    let pieces: [LayoutPiece]
    var aspect: CGFloat = 1.6
    var look: (LayoutPiece) -> LayoutPieceLook

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.10))
                ForEach(pieces) { piece in
                    let r = piece.rect
                    let box = CGRect(x: r.x * geo.size.width, y: r.y * geo.size.height,
                                     width: r.w * geo.size.width, height: r.h * geo.size.height)
                        .insetBy(dx: 1, dy: 1)
                    ZStack {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(piece.kind.isMeeting ? Color.black.opacity(0.78)
                                                       : Color(nsColor: .controlBackgroundColor))
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.5)
                        if let icon = look(piece).icon, piece.kind.app != nil,
                           min(box.width, box.height) > 16 {
                            Image(nsImage: icon).resizable()
                                .frame(width: min(box.width, box.height) * 0.5, height: min(box.width, box.height) * 0.5)
                        }
                    }
                    .frame(width: max(box.width, 0), height: max(box.height, 0))
                    .position(x: box.midX, y: box.midY)
                }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
