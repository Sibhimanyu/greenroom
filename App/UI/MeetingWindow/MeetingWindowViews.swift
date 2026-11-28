//
//  MeetingWindowViews.swift
//  Greenroom
//
//  Small views the meeting window is built from: first-click controls, the split divider, the frosted bar and the toolbar foot.
//
import AppKit
import SwiftUI
import Combine

/// Both of these live in a window that is almost never key. A stock control in a
/// non-key window discards its first press as "make me key", so every click
/// would need doing twice. See ClosureButton for the same lesson.
final class FirstClickSegmented: NSSegmentedControl {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The grab strip between a share and the view beside it. Drags report the
/// pointer's x in the parent's coordinates; a double click puts the split back.
@MainActor
final class MeetingSplitDivider: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    var onReset: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var dragging = false { didSet { needsDisplay = true } }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onReset?(); return }
        dragging = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging, let parent = superview else { return }
        onDrag?(parent.convert(event.locationInWindow, from: nil).x)
    }
    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onEnd?()
    }
    override func draw(_ dirtyRect: NSRect) {
        let handle = NSRect(x: bounds.midX - 2, y: bounds.midY - 18, width: 4, height: 36)
        NSColor.white.withAlphaComponent(hovering || dragging ? 0.7 : 0.28).setFill()
        NSBezierPath(roundedRect: handle, xRadius: 2, yRadius: 2).fill()
    }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}


/// System material, not a hardcoded grey: DESIGN.md reserves the brand palette
/// for content and asks chrome to follow the platform.
@MainActor
final class BarView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
    }
    required init?(coder: NSCoder) { nil }
}

/// The toolbar's backing. Clear, so the Meeting window's frost (WindowFrost,
/// which also turns solid while the class can see the window) is what shows
/// behind it, as behind the rest of the window. A blur sits under it only when
/// asked, for the slot form's toolbar over video.
@MainActor
final class ToolbarFootView: NSView {
    private let blur = BarView()
    var showsBlur = false { didSet { blur.isHidden = !showsBlur } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        blur.frame = bounds
        blur.autoresizingMask = [.width, .height]
        blur.isHidden = true
        addSubview(blur)
    }
    required init?(coder: NSCoder) { nil }
}
