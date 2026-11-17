import CoreGraphics

enum OnboardingPlacement {
    /// Where the guide's frame goes: centred on `anchor` (the main window), or
    /// on the visible screen when there is none, then clamped inside it.
    static func frame(size: CGSize, anchor: CGRect?, visible: CGRect) -> CGRect {
        let centre = anchor.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: visible.midX, y: visible.midY)
        var origin = CGPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2)
        let maxX = visible.maxX - size.width, maxY = visible.maxY - size.height
        origin.x = max(visible.minX, min(origin.x, maxX))
        origin.y = max(visible.minY, min(origin.y, maxY))
        return CGRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
    }
}
