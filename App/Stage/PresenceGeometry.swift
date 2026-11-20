//
//  PresenceGeometry.swift
//  Greenroom
//
//  The presence bubble's maths, with no AppKit window in it: where the camera
//  sits on the real screen (Cocoa points, bottom-left origin) and where it sits
//  in the class picture (StageLayout fractions (as a PresenceBox) of the 1920x1080 canvas,
//  measured from the top-left like StageRenderer.cameraLayer).
//
//  The display is drawn on the canvas inside `content`. A whole display of
//  another shape than 16:9 is aspect-fitted, so `content` is smaller than the
//  canvas; the scale from points to canvas pixels is `content.width / display.width`
//  and the same on both axes. Every function here is its own inverse's partner:
//  `frame(for:)` then `layout(applying:to:)` gives the layout back.
//
import CoreGraphics
import Foundation

/// The five numbers of StageLayout that place the camera, and whether the look
/// is the Cutout (own height and inset, flush with the bottom). Kept apart from
/// StageLayout so this file and its tests need nothing else.
struct PresenceBox: Equatable {
    var widthFraction = 0.24
    var rightInset = 0.045
    var bottomInset = 0.06
    var cutoutHeightFraction = 0.5
    var cutoutRightInset = 0.02
    var isCutout = false
}

struct PresenceGeometry: Equatable {
    /// The display being shared, in global Cocoa points (bottom-left origin).
    var display: CGRect
    /// Where that display is drawn on the canvas, top-left origin, canvas
    /// pixels. Nil: it fills the canvas.
    var content: CGRect?
    var canvas = CGSize(width: 1920, height: 1080)

    /// The ranges the coordinator clamps to (CoordinatorController.bubble*).
    static let widthFractions: ClosedRange<Double> = 0.08...0.6
    static let insets: ClosedRange<Double> = 0...0.9
    static let cutoutHeights: ClosedRange<Double> = 0.3...1.0

    /// Canvas pixels per screen point.
    var scale: Double {
        let c = content ?? CGRect(origin: .zero, size: canvas)
        return display.width > 0 ? c.width / display.width : 1
    }
    private var contentRect: CGRect { content ?? CGRect(origin: .zero, size: canvas) }

    /// Where the renderer draws the camera, canvas pixels, top-left origin:
    /// the one source of truth for `StageRenderer.cameraLayer` and for the
    /// bubble. `aspect` is the picture's width over height after the shape's
    /// crop (1 for circle and square). Rounded exactly as the renderer does.
    /// `bounds` is where the camera may sit: the drawn content rect while a
    /// screen or window is shown (never the letterbox or pillarbox bars), the
    /// whole canvas when nil. Sizes are still fractions of the canvas; the
    /// box is capped to fit `bounds` and slid inside it.
    static func cameraRect(for box: PresenceBox, aspect: Double, canvas: CGSize, bounds: CGRect? = nil) -> CGRect {
        let a = max(aspect, 0.1)
        let W = canvas.width, H = canvas.height
        let b = bounds ?? CGRect(origin: .zero, size: canvas)
        if box.isCutout {
            // layoutCutout: flush with the bottom of the bounds, own height and inset.
            let h = min(H * box.cutoutHeightFraction, b.height, b.width / a), w = h * a
            return CGRect(x: inside(W - W * box.cutoutRightInset - w, size: w, from: b.minX, to: b.maxX), y: b.maxY - h, width: w, height: h)
        }
        // positionBubble: the box has the picture's own aspect.
        let boxW = min(W * box.widthFraction, b.height * a, b.width).rounded()
        let boxH = (boxW / a).rounded()
        return CGRect(x: inside((W - W * box.rightInset - boxW).rounded(), size: boxW, from: b.minX, to: b.maxX),
                      y: inside((H - H * box.bottomInset - boxH).rounded(), size: boxH, from: b.minY, to: b.maxY),
                      width: boxW, height: boxH)
    }

    /// `origin` moved so that `size` fits in from...to (pinned to `from` when it cannot).
    private static func inside(_ origin: Double, size: Double, from: Double, to: Double) -> Double {
        max(from, min(origin, to - size))
    }

    /// The widest the camera box may be so that it fits the bounds: the shape's
    /// own limit, and the box's height (width over aspect) within the bounds'
    /// height. For the Cutout the limit is on its height (and its width).
    func maxWidthFraction(for layout: PresenceBox, aspect: Double) -> Double {
        let a = max(aspect, 0.1), b = contentRect
        if layout.isCutout {
            return min(Self.cutoutHeights.upperBound, b.height / canvas.height, b.width / (canvas.height * a))
        }
        return min(Self.widthFractions.upperBound, b.height * a / canvas.width, b.width / canvas.width)
    }

    /// Where the camera may sit on the real screen (Cocoa points): the shared
    /// display itself, since the camera stays over the content, never in the bars.
    var boundsOnScreen: CGRect { display }

    /// `frame` slid (not resized) to lie inside the display on screen.
    func slid(_ frame: CGRect) -> CGRect {
        let b = boundsOnScreen
        var f = frame
        f.origin.x = max(b.minX, min(f.minX, b.maxX - f.width))
        f.origin.y = max(b.minY, min(f.minY, b.maxY - f.height))
        return f
    }

    /// The camera's box on the real screen: the renderer's rect, taken back
    /// through the content rect to display points (Cocoa, bottom-left origin).
    func frame(for layout: PresenceBox, aspect: Double) -> CGRect {
        let r = Self.cameraRect(for: layout, aspect: aspect, canvas: canvas, bounds: contentRect)
        let c = contentRect, s = scale
        let w = r.width / s, h = r.height / s
        let x = display.minX + (r.minX - c.minX) / s
        let top = display.maxY - (r.minY - c.minY) / s
        return CGRect(x: x, y: top - h, width: w, height: h)
    }

    /// `layout` with the camera box moved to `frame`, clamped to what the
    /// coordinator accepts and so that the whole box stays inside the content
    /// rect. Only the fields the shape uses change.
    func layout(applying frame: CGRect, to layout: PresenceBox, aspect: Double = 16.0 / 9.0) -> PresenceBox {
        var out = layout
        let a = max(aspect, 0.1)
        let c = contentRect, s = scale
        let rightPx = c.minX + (frame.maxX - display.minX) * s
        let bottomPx = c.minY + (display.maxY - frame.minY) * s
        let maxWidth = maxWidthFraction(for: layout, aspect: a)
        // Insets are canvas fractions; the box must lie between the content's edges.
        let rightMin = (canvas.width - c.maxX) / canvas.width
        let bottomMin = (canvas.height - c.maxY) / canvas.height
        if layout.isCutout {
            let height = Self.clamp(frame.height * s / canvas.height, Self.cutoutHeights.lowerBound...max(Self.cutoutHeights.lowerBound, maxWidth))
            let boxW = height * canvas.height * a / canvas.width           // the box's width, as a canvas fraction
            out.cutoutHeightFraction = height
            let rightMax = (canvas.width - c.minX) / canvas.width - boxW
            out.cutoutRightInset = Self.clamp((canvas.width - rightPx) / canvas.width, rightMin...max(rightMin, min(Self.insets.upperBound, rightMax)))
        } else {
            let width = Self.clamp(frame.width * s / canvas.width, Self.widthFractions.lowerBound...max(Self.widthFractions.lowerBound, maxWidth))
            let boxH = width * canvas.width / a / canvas.height            // the box's height, as a canvas fraction
            out.widthFraction = width
            let rightMax = (canvas.width - c.minX) / canvas.width - width
            let bottomMax = (canvas.height - c.minY) / canvas.height - boxH
            out.rightInset = Self.clamp((canvas.width - rightPx) / canvas.width, rightMin...max(rightMin, min(Self.insets.upperBound, rightMax)))
            out.bottomInset = Self.clamp((canvas.height - bottomPx) / canvas.height, bottomMin...max(bottomMin, min(Self.insets.upperBound, bottomMax)))
        }
        return out
    }

    /// How much one tap of the quick controls' Bigger / Smaller changes the size:
    /// a fraction of the canvas width (of its height for the Cutout).
    static let sizeStep = 0.05

    /// Which edge of the bubble stays put while it is resized.
    enum SizeAnchor { case center, top, bottom }

    /// The box one step bigger (`steps` > 0) or smaller (< 0).
    func stepped(_ box: PresenceBox, aspect: Double, steps: Int, anchor: SizeAnchor = .center) -> PresenceBox {
        stepped(box, aspect: aspect, by: Self.sizeStep * Double(steps), anchor: anchor)
    }

    /// The box `amount` bigger (or smaller when negative), as a fraction of the
    /// canvas width (height for the Cutout). `.top` keeps the top edge's centre
    /// fixed, `.bottom` the bottom edge's, `.center` the middle; the Cutout is
    /// always flush with the bottom. Stops at the limits (the shape's own, and
    /// what fits in the content) and is slid back inside the content.
    func stepped(_ box: PresenceBox, aspect: Double, by amount: Double, anchor: SizeAnchor = .center) -> PresenceBox {
        let a = max(aspect, 0.1), s = scale
        let current = frame(for: box, aspect: a)
        let top = maxWidthFraction(for: box, aspect: a)
        let range = box.isCutout ? Self.cutoutHeights : Self.widthFractions
        let limits = range.lowerBound...max(range.lowerBound, top)
        let now = box.isCutout ? current.height * s / canvas.height : current.width * s / canvas.width
        let next = Self.clamp(now + amount, limits)
        let w = box.isCutout ? next * canvas.height * a / s : next * canvas.width / s
        let h = w / a
        let y: Double
        switch box.isCutout ? SizeAnchor.bottom : anchor {   // Cocoa y is up: the top edge is maxY
        case .center: y = current.midY - h / 2
        case .top: y = current.maxY - h
        case .bottom: y = current.minY
        }
        let f = slid(CGRect(x: current.midX - w / 2, y: y, width: w, height: h))
        return layout(applying: f, to: box, aspect: a)
    }

    /// Smallest and largest width the bubble may take on the real screen
    /// (the largest keeps the whole box inside the canvas).
    func widthRange(for layout: PresenceBox, aspect: Double) -> ClosedRange<CGFloat> {
        let s = scale, a = max(aspect, 0.1)
        let top = maxWidthFraction(for: layout, aspect: a)
        if layout.isCutout {
            let r = Self.cutoutHeights
            return CGFloat(r.lowerBound * canvas.height * a / s)...CGFloat(max(r.lowerBound, top) * canvas.height * a / s)
        }
        let r = Self.widthFractions
        return CGFloat(r.lowerBound * canvas.width / s)...CGFloat(max(r.lowerBound, top) * canvas.width / s)
    }

    private static func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(max(v, r.lowerBound), r.upperBound) }
}

/// Whether the Cutout's 14pt edge band (a 2% black ring that lets the window
/// server hand resize cursors to a transparent window) may be drawn. Drawn all
/// the time it shows as a faint frame around the person on a smooth wallpaper
/// (owner, 2026-11-20), so it exists only while the pointer is over the bubble,
/// when the hover outline is on screen anyway. Other shapes never need it.
enum PresenceHitBand {
    static func isDrawn(isCutout: Bool, pointerOverBubble: Bool, interacting: Bool) -> Bool {
        isCutout && (pointerOverBubble || interacting)
    }
}
