//
//  WhiteboardViews.swift
//  Greenroom
//
//  Ported from Recorditor (ZRecorditor @7210322, native/MacRecorder/Recording/CameraWhiteboard.swift:
//  `CameraWhiteboardStage`, `CameraWhiteboardTools`). Phase 5 of the Recorditor port.
//
//  The whiteboard page in a Greenroom window, with its tools floating at the
//  foot of the page on glass (DESIGN.md, Glass). The model is in
//  App/Recording/CameraWhiteboard.swift. Upstream drew the camera as an inset
//  in the corner of the page; here the camera is composited by the Stage over
//  the page, in the user's own shape and position, so no inset is drawn.
//
import AppKit
import SwiftUI

// MARK: - The page in a window

/// The page: draw with the mouse. Hovering a stroke shows its box with an x
/// (delete) and a resize handle; dragging the stroke moves it. That chrome is
/// only in the window; the Stage's picture draws the strokes alone.
struct CameraWhiteboardStage: View {
    @ObservedObject var board: CameraWhiteboardModel
    var cornerRadius: CGFloat = 12

    private enum Gesture {
        case erase(last: CGPoint)
        case draw
        case move(start: CGPoint, original: CameraWhiteboardModel.Stroke)
        case resize(original: CameraWhiteboardModel.Stroke, box: CGRect)
        case done
    }
    @State private var hovered: Int?
    @State private var gesture: Gesture?
    private static let padding: CGFloat = 8
    private static let buttonRadius: CGFloat = 11
    private static let eraserRadius: CGFloat = 14
    @State private var eraserAt: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .bottomTrailing) {
                Canvas { context, canvasSize in
                    context.withCGContext { cg in
                        CameraWhiteboardModel.draw(board.strokes + (board.current.map { [$0] } ?? []),
                                                   in: cg, size: canvasSize)
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in dragChanged(value, size: size) }
                        .onEnded { _ in
                            if case .draw = gesture { board.finish() }
                            gesture = nil
                        })
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        if board.isErasing {
                            eraserAt = point
                            hovered = nil
                            NSCursor.arrow.set()
                            return
                        }
                        eraserAt = nil
                        guard gesture == nil else { return }
                        hovered = strokeAt(point, size: size)
                        if let hovered {
                            let box = self.box(of: hovered, size: size)
                            if near(point, CGPoint(x: box.maxX, y: box.minY)) { NSCursor.pointingHand.set() }
                            else if near(point, CGPoint(x: box.maxX, y: box.maxY)) { NSCursor.crosshair.set() }
                            else { NSCursor.openHand.set() }
                        } else {
                            NSCursor.crosshair.set()
                        }
                    case .ended:
                        eraserAt = nil
                        if gesture == nil { hovered = nil }
                        NSCursor.arrow.set()
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if let hovered, board.strokes.indices.contains(hovered) {
                    chrome(box(of: hovered, size: size))
                        .allowsHitTesting(false)
                }
                // The eraser's reach, following the pointer (window only).
                if board.isErasing, let eraserAt {
                    Circle()
                        .fill(Color.white.opacity(0.35))
                        .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1.5))
                        .frame(width: Self.eraserRadius * 2, height: Self.eraserRadius * 2)
                        .offset(x: eraserAt.x - Self.eraserRadius, y: eraserAt.y - Self.eraserRadius)
                        .allowsHitTesting(false)
                }
            }
        }
        .aspectRatio(CameraWhiteboardModel.aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    // MARK: geometry (view points)

    private func viewPoints(_ stroke: CameraWhiteboardModel.Stroke, size: CGSize) -> [CGPoint] {
        stroke.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
    }

    private func lineWidth(_ size: CGSize) -> CGFloat { max(2, size.width * 0.0042) }

    private func bounds(of index: Int, size: CGSize) -> CGRect {
        let points = viewPoints(board.strokes[index], size: size)
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .null }
        let half = lineWidth(size) / 2
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -half, dy: -half)
    }

    private func box(of index: Int, size: CGSize) -> CGRect {
        bounds(of: index, size: size).insetBy(dx: -Self.padding, dy: -Self.padding)
    }

    private func near(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) <= Self.buttonRadius + 3 }

    /// The hovered stroke keeps its whole box (the x and handle sit on its
    /// corners); others need a hit on the line.
    private func strokeAt(_ point: CGPoint, size: CGSize) -> Int? {
        if let hovered, board.strokes.indices.contains(hovered),
           box(of: hovered, size: size).insetBy(dx: -Self.buttonRadius, dy: -Self.buttonRadius).contains(point) {
            return hovered
        }
        let reach = lineWidth(size) / 2 + 8
        return board.strokes.indices.reversed().first { index in
            let points = viewPoints(board.strokes[index], size: size)
            guard bounds(of: index, size: size).insetBy(dx: -8, dy: -8).contains(point) else { return false }
            if points.count == 1 { return hypot(point.x - points[0].x, point.y - points[0].y) <= reach }
            return (1..<points.count).contains { i in
                let a = points[i - 1], b = points[i]
                let dx = b.x - a.x, dy = b.y - a.y
                let lengthSquared = dx * dx + dy * dy
                let t = lengthSquared == 0 ? 0 : max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
                return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy)) <= reach
            }
        }
    }

    // MARK: gestures

    private func dragChanged(_ value: DragGesture.Value, size: CGSize) {
        let point = value.location
        let normalized = CGPoint(x: min(max(point.x / size.width, 0), 1), y: min(max(point.y / size.height, 0), 1))
        if board.isErasing {
            let from: CGPoint
            if case let .erase(last) = gesture { from = last } else { from = value.startLocation }
            let steps = max(1, Int(hypot(point.x - from.x, point.y - from.y) / (Self.eraserRadius / 2)))
            for index in 1...steps {
                let t = CGFloat(index) / CGFloat(steps)
                board.erase(at: CGPoint(x: from.x + (point.x - from.x) * t, y: from.y + (point.y - from.y) * t),
                            radius: Self.eraserRadius, size: size)
            }
            hovered = nil
            gesture = .erase(last: point)
            return
        }
        switch gesture {
        case nil:
            if let index = strokeAt(value.startLocation, size: size) {
                let box = box(of: index, size: size)
                if near(value.startLocation, CGPoint(x: box.maxX, y: box.minY)) {
                    board.remove(at: index)
                    hovered = nil
                    gesture = .done
                } else if near(value.startLocation, CGPoint(x: box.maxX, y: box.maxY)) {
                    gesture = .resize(original: board.strokes[index], box: bounds(of: index, size: size))
                    hovered = index
                } else {
                    gesture = .move(start: value.startLocation, original: board.strokes[index])
                    hovered = index
                    NSCursor.closedHand.set()
                }
            } else {
                hovered = nil
                gesture = .draw
                board.begin(at: normalized)
            }
        case .draw:
            board.extend(to: normalized)
        case let .move(start, original):
            guard let index = hovered else { return }
            let dx = (point.x - start.x) / size.width, dy = (point.y - start.y) / size.height
            var moved = original
            moved.points = original.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            board.replace(at: index, with: moved)
        case let .resize(original, box):
            guard let index = hovered else { return }
            let width = max(12, point.x - Self.padding - box.minX)
            let height = max(12, point.y - Self.padding - box.minY)
            let sx = box.width > 0 ? width / box.width : 1, sy = box.height > 0 ? height / box.height : 1
            var scaled = original
            scaled.points = original.points.map {
                let x = box.minX + ($0.x * size.width - box.minX) * sx
                let y = box.minY + ($0.y * size.height - box.minY) * sy
                return CGPoint(x: x / size.width, y: y / size.height)
            }
            board.replace(at: index, with: scaled)
        case .done, .erase:
            break
        }
    }

    // MARK: chrome

    private func chrome(_ box: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .frame(width: box.width, height: box.height)
                .offset(x: box.minX, y: box.minY)
            Circle()
                .fill(Color(red: 1, green: 0.29, blue: 0.31))
                .frame(width: 22, height: 22)
                .overlay(Image(systemName: "xmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white))
                .shadow(color: .black.opacity(0.35), radius: 3)
                .offset(x: box.maxX - 11, y: box.minY - 11)
            Circle()
                .fill(Color.white)
                .overlay(Circle().stroke(Color.accentColor, lineWidth: 2).padding(1))
                .frame(width: 14, height: 14)
                .offset(x: box.maxX - 7, y: box.maxY - 7)
        }
    }
}

/// Pen, Eraser, five colours, Undo, Clear. Floats over the page, so it is glass.
struct CameraWhiteboardTools: View {
    @ObservedObject var board: CameraWhiteboardModel
    var onDone: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            modeButton("Pen", icon: "pencil.tip", on: !board.isErasing) { board.isErasing = false }
            modeButton("Eraser", icon: "eraser", on: board.isErasing) { board.isErasing = true }
            divider
            ForEach(Array(CameraWhiteboardModel.colors.enumerated()), id: \.offset) { _, color in
                let selected = board.color == color
                Button {
                    board.color = color
                } label: {
                    Circle()
                        .fill(Color(nsColor: color))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color.primary.opacity(selected ? 0.9 : 0.25), lineWidth: selected ? 2 : 1))
                        .padding(4)
                        .contentShape(Circle())
                }
                .buttonStyle(PressScaleStyle(scale: 0.85))
                .help("Ink colour")
                .accessibilityLabel("Ink colour")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            divider
            roundButton("arrow.uturn.backward", help: "Undo (\u{2318}Z)") { board.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!board.canUndo)
            roundButton("trash", help: "Clear the whiteboard") { board.clear() }
                .disabled(!board.canUndo)
            if let onDone {
                divider
                Button("Back to screen", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Go back to what you were sharing before the whiteboard")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(.easeOut(duration: 0.15), value: board.isErasing)
        .greenroomGlass(in: Capsule(), interactive: true)
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.2)).frame(width: 1, height: 22).padding(.horizontal, 4)
    }

    private func modeButton(_ title: String, icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? Color.white : Color.primary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(on ? Brand.green : Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.9))
        .help(title == "Eraser" ? "Eraser \u{2014} drag over a line to rub it out" : "Pen \u{2014} draw on the page")
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func roundButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.9))
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The whole window's content: the page, with the tools floating at its foot.
struct WhiteboardWindowView: View {
    @ObservedObject var board: CameraWhiteboardModel
    var onDone: () -> Void

    var body: some View {
        CameraWhiteboardStage(board: board, cornerRadius: 0)
            .overlay(alignment: .bottom) {
                CameraWhiteboardTools(board: board, onDone: onDone)
                    .padding(.bottom, 14)
            }
            .tint(Brand.green)
    }
}

// MARK: - The window

/// The whiteboard window: a Greenroom window, so never captured. What the
/// meeting and the recording see is the page rendered by the coordinator.
@MainActor
final class WhiteboardWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    var onClosed: (() -> Void)?

    var isVisible: Bool { window?.isVisible ?? false }

    func show(board: CameraWhiteboardModel, onDone: @escaping () -> Void) {
        if window == nil {
            let size = NSSize(width: 960, height: 540)
            let created = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false)
            created.title = "Whiteboard"
            created.isReleasedWhenClosed = false
            created.contentAspectRatio = NSSize(width: 16, height: 9)
            created.contentMinSize = NSSize(width: 480, height: 270)
            created.delegate = self
            created.sharingType = .none
            created.contentView = NSHostingView(rootView: WhiteboardWindowView(board: board, onDone: onDone))
            created.center()
            window = created
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) { onClosed?() }
}
