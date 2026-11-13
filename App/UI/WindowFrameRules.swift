import AppKit

/// The window-frame math for page changes, kept free of NSWindow so it can be
/// tested. All rects are in screen coordinates (origin bottom-left).
enum WindowFrameRules {
    /// The page's frame: it grows down and right from Home's TOP-LEFT corner
    /// (DESIGN.md 2026-09-04, anchored top edge), then sits inside the
    /// visible frame of the screen Home is on. Shifted up only by the
    /// overflow at the bottom, left only by the overflow at the right.
    static func pageFrame(from home: NSRect, size: CGSize, visibleFrames: [NSRect]) -> NSRect {
        anchored(left: home.minX, top: home.maxY, size: size, in: screen(of: home, in: visibleFrames))
    }

    /// The visible frame holding most of `frame`; nil when there are none.
    static func screen(of frame: NSRect, in visibleFrames: [NSRect]) -> NSRect? {
        visibleFrames.max { area($0.intersection(frame)) < area($1.intersection(frame)) }
    }

    private static func area(_ r: NSRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

    static func anchored(left: CGFloat, top: CGFloat, size: CGSize, in visible: NSRect?) -> NSRect {
        clamp(NSRect(x: left, y: top - size.height, width: size.width, height: size.height), in: visible)
    }

    /// Anchors the current top-left, for a resize in place.
    static func topLeftAnchored(on current: NSRect, size: CGSize, in visible: NSRect?) -> NSRect {
        anchored(left: current.minX, top: current.maxY, size: size, in: visible)
    }

    static func clamp(_ frame: NSRect, in visible: NSRect?) -> NSRect {
        guard let visible else { return frame }
        var f = frame
        if f.maxX > visible.maxX { f.origin.x = visible.maxX - f.width }
        if f.minX < visible.minX { f.origin.x = visible.minX }
        if f.minY < visible.minY { f.origin.y = visible.minY }
        // Taller than the screen: the top stays on it.
        if f.maxY > visible.maxY { f.origin.y = visible.maxY - f.height }
        return f
    }

    /// Back to Home. `remembered` is the frame Home had when the page opened.
    /// - Unmoved on the page, and still on a screen: the remembered origin
    ///   (left edge and top edge), at the new size.
    /// - Moved on the page, or the screen changed: Home's size from the
    ///   window's current top-left.
    static func returningHome(remembered: NSRect?, size: CGSize, current: NSRect,
                              movedOnPage: Bool, visibleFrames: [NSRect],
                              currentVisible: NSRect?) -> NSRect {
        if !movedOnPage, let remembered,
           let screen = visibleFrames.first(where: { $0.insetBy(dx: -1, dy: -1).contains(remembered) }) {
            return clamp(NSRect(x: remembered.minX, y: remembered.maxY - size.height,
                                width: size.width, height: size.height), in: screen)
        }
        return topLeftAnchored(on: current, size: size, in: currentVisible)
    }

    /// Whether the user dragged the window since the page settled.
    static func moved(from settled: NSRect?, to current: NSRect, tolerance: CGFloat = 2) -> Bool {
        guard let settled else { return false }
        return abs(settled.minX - current.minX) > tolerance || abs(settled.maxY - current.maxY) > tolerance
    }
}
