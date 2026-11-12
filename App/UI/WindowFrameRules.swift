import AppKit

/// The window-frame math for page changes, kept free of NSWindow so it can be
/// tested. All rects are in screen coordinates (origin bottom-left).
enum WindowFrameRules {
    /// A frame of `size` that keeps the current MIDDLE (x) and TOP edge (y),
    /// then sits inside `visible`: shifted right if it starts left of the
    /// screen, left if it runs past the right, up only if the bottom would
    /// leave the screen.
    static func centred(on current: NSRect, size: CGSize, in visible: NSRect?) -> NSRect {
        anchored(midX: current.midX, top: current.maxY, size: size, in: visible)
    }

    static func anchored(midX: CGFloat, top: CGFloat, size: CGSize, in visible: NSRect?) -> NSRect {
        clamp(NSRect(x: midX - size.width / 2, y: top - size.height,
                     width: size.width, height: size.height), in: visible)
    }

    static func clamp(_ frame: NSRect, in visible: NSRect?) -> NSRect {
        guard let visible else { return frame }
        var f = frame
        if f.maxX > visible.maxX { f.origin.x = visible.maxX - f.width }
        if f.minX < visible.minX { f.origin.x = visible.minX }
        if f.minY < visible.minY { f.origin.y = visible.minY }
        return f
    }

    /// Back to Home. `remembered` is the frame Home had when the page opened.
    /// - Unmoved on the page, and still on a screen: the remembered origin
    ///   (left edge and top edge), at the new size.
    /// - Moved on the page, or the screen changed: Home's size around the
    ///   window's current middle, top edge kept.
    static func returningHome(remembered: NSRect?, size: CGSize, current: NSRect,
                              movedOnPage: Bool, visibleFrames: [NSRect],
                              currentVisible: NSRect?) -> NSRect {
        if !movedOnPage, let remembered,
           let screen = visibleFrames.first(where: { $0.insetBy(dx: -1, dy: -1).contains(remembered) }) {
            return clamp(NSRect(x: remembered.minX, y: remembered.maxY - size.height,
                                width: size.width, height: size.height), in: screen)
        }
        return centred(on: current, size: size, in: currentVisible)
    }

    /// Whether the user dragged the window since the page settled.
    static func moved(from settled: NSRect?, to current: NSRect, tolerance: CGFloat = 2) -> Bool {
        guard let settled else { return false }
        return abs(settled.midX - current.midX) > tolerance || abs(settled.maxY - current.maxY) > tolerance
    }
}
