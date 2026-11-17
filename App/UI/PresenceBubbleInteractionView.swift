//
//  PresenceBubbleInteractionView.swift
//  Greenroom
//
//  Ported from Recorditor's BubbleInteractionView (docs/recorditor-integration/):
//  cursor affordances and edge/corner resizing for the floating camera, in
//  plain AppKit. A tracking area with .activeAlways drives the cursor (a
//  non-activating panel never becomes key, so cursor rects never fire). The
//  edge band and corners resize; the middle drags the panel.
//
//  Changed from Recorditor: the box keeps the picture's own aspect (a circle is
//  square, a Rounded camera is 16:9 or whatever the camera is) instead of a
//  fixed 16:9, the width limits come from the owner, and the result is a whole
//  frame (the owner turns it into StageLayout fractions), not a screen fraction.
//
import AppKit

final class PresenceBubbleInteractionView: NSView {
    /// The frame an edge drag asks for, in screen points.
    var onResize: ((NSRect) -> Void)?
    /// A drag (move or resize) began or ended.
    var onInteraction: ((Bool) -> Void)?
    /// Width over height of the box.
    var aspect: () -> CGFloat = { 16.0 / 9.0 }
    /// Smallest and largest width, in points.
    var widthRange: () -> ClosedRange<CGFloat> = { 80...800 }
    /// Where the box must stay (screen points): the canvas as it lies on the
    /// screen. Nil: no limit.
    var limit: () -> NSRect? = { nil }
    /// The ring that says "this is a handle", on hover only.
    var onHover: ((Bool) -> Void)?
    /// Scroll wheel or two-finger scroll: a size change as a fraction of the
    /// canvas width (positive: bigger), and whether the gesture has ended.
    var onScroll: ((Double, Bool) -> Void)?
    /// The Cutout stands on the bottom of the content: its bottom edge never
    /// moves, so the bottom edge is not a handle (it drags the bubble) and the
    /// bottom corners only change its width. Height still drives the size.
    var flushBottom: () -> Bool = { false }

    private let edgeBand: CGFloat = 12
    private let cornerBand: CGFloat = 20
    private var resizing = false
    private var moving = false
    private var grabOffset = NSPoint.zero   // mouse minus the window's origin, at mouse-down
    private var initialFrame = NSRect.zero
    private var dragRight: Bool?   // nil = no horizontal edge grabbed
    private var dragTop: Bool?     // nil = no vertical edge grabbed

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func band(at p: NSPoint) -> (right: Bool?, top: Bool?)? {
        guard bounds.contains(p) else { return nil }
        let inLeft = p.x < cornerBand, inRight = p.x > bounds.width - cornerBand
        let inBottom = p.y < cornerBand, inTop = p.y > bounds.height - cornerBand
        if (inLeft || inRight) && (inBottom || inTop) { return (right: inRight, top: inTop) }
        let right: Bool? = p.x < edgeBand ? false : (p.x > bounds.width - edgeBand ? true : nil)
        let top: Bool? = p.y < edgeBand ? false : (p.y > bounds.height - edgeBand ? true : nil)
        return right == nil && top == nil ? nil : (right, top)
    }

    /// What a press here grabs, after the Cutout's rule: nil = moves the bubble.
    private func grab(at p: NSPoint) -> (right: Bool?, top: Bool?)? {
        guard var g = band(at: p) else { return nil }
        if flushBottom(), g.top == false {
            if g.right == nil { return nil }
            g.top = nil
        }
        return g
    }

    // MARK: cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self))
    }

    override func scrollWheel(with event: NSEvent) {
        let unit = event.hasPreciseScrollingDeltas ? 0.0004 : 0.004
        let delta = max(-0.02, min(0.02, Double(event.scrollingDeltaY) * unit))
        let ended = event.phase == .ended || event.phase == .cancelled
        if delta != 0 || ended { onScroll?(delta, ended) }
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true); refreshCursor(for: event) }
    override func mouseMoved(with event: NSEvent) { refreshCursor(for: event) }
    override func mouseExited(with event: NSEvent) { if !resizing { onHover?(false); NSCursor.arrow.set() } }

    private func refreshCursor(for event: NSEvent) {
        guard !resizing else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return }
        guard let grab = grab(at: p) else { NSCursor.openHand.set(); return }
        switch (grab.right, grab.top) {
        case (nil, .some): NSCursor.resizeUpDown.set()
        case (.some, nil): NSCursor.resizeLeftRight.set()
        case let (.some(right), .some(top)):
            if #available(macOS 15.0, *) {
                let position: NSCursor.FrameResizePosition = top ? (right ? .topRight : .topLeft)
                                                                 : (right ? .bottomRight : .bottomLeft)
                NSCursor.frameResize(position: position, directions: .all).set()
            } else {
                NSCursor.resizeLeftRight.set()
            }
        case (nil, nil): NSCursor.openHand.set()
        }
    }

    // MARK: drag

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let grab = grab(at: p) {
            resizing = true
            initialFrame = window.frame
            dragRight = grab.right
            dragTop = grab.top
            onInteraction?(true)
        } else {
            // Interior: our own move, so it can stop at the canvas edge (the
            // system's performDrag cannot be limited).
            moving = true
            NSCursor.closedHand.set()
            initialFrame = window.frame
            grabOffset = window.convertPoint(toScreen: event.locationInWindow)
            onInteraction?(true)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let mouse = window.convertPoint(toScreen: event.locationInWindow)
        if moving {
            var f = initialFrame.offsetBy(dx: mouse.x - grabOffset.x, dy: mouse.y - grabOffset.y)
            if let b = limit() {
                f.origin.x = max(b.minX, min(f.minX, b.maxX - f.width))
                f.origin.y = max(b.minY, min(f.minY, b.maxY - f.height))
            }
            onResize?(f)
            return
        }
        guard resizing else { return }
        let a = max(aspect(), 0.1)
        let f = initialFrame
        var widths: [CGFloat] = []
        if let dragRight { widths.append(max(0, dragRight ? mouse.x - f.minX : f.maxX - mouse.x)) }
        if let dragTop { widths.append(max(0, dragTop ? mouse.y - f.minY : f.maxY - mouse.y) * a) }
        guard var width = widths.max() else { return }
        let range = widthRange()
        width = min(max(width, range.lowerBound), range.upperBound)
        if let b = limit() {
            // The anchored edge stays; the box may not grow past the canvas on
            // the side being dragged (a long way, or a tall one).
            var room = CGFloat.greatestFiniteMagnitude
            if let dragRight { room = min(room, dragRight ? b.maxX - f.minX : f.maxX - b.minX) }
            if let dragTop { room = min(room, (dragTop ? b.maxY - f.minY : f.maxY - b.minY) * a) }
            width = max(min(width, room), 1)
        }
        let height = width / a
        // The edge opposite the grab stays anchored.
        let originX = dragRight == false ? f.maxX - width : f.minX
        let originY = dragTop == false ? f.maxY - height : f.minY
        onResize?(NSRect(x: originX, y: originY, width: width, height: height))
    }

    override func mouseUp(with event: NSEvent) {
        guard resizing || moving else { return }
        resizing = false
        moving = false
        onInteraction?(false)
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            refreshCursor(for: event)
        } else {
            onHover?(false)
            NSCursor.arrow.set()
        }
    }
}
