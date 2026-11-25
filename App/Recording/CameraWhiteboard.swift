//
//  CameraWhiteboard.swift
//  Greenroom
//
//  Ported from Recorditor (ZRecorditor @7210322, native/MacRecorder/Recording/CameraWhiteboard.swift).
//  Phase 5 of the Recorditor port, see docs/recorditor-integration/drawing-port-log.md.
//
//  A white 16:9 page to draw on. In Greenroom it is a "Behind you" choice
//  (ShareTarget.Kind.whiteboard): the page is rendered to an image whenever it
//  changes and the Stage uses that image as the screen content, so the camera
//  composites over it with the user's own shape and position. Upstream drew a
//  fixed inset in the corner (`insetFraction`); that logic is not needed here.
//
//  Strokes are kept in page coordinates (0...1), so the window and the Stage's
//  1920 x 1080 picture draw the same thing at any size.
//
import AppKit
import CoreGraphics

@MainActor
final class CameraWhiteboardModel: ObservableObject {
    struct Stroke {
        var color: NSColor
        var points: [CGPoint]
    }

    /// The page's shape: the Stage canvas is 16:9.
    static let aspect: CGFloat = 16 / 9

    static let colors: [NSColor] = [
        NSColor(red: 0.07, green: 0.09, blue: 0.14, alpha: 1),
        NSColor(red: 1.00, green: 0.29, blue: 0.31, alpha: 1),
        NSColor(red: 0.16, green: 0.39, blue: 0.94, alpha: 1),
        NSColor(red: 0.13, green: 0.66, blue: 0.33, alpha: 1),
        NSColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 1),
    ]

    @Published var color: NSColor = colors[0] { didSet { isErasing = false } }
    /// Drag rubs out instead of drawing.
    @Published var isErasing = false
    @Published private(set) var strokes: [Stroke] = []
    @Published var current: Stroke?

    var canUndo: Bool { !strokes.isEmpty }

    func begin(at point: CGPoint) {
        current = Stroke(color: color, points: [point])
    }

    func extend(to point: CGPoint) {
        guard var stroke = current else { return }
        if let last = stroke.points.last, hypot(point.x - last.x, point.y - last.y) < 0.0012 { return }
        stroke.points.append(point)
        current = stroke
    }

    func finish() {
        guard let stroke = current else { return }
        current = nil
        strokes.append(stroke)
    }

    func replace(at index: Int, with stroke: Stroke) {
        guard strokes.indices.contains(index) else { return }
        strokes[index] = stroke
    }

    func remove(at index: Int) {
        guard strokes.indices.contains(index) else { return }
        strokes.remove(at: index)
    }

    /// Rubs out what's within `radius` (view points) of a view point, on a
    /// page of the given size: lines lose that stretch, splitting if need be.
    func erase(at point: CGPoint, radius: CGFloat, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let reach = radius + max(2, size.width * 0.0042) / 2
        var result: [Stroke] = []
        var changed = false
        for stroke in strokes {
            let viewPoints = stroke.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            let pieces = erasePolyline(viewPoints, around: point, radius: reach)
            if pieces.count == 1, pieces[0].count == viewPoints.count {
                result.append(stroke)
            } else {
                changed = true
                result += pieces.map { piece in
                    Stroke(color: stroke.color,
                           points: piece.map { CGPoint(x: $0.x / size.width, y: $0.y / size.height) })
                }
            }
        }
        if changed { strokes = result }
    }

    func undo() { _ = strokes.popLast() }
    func clear() { strokes.removeAll() }

    func reset() {
        strokes.removeAll()
        current = nil
        isErasing = false
    }

    /// The page as the Stage shows it.
    func renderPage(width: Int) -> CGImage? {
        let height = Int((CGFloat(width) / Self.aspect).rounded())
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // Page coordinates run top-down, like the view.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        Self.draw(strokes + (current.map { [$0] } ?? []), in: context,
                  size: CGSize(width: width, height: height))
        return context.makeImage()
    }

    /// White page and strokes, in a top-down context of the given size.
    nonisolated static func draw(_ strokes: [Stroke], in context: CGContext, size: CGSize) {
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        // Line weight follows the page, so a 4 pt line on a 960 pt page is
        // the same weight in a 1920 px frame.
        context.setLineWidth(max(2, size.width * 0.0042))
        for stroke in strokes {
            let points = stroke.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            guard let first = points.first else { continue }
            context.setStrokeColor(stroke.color.cgColor)
            context.beginPath()
            context.move(to: first)
            if points.count == 1 {
                context.addLine(to: first)
            } else {
                for index in 1..<points.count {
                    let previous = points[index - 1], point = points[index]
                    let mid = CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2)
                    context.addQuadCurve(to: mid, control: previous)
                }
                context.addLine(to: points[points.count - 1])
            }
            context.strokePath()
        }
    }
}

/// Two different things people call "the whiteboard", kept apart.
/// PRESENTING it is a share target (Home's Screen panel, "Whiteboard"): the
/// meeting sees the page. OPENING it from the drawing tools (Annotations) is
/// only a white window on the owner's screen: the share target and the Stage
/// are left alone, and the window follows "Show on my share" like any other.
enum WhiteboardOpenRules {
    enum Action: Equatable {
        /// An ordinary white window, share target untouched.
        case openLocal
        /// The local window is up: the tool puts it away again.
        case closeLocal
        /// The whiteboard is already the share target: its window is the one to show.
        case raisePresented
    }

    /// What the drawing tools' Whiteboard button (and W) does.
    static func toolAction(shareIsWhiteboard: Bool, localIsOpen: Bool) -> Action {
        if shareIsWhiteboard { return .raisePresented }
        return localIsOpen ? .closeLocal : .openLocal
    }

    /// Whether a stroke change should re-render the page for the Stage: only
    /// while the whiteboard IS the share target.
    static func feedsStage(shareIsWhiteboard: Bool) -> Bool { shareIsWhiteboard }

    /// What "Back to screen" returns to. When the share becomes the whiteboard, the target it
    /// replaced is remembered; moving between other targets forgets it, and a change while the
    /// whiteboard stays the share (or a change out of it) keeps what was remembered.
    static func remembered<T>(_ current: T?, replaced old: T, oldIsWhiteboard: Bool, newIsWhiteboard: Bool) -> T? {
        if newIsWhiteboard { return oldIsWhiteboard ? current : old }
        return oldIsWhiteboard ? current : nil
    }

    /// Where "Back to screen" goes: the remembered target, else `fallback`.
    static func returnTarget<T>(remembered: T?, fallback: T) -> T { remembered ?? fallback }

    /// What closing the local whiteboard window does to the drawing state it found.
    enum CloseOutcome: Equatable {
        /// The screen canvas had stepped aside for it: it comes back.
        case resumeCanvas
        /// Nothing was suspended (or nothing is shared): drawing is simply off again.
        case drawingOff
        /// The presented whiteboard owns the drawing state: leave it alone.
        case untouched
    }

    static func closeOutcome(wasSuspended: Bool, shareIsWhiteboard: Bool, shareIsNothing: Bool) -> CloseOutcome {
        if shareIsWhiteboard { return .untouched }
        return wasSuspended && !shareIsNothing ? .resumeCanvas : .drawingOff
    }
}
