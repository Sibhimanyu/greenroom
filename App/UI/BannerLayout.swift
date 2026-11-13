//
//  BannerLayout.swift
//  Greenroom
//
//  Frame math for the one message panel (WindowBanner.swift). Pure Foundation,
//  so GreenroomTests compiles it directly.
//
import Foundation
import CoreGraphics

/// Where the stack of messages sits. Pure, so the position is unit-tested
/// rather than eyeballed.
enum BannerLayout {
    /// Gap from the screen's right edge and from the menu bar.
    static let inset: CGFloat = 12
    /// Gap between stacked messages.
    static let gap: CGFloat = 8
    /// Every card is this wide, so the panel has no empty, click-blocking corners.
    static let cardWidth: CGFloat = 380
    /// Room around the cards inside the panel for their shadow.
    static let shadowPad: CGFloat = 14

    /// The cards' frames (AppKit coordinates, bottom-left origin), first card
    /// at the top, each one `gap` below the last, all `inset` from the right
    /// edge and from the top of `visible` (the screen minus menu bar and Dock).
    static func cardFrames(sizes: [CGSize], in visible: CGRect) -> [CGRect] {
        var top = visible.maxY - inset
        return sizes.map { size in
            let frame = CGRect(x: visible.maxX - inset - size.width, y: top - size.height,
                               width: size.width, height: size.height)
            top -= size.height + gap
            return frame
        }
    }

    /// The panel's frame for a stack of total size `stack` (cards plus gaps,
    /// without the shadow padding): the cards' bounds grown by the shadow room.
    static func panelFrame(stack: CGSize, in visible: CGRect) -> CGRect {
        let card = cardFrames(sizes: [stack], in: visible)[0]
        return card.insetBy(dx: -shadowPad, dy: -shadowPad)
    }
}
