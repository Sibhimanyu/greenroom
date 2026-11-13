// Ported from Recorditor (ZRecorditor @7210322, native/MacRecorder/Editor/ArrowDragLayer.swift).
import AppKit
import SwiftUI

/// AppKit interaction layer for arrow annotations. SwiftUI gestures proved
/// unreliable here (drag values arrived in the wrong space or with a
/// flipped vertical axis depending on attachment), so arrows use raw mouse
/// events instead: the view is flipped (top-left origin, the overlay's own
/// space), claims only points near an arrow, and reports absolute tail/tip
/// positions — grab-the-tip means the tip IS the pointer, any angle.
final class ArrowDragNSView: NSView {
    struct Item {
        let id: UUID
        var tail: CGPoint
        var tip: CGPoint
        /// The floating toolbar's rect for a selected arrow — clicks there
        /// belong to the SwiftUI buttons underneath this layer.
        var exclusion: CGRect
    }

    enum Mode {
        case move, tail, tip
    }

    var items: [Item] = []
    var onSelect: ((UUID) -> Void)?
    /// (id, new tail, new tip) in this view's top-left coordinates.
    var onDrag: ((UUID, CGPoint, CGPoint) -> Void)?

    private let endpointRadius: CGFloat = 24
    private let lineRadius: CGFloat = 14
    private var active: (id: UUID, mode: Mode, baseTail: CGPoint, baseTip: CGPoint, down: CGPoint)?

    override var isFlipped: Bool { true }   // top-left origin, like the overlay
    override var mouseDownCanMoveWindow: Bool { false }

    func pick(at p: CGPoint) -> (Item, Mode)? {
        for item in items {
            if item.exclusion.contains(p) { continue }
            let toTip = hypot(p.x - item.tip.x, p.y - item.tip.y)
            let toTail = hypot(p.x - item.tail.x, p.y - item.tail.y)
            if min(toTip, toTail) <= endpointRadius {
                return (item, toTip <= toTail ? .tip : .tail)
            }
            if Self.distanceToSegment(p, item.tail, item.tip) <= lineRadius {
                return (item, .move)
            }
        }
        return nil
    }

    static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let lengthSquared = abx * abx + aby * aby
        guard lengthSquared > 0.001 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * abx + (p.y - a.y) * aby) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * abx), p.y - (a.y + t * aby))
    }

    /// Claim only points on/near an arrow — everything else falls through
    /// to the SwiftUI overlay (toolbar, text fields, blur boxes, deselect).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return pick(at: local) != nil ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let (item, mode) = pick(at: p) else { return }
        onSelect?(item.id)
        active = (item.id, mode, item.tail, item.tip, p)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let active else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dx = p.x - active.down.x
        let dy = p.y - active.down.y
        var tail = active.baseTail
        var tip = active.baseTip
        switch active.mode {
        case .move:
            tail.x += dx; tail.y += dy
            tip.x += dx; tip.y += dy
        case .tail:
            tail.x += dx; tail.y += dy
        case .tip:
            tip.x += dx; tip.y += dy
        }
        onDrag?(active.id, tail, tip)
    }

    override func mouseUp(with event: NSEvent) {
        active = nil
    }
}

/// SwiftUI wrapper: feeds the layer the visible arrows' screen positions
/// and routes updates back into the view model.
struct ArrowDragLayer: NSViewRepresentable {
    var items: [ArrowDragNSView.Item]
    var onSelect: (UUID) -> Void
    var onDrag: (UUID, CGPoint, CGPoint) -> Void

    func makeNSView(context: Context) -> ArrowDragNSView {
        let view = ArrowDragNSView()
        view.items = items
        view.onSelect = onSelect
        view.onDrag = onDrag
        return view
    }

    func updateNSView(_ nsView: ArrowDragNSView, context: Context) {
        nsView.items = items
        nsView.onSelect = onSelect
        nsView.onDrag = onDrag
    }
}
