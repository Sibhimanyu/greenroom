//
//  PopoverPlacement.swift
//
//  The placement math of GreenroomPopover, pure (Foundation only) so it is
//  tested. AppKit screen space: origin bottom-left, y grows upward. The popup
//  hangs `gap` below `anchor`; its top is fixed, its height is capped to the
//  room between the anchor and `visible` (the screen's visibleFrame, so the
//  Dock and menu bar are excluded), and it is kept inside the screen's sides.
//  The panel frame IS the visible rounded body: no notch, no transparent
//  margin (the shadow is the window's own, drawn outside the frame).
//
import Foundation

enum PopoverPlacement {
    struct Result: Equatable {
        /// The panel's frame, which is exactly the visible body.
        var panelFrame: CGRect
        var bodySize: CGSize { panelFrame.size }
    }

    /// `contentSize` is the content's ideal size including the scroll insets.
    static func frame(anchor: CGRect, contentSize: CGSize, visible: CGRect,
                      gap: CGFloat = 8, margin: CGFloat = 12, minBody: CGFloat = 80) -> Result {
        let top = anchor.minY - gap
        let room = top - visible.minY - margin
        // The cap is the room; the floor only applies when there is almost none.
        let maxBody = max(minBody, room)
        let ready = contentSize.width > 0 && contentSize.height > 0
        let width = min(ready ? contentSize.width : 320, visible.width - 2 * margin)
        let body = min(ready ? contentSize.height : 200, maxBody)
        let minX = visible.minX + margin
        let x = min(max(anchor.midX - width / 2, minX), max(minX, visible.maxX - margin - width))
        return Result(panelFrame: CGRect(x: x, y: top - body, width: width, height: body))
    }
}
