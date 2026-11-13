//
//  ScreenAnnotation.swift
//  Greenroom
//
//  Ported from Recorditor (ZRecorditor @7210322, native/MacRecorder/Recording/ScreenAnnotation.swift).
//  Phase 5 of the Recorditor port, see docs/recorditor-integration/drawing-port-log.md.
//
//  The drawing model (tools, marks, erasing, editing geometry) and the one
//  painter that draws a mark. Two things draw with it: the transparent canvas
//  over the real screen (ScreenAnnotationController.swift) and the image the
//  Stage lays over the shared screen (`AnnotationMarksRenderer`).
//
//  Upstream kept marks in the canvas window's own coordinates and let
//  ScreenCaptureKit capture the canvas. Greenroom excludes its own windows
//  from capture, so marks are kept in GLOBAL screen points (CoreGraphics,
//  top-left origin of the main display, the space of SCDisplay.frame and
//  window bounds) and the Stage draws them itself.
//
import AppKit
import CoreGraphics

@MainActor
final class ScreenAnnotationModel: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case pointer, pen, highlighter, arrow, eraser
        var id: String { rawValue }

        var title: String {
            switch self {
            case .pointer: "Select"
            case .pen: "Pen"
            case .highlighter: "Highlighter"
            case .arrow: "Arrow"
            case .eraser: "Eraser"
            }
        }

        var icon: String {
            switch self {
            case .pointer: "cursorarrow"
            case .pen: "pencil.tip"
            case .highlighter: "highlighter"
            case .arrow: "arrow.up.right"
            case .eraser: "eraser"
            }
        }

        var shortcut: String {
            switch self {
            case .pointer: "V"
            case .pen: "P"
            case .highlighter: "H"
            case .arrow: "A"
            case .eraser: "E"
            }
        }
    }

    struct Mark {
        var tool: Tool
        var color: NSColor
        /// Global screen points (CoreGraphics, top-left origin).
        var points: [CGPoint]
    }

    static let colors: [NSColor] = [
        NSColor(red: 1.00, green: 0.29, blue: 0.31, alpha: 1),   // record red
        NSColor(red: 1.00, green: 0.80, blue: 0.15, alpha: 1),
        NSColor(red: 0.20, green: 0.82, blue: 0.40, alpha: 1),
        NSColor(red: 0.29, green: 0.56, blue: 1.00, alpha: 1),
        .white,
        NSColor(red: 0.07, green: 0.09, blue: 0.14, alpha: 1),
    ]

    @Published var tool: Tool = .arrow
    @Published var color: NSColor = colors[0]
    /// A window share: drawing only goes over the shared window (global
    /// points); the rest of the screen isn't in the picture. Nil: anywhere.
    @Published var drawableArea: CGRect?
    /// A short note for the toolbar's hint line (each one new, so the same
    /// note twice shows twice).
    struct Notice: Equatable { let text: String; let id: Int }
    @Published private(set) var notice: Notice?
    func say(_ text: String) { notice = Notice(text: text, id: (notice?.id ?? 0) + 1) }
    static let outsideWindowNote = "Draw over the window being shared \u{2014} the rest of the screen isn\u{2019}t in the picture"

    /// Every mark on the screen. Changing it tells `onMarksChanged`, which
    /// is what makes the Stage redraw its copy.
    @Published private(set) var marks: [Mark] = [] { didSet { onMarksChanged?() } }
    /// The stroke being dragged right now (not published: only the Stage and
    /// the canvas care, and they are told through `onMarksChanged`).
    var inProgress: Mark? { didSet { onMarksChanged?() } }
    var onMarksChanged: (() -> Void)?

    var canUndo: Bool { !marks.isEmpty }

    func add(_ mark: Mark) { marks.append(mark) }

    func replace(at index: Int, with mark: Mark) {
        guard marks.indices.contains(index) else { return }
        marks[index] = mark
    }

    func remove(at index: Int) {
        guard marks.indices.contains(index) else { return }
        marks.remove(at: index)
    }

    /// Everything moves by `delta` (a followed window moved).
    func translateAll(by delta: CGSize) {
        guard !marks.isEmpty, delta != .zero else { return }
        marks = marks.map { $0.moved(by: delta) }
    }

    /// Rubs out what's within `radius` of the point: pen and highlighter
    /// lines lose that stretch (splitting in two where it's mid-line), an
    /// arrow touched anywhere goes whole.
    func erase(at point: CGPoint, radius: CGFloat) {
        var result: [Mark] = []
        var changed = false
        for mark in marks {
            if mark.tool == .arrow {
                if mark.hits(point, slack: radius) { changed = true } else { result.append(mark) }
                continue
            }
            let reach = radius + mark.lineWidth / 2
            guard mark.bounds.insetBy(dx: -reach, dy: -reach).contains(point) else {
                result.append(mark)
                continue
            }
            let pieces = erasePolyline(mark.points, around: point, radius: reach)
            if pieces.count == 1, pieces[0].count == mark.points.count {
                result.append(mark)
            } else {
                changed = true
                result += pieces.map { Mark(tool: mark.tool, color: mark.color, points: $0) }
            }
        }
        guard changed else { return }
        marks = result
    }

    func undo() { _ = marks.popLast() }
    func clear() { marks.removeAll() }

    func reset() {
        marks.removeAll()
        inProgress = nil
        tool = .arrow
    }
}

/// What's left of a polyline after rubbing out a circle: the runs of points
/// outside it (long segments are filled in first, so a sparse line — one
/// that was resized bigger — still breaks where the eraser crossed it).
func erasePolyline(_ points: [CGPoint], around center: CGPoint, radius: CGFloat) -> [[CGPoint]] {
    guard let first = points.first else { return [] }
    var dense = [first]
    let step = max(1, radius / 3)
    for point in points.dropFirst() {
        let last = dense[dense.count - 1]
        let distance = hypot(point.x - last.x, point.y - last.y)
        if distance > step {
            let count = Int(distance / step)
            for index in 1...count {
                let t = CGFloat(index) / CGFloat(count + 1)
                dense.append(CGPoint(x: last.x + (point.x - last.x) * t, y: last.y + (point.y - last.y) * t))
            }
        }
        dense.append(point)
    }
    var pieces: [[CGPoint]] = []
    var run: [CGPoint] = []
    for point in dense {
        if hypot(point.x - center.x, point.y - center.y) <= radius {
            if run.count > 1 { pieces.append(run) }
            run = []
        } else {
            run.append(point)
        }
    }
    if run.count > 1 { pieces.append(run) }
    // Nothing touched: hand back the original points, not the filled-in ones.
    if pieces.count == 1, pieces[0].count == dense.count { return [points] }
    return pieces
}

extension ScreenAnnotationModel.Mark {
    /// How wide the mark draws (for its hit area and box).
    var lineWidth: CGFloat {
        switch tool {
        case .highlighter: 22
        case .arrow: 22   // the head
        default: 4
        }
    }

    /// The box around what's drawn.
    var bounds: CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
    }

    /// Is the point on the drawn line (within a finger's slack)?
    func hits(_ point: CGPoint, slack: CGFloat = 8) -> Bool {
        let reach = lineWidth / 2 + slack
        guard bounds.insetBy(dx: -slack, dy: -slack).contains(point) else { return false }
        if points.count == 1 { return hypot(point.x - points[0].x, point.y - points[0].y) <= reach }
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index]
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared == 0 ? 0 : max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
            let closest = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
            if hypot(point.x - closest.x, point.y - closest.y) <= reach { return true }
        }
        return false
    }

    func moved(by delta: CGSize) -> Self {
        var copy = self
        copy.points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
        return copy
    }

    /// Scaled so its box goes from `from` to `to` (top-left anchored).
    func scaled(from: CGRect, to: CGRect) -> Self {
        var copy = self
        let sx = from.width > 0 ? to.width / from.width : 1
        let sy = from.height > 0 ? to.height / from.height : 1
        copy.points = points.map {
            CGPoint(x: to.minX + ($0.x - from.minX) * sx, y: to.minY + ($0.y - from.minY) * sy)
        }
        return copy
    }
}

// MARK: - Painting

/// Draws one mark into the current NSGraphicsContext (any flipped, top-left
/// coordinate space). Upstream's `AnnotationCanvasView.draw(_:)`, lifted out
/// so the canvas and the Stage's image draw exactly the same thing.
enum AnnotationPainter {
    static func draw(_ mark: ScreenAnnotationModel.Mark) {
        switch mark.tool {
        case .pointer, .eraser:
            return
        case .pen, .highlighter:
            guard !mark.points.isEmpty else { return }
            let highlighter = mark.tool == .highlighter
            let path = NSBezierPath()
            path.lineWidth = highlighter ? 22 : 4
            path.lineCapStyle = highlighter ? .square : .round
            path.lineJoinStyle = .round
            path.move(to: mark.points[0])
            if mark.points.count == 1 {
                path.line(to: mark.points[0])
            } else {
                // Midpoint curves: a smooth line through the drag.
                for index in 1..<mark.points.count {
                    let previous = mark.points[index - 1], point = mark.points[index]
                    let mid = CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2)
                    path.curve(to: mid, controlPoint1: previous, controlPoint2: previous)
                }
                path.line(to: mark.points[mark.points.count - 1])
            }
            mark.color.withAlphaComponent(highlighter ? 0.35 : 1).setStroke()
            path.stroke()
        case .arrow:
            guard let end = mark.points.last, let start = mark.points.first else { return }
            let angle = atan2(end.y - start.y, end.x - start.x)
            let head: CGFloat = 22
            // The shaft stops at the head's base so the tip stays sharp.
            let base = CGPoint(x: end.x - cos(angle) * head * 0.8, y: end.y - sin(angle) * head * 0.8)
            let shaft = NSBezierPath()
            shaft.lineWidth = 5
            shaft.lineCapStyle = .round
            shaft.move(to: start)
            shaft.line(to: base)
            let tip = NSBezierPath()
            tip.move(to: end)
            tip.line(to: CGPoint(x: end.x - cos(angle - .pi / 7) * head, y: end.y - sin(angle - .pi / 7) * head))
            tip.line(to: CGPoint(x: end.x - cos(angle + .pi / 7) * head, y: end.y - sin(angle + .pi / 7) * head))
            tip.close()
            // A thin dark outline keeps light colors readable on any screen.
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            mark.color.setStroke()
            mark.color.setFill()
            shaft.stroke()
            tip.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

// MARK: - The Stage's copy of the marks

/// The marks as a picture the same shape as the screen they were drawn on.
/// `frame` is the screen area it covers (global CG points); the Stage fits
/// this image over the screen content exactly as it fits the screen itself,
/// so a mark lands where it was drawn without the Stage knowing any geometry.
struct StageMarksOverlay {
    var image: CGImage
    var frame: CGRect
}

enum AnnotationMarksRenderer {
    /// Longest side of the picture the marks are drawn into: about the
    /// Stage's own canvas, so a mark is as sharp as the screen under it.
    static let targetSize = CGSize(width: 1920, height: 1080)

    /// Pixels per point for a `frame`-sized screen area.
    static func scale(for frame: CGRect) -> CGFloat {
        guard frame.width > 0, frame.height > 0 else { return 1 }
        return min(4, min(targetSize.width / frame.width, targetSize.height / frame.height))
    }

    /// Draws `marks` (global points) onto a transparent image covering `frame`.
    /// Nil when there is nothing in the frame to draw. `clip` (global points)
    /// cuts the marks to a window's bounds.
    @MainActor
    static func image(of marks: [ScreenAnnotationModel.Mark], over frame: CGRect, clip: CGRect? = nil) -> StageMarksOverlay? {
        guard frame.width >= 2, frame.height >= 2 else { return nil }
        let visible = marks.filter { $0.bounds.intersects(frame) }
        guard !visible.isEmpty else { return nil }
        let s = scale(for: frame)
        let width = max(2, Int((frame.width * s).rounded())), height = max(2, Int((frame.height * s).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Top-down, in points, origin at the frame's corner.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: s, y: -s)
        context.translateBy(x: -frame.minX, y: -frame.minY)
        if let clip { context.clip(to: clip) }
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        for mark in visible { AnnotationPainter.draw(mark) }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        return StageMarksOverlay(image: image, frame: frame)
    }
}

// MARK: - Where a mark lands (pure, for tests)

/// The mapping from a global screen point to a canvas pixel, written out as
/// plain arithmetic. It is what the Stage achieves by fitting the overlay
/// image over the screen content, and it is the same maths as
/// `StageCompositor.videoPosition(ofGlobalPoint:)` (phase 2).
enum MarkProjection {
    /// `source`: the captured display or followed window (global points).
    /// `placed`: where the renderer drew the screen (canvas pixels, top-left).
    static func canvasPoint(forGlobal p: CGPoint, source: CGRect, placed: CGRect) -> CGPoint? {
        guard source.width > 1, source.height > 1, placed.width > 0, placed.height > 0,
              source.contains(p) else { return nil }
        let u = (p.x - source.minX) / source.width
        let v = (p.y - source.minY) / source.height
        return CGPoint(x: placed.minX + u * placed.width, y: placed.minY + v * placed.height)
    }
}
