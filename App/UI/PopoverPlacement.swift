//
//  PopoverPlacement.swift
//
//  The placement math of GreenroomPopover, pure (Foundation only) so it is
//  tested. AppKit screen space: origin bottom-left, y grows upward. The popup
//  hangs below `anchor`; its top is fixed, its body is capped to the room
//  between the anchor and `visible` (the screen's visibleFrame, so the Dock
//  and menu bar are excluded), and it is kept inside the screen's sides.
//
import Foundation

enum PopoverPlacement {
    struct Result: Equatable {
        /// The panel's frame, including the transparent shadow pad (sides, bottom).
        var panelFrame: CGRect
        /// The visible body (the scroll view), without the up-notch.
        var bodySize: CGSize
        /// The notch's x, in the body's own space.
        var arrowX: CGFloat
    }

    static func frame(anchor: CGRect, contentSize: CGSize, visible: CGRect,
                      gap: CGFloat = 8, margin: CGFloat = 12, arrowHeight: CGFloat = 7,
                      arrowEdge: CGFloat = 26, shadowPad: CGFloat = 14,
                      minBody: CGFloat = 80) -> Result {
        let top = anchor.minY - gap
        let room = top - visible.minY - margin - arrowHeight
        // The cap is the room; the floor only applies when there is almost none.
        let maxBody = max(minBody, room)
        let ready = contentSize.width > 0 && contentSize.height > 0
        let width = min(ready ? contentSize.width : 320, visible.width - 2 * margin)
        let body = min(ready ? contentSize.height : 200, maxBody)
        let minX = visible.minX + margin
        let x = min(max(anchor.midX - width / 2, minX), max(minX, visible.maxX - margin - width))
        let arrowX = min(max(anchor.midX - x, arrowEdge), max(arrowEdge, width - arrowEdge))
        let frame = CGRect(x: x - shadowPad, y: top - body - arrowHeight - shadowPad,
                           width: width + 2 * shadowPad, height: body + arrowHeight + shadowPad)
        return Result(panelFrame: frame, bodySize: CGSize(width: width, height: body), arrowX: arrowX)
    }
}
