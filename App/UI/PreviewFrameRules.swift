//
//  PreviewFrameRules.swift
//
//  Home's preview card shows the composited 1920x1080 canvas, cropped to the
//  shared content when there is one (a 16:10 Mac then fills its frame, with
//  no pillarbox bars), and lets the presenter drag the camera in it. These are
//  the pure parts: the crop, the canvas's place behind the frame, and the
//  camera's rect in the frame, both ways. The camera maths is PresenceGeometry
//  with the frame as "the display", so the preview, the floating bubble and
//  the stage agree by construction.
//
import CoreGraphics

enum PreviewFrameRules {
    /// The compositor's canvas, canvas pixels.
    static let canvas = CGSize(width: 1920, height: 1080)

    /// What to show of the canvas, as a unit rect (top-left origin): the
    /// content rect when a screen or window is drawn (Presenter keeps the
    /// whole canvas: the camera is the other half of that picture), else the
    /// whole canvas.
    static func crop(content: CGRect?, presenter: Bool) -> CGRect {
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard !presenter, let c = content, c.width > 1, c.height > 1 else { return whole }
        let r = CGRect(x: c.minX / canvas.width, y: c.minY / canvas.height,
                       width: c.width / canvas.width, height: c.height / canvas.height)
            .intersection(whole)
        return r.isNull || r.width < 0.05 || r.height < 0.05 ? whole : r
    }

    /// Width over height of the picture for a unit crop of a canvas of `canvasAspect`.
    static func aspect(canvasAspect: CGFloat, crop: CGRect) -> CGFloat {
        guard crop.height > 0 else { return canvasAspect }
        return canvasAspect * crop.width / crop.height
    }

    /// True while a screen share's content rect has not arrived: the first frame
    /// after the picture opens can come before the compositor knows it, and the
    /// whole 16:9 canvas is then NOT the picture's shape. The card holds its
    /// last real shape until the rect is there.
    static func awaitingContent(capturesScreen: Bool, presenter: Bool, content: CGRect?) -> Bool {
        guard capturesScreen, !presenter else { return false }
        guard let c = content else { return true }
        return !(c.width > 1 && c.height > 1)
    }

    /// Home's card width: the setup column's height less the eyebrow, times the
    /// picture's aspect, so the picture fills the card. The aspect is held to
    /// 1:1...21:9 so an odd share never makes a sliver or a window wider than a screen.
    static func cardWidth(columnHeight: CGFloat, eyebrow: CGFloat, aspect: CGFloat) -> CGFloat {
        let a = min(max(aspect.isFinite ? aspect : 16.0 / 10.0, 1), 21.0 / 9.0)
        return (max(columnHeight - eyebrow, 0) * a).rounded()
    }

    /// The aspect the card is sized from, given the one it has and what the
    /// picture says now. Only a real picture changes it: with none (Home left
    /// for a page and its camera stopped, or the picture not up yet) the card
    /// keeps its last real shape, so the window Home returns to still fits it
    /// and the first frame back does not resize the window a second time.
    static func heldAspect(current: CGFloat, live: CGFloat?) -> CGFloat {
        guard let live, live.isFinite, abs(live - current) > 0.001 else { return current }
        return live
    }

    /// The width Home returns to: the one it left, but never less than its
    /// content needs, or the content overflows the window and its margins go.
    static func returnWidth(remembered: CGFloat?, current: CGFloat, floor: CGFloat) -> CGFloat {
        max(remembered ?? current, floor)
    }

    /// The aspect Home assumes before the first frame: the main display's.
    static func defaultAspect(screen: CGSize?) -> CGFloat {
        guard let s = screen, s.width > 0, s.height > 0 else { return 16.0 / 10.0 }
        return s.width / s.height
    }

    /// Where the whole canvas lies, in the frame's own space, so that `crop` fills `frame`.
    static func canvasRect(frame: CGRect, crop: CGRect) -> CGRect {
        guard crop.width > 0, crop.height > 0 else { return frame }
        let w = frame.width / crop.width, h = frame.height / crop.height
        return CGRect(x: frame.minX - crop.minX * w, y: frame.minY - crop.minY * h, width: w, height: h)
    }

    /// The geometry that maps the frame (a "display" of the frame's own size)
    /// and the content rect (canvas px) to camera boxes. `content` nil: the
    /// canvas fills the frame.
    static func geometry(frame: CGSize, content: CGRect?) -> PresenceGeometry {
        PresenceGeometry(display: CGRect(origin: .zero, size: frame), content: content)
    }

    /// The camera's rect in the frame, top-left origin.
    static func cameraRect(box: PresenceBox, aspect: Double, frame: CGSize, content: CGRect?) -> CGRect {
        let g = geometry(frame: frame, content: content)
        let f = g.frame(for: box, aspect: aspect)          // y up
        return CGRect(x: f.minX, y: frame.height - f.maxY, width: f.width, height: f.height)
    }

    /// `box` with the camera moved or resized to `rect` (frame space, top-left
    /// origin), clamped inside the content as the bubble's is.
    static func box(applying rect: CGRect, to box: PresenceBox, aspect: Double,
                    frame: CGSize, content: CGRect?) -> PresenceBox {
        let g = geometry(frame: frame, content: content)
        let up = CGRect(x: rect.minX, y: frame.height - rect.maxY, width: rect.width, height: rect.height)
        return g.layout(applying: up, to: box, aspect: aspect)
    }

    /// A point in the frame as a fraction of the content (unit, top-left).
    static func contentFraction(of point: CGPoint, frame: CGSize) -> CGPoint {
        CGPoint(x: frame.width > 0 ? point.x / frame.width : 0, y: frame.height > 0 ? point.y / frame.height : 0)
    }

    /// A point in the frame as canvas pixels, given the crop.
    static func canvasPoint(of point: CGPoint, frame: CGSize, crop: CGRect) -> CGPoint {
        let f = contentFraction(of: point, frame: frame)
        return CGPoint(x: (crop.minX + f.x * crop.width) * canvas.width,
                       y: (crop.minY + f.y * crop.height) * canvas.height)
    }
}

/// Display points <-> builder canvas, with no view in it. The builder's display
/// box is the display at its real shape, so it is "the display" of
/// PresenceGeometry and the content rect is the display aspect-fitted on the
/// 1920x1080 canvas, exactly as the stage draws it.
enum LayoutCameraRules {
    /// Where a display of `displayAspect` is drawn on the 1920x1080 canvas.
    static func content(displayAspect: CGFloat) -> CGRect {
        let canvas = PreviewFrameRules.canvas
        let a = max(Double(displayAspect), 0.1)
        if a >= canvas.width / canvas.height {
            let h = canvas.width / a
            return CGRect(x: 0, y: (canvas.height - h) / 2, width: canvas.width, height: h)
        }
        let w = canvas.height * a
        return CGRect(x: (canvas.width - w) / 2, y: 0, width: w, height: canvas.height)
    }

    static func geometry(frame: CGSize, displayAspect: CGFloat) -> PresenceGeometry {
        PreviewFrameRules.geometry(frame: frame, content: content(displayAspect: displayAspect))
    }

    /// The camera's rect in the builder canvas of `frame` points (top-left
    /// origin): placed on the WHOLE display exactly as the bubble is, then moved
    /// by where the usable area sits in it. May run past the canvas edge into
    /// the menu bar / Dock zone.
    static func rect(box: PresenceBox, aspect: Double, frame: CGSize, space: LayoutCameraSpace) -> CGRect {
        let full = space.fullFrame(for: frame), o = space.origin(for: frame)
        return rect(box: box, aspect: aspect, frame: full, displayAspect: full.width / max(full.height, 1)).offsetBy(dx: o.x, dy: o.y)
    }

    /// Where the camera layer may be drawn on a canvas of `frame` points: the canvas itself (its content
    /// rect, inside the bezel padding), widened only by the menu bar / Dock zone of the whole display
    /// when `space` says the display is bigger than the usable area. Never into the bezel padding.
    static func drawable(frame: CGSize, space: LayoutCameraSpace?) -> CGRect {
        let canvas = CGRect(origin: .zero, size: frame)
        guard let space else { return canvas }
        return canvas.union(CGRect(origin: space.origin(for: frame), size: space.fullFrame(for: frame)))
    }

    /// `rect` moved (never resized unless it is larger than `area`) to lie inside `area`.
    static func clamped(_ rect: CGRect, to area: CGRect) -> CGRect {
        let w = min(rect.width, area.width), h = min(rect.height, area.height)
        let x = min(max(rect.minX, area.minX), area.maxX - w)
        let y = min(max(rect.minY, area.minY), area.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// `box` for a camera moved or resized to `rect` in the builder canvas.
    static func box(applying rect: CGRect, to box: PresenceBox, aspect: Double,
                    frame: CGSize, space: LayoutCameraSpace) -> PresenceBox {
        let full = space.fullFrame(for: frame), o = space.origin(for: frame)
        return Self.box(applying: rect.offsetBy(dx: -o.x, dy: -o.y), to: box, aspect: aspect,
                        frame: full, displayAspect: full.width / max(full.height, 1))
    }

    /// The width range (canvas points) the camera may take on the whole display.
    static func widthRange(for box: PresenceBox, aspect: Double, frame: CGSize, space: LayoutCameraSpace) -> ClosedRange<CGFloat> {
        let full = space.fullFrame(for: frame)
        return PreviewFrameRules.geometry(frame: full, content: content(displayAspect: full.width / max(full.height, 1)))
            .widthRange(for: box, aspect: aspect)
    }

    /// The camera's rect inside a canvas of `frame` points, top-left origin.
    static func rect(box: PresenceBox, aspect: Double, frame: CGSize, displayAspect: CGFloat) -> CGRect {
        PreviewFrameRules.cameraRect(box: box, aspect: aspect, frame: frame,
                                     content: content(displayAspect: displayAspect))
    }

    /// `box` with the camera moved or resized to `rect` (canvas points, top-left origin).
    static func box(applying rect: CGRect, to box: PresenceBox, aspect: Double,
                    frame: CGSize, displayAspect: CGFloat) -> PresenceBox {
        PreviewFrameRules.box(applying: rect, to: box, aspect: aspect, frame: frame,
                              content: content(displayAspect: displayAspect))
    }
}

/// Where the builder's canvas (the display's USABLE area, without menu bar and
/// Dock) sits inside the whole display, which is what the bubble and the stage
/// map against. `usable` is in whole-display points, top-left origin.
struct LayoutCameraSpace: Equatable {
    var full: CGSize
    var usable: CGRect

    init(full: CGSize, usable: CGRect) { self.full = full; self.usable = usable }

    /// From an NSScreen's `frame` and `visibleFrame` (Cocoa, bottom-left origin).
    init(frame: CGRect, visibleFrame: CGRect) {
        self.init(full: frame.size,
                  usable: CGRect(x: visibleFrame.minX - frame.minX, y: frame.maxY - visibleFrame.maxY,
                                 width: visibleFrame.width, height: visibleFrame.height))
    }

    /// Builder canvas points per display point, for a canvas drawn `frame` big.
    func scale(frame: CGSize) -> CGFloat { usable.width > 0 ? frame.width / usable.width : 1 }
    /// The whole display at that scale.
    func fullFrame(for frame: CGSize) -> CGSize {
        let s = scale(frame: frame)
        return CGSize(width: full.width * s, height: full.height * s)
    }
    /// Where the whole display's top-left corner falls in the canvas (negative: outside it).
    func origin(for frame: CGSize) -> CGPoint {
        let s = scale(frame: frame)
        return CGPoint(x: -usable.minX * s, y: -usable.minY * s)
    }
}

/// How often the picture for Home and Settings is taken from the compositor
/// (which ticks at 30). Outside a live meeting nothing else is competing, so
/// the preview follows the drag at the full rate; while one is live the
/// meeting, the recorder and the preview share the machine, so it halves.
enum PreviewRate {
    static func framesPerSecond(meetingLive: Bool) -> Double { meetingLive ? 15 : 30 }
}
