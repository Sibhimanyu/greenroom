//
//  ZoomMarketplaceWindowPlacement.swift
//  Greenroom
//
//  Where the Zoom window and the setup guide sit on one screen (spec R1).
//  Frames are in screen coordinates (origin bottom-left). Pure: no NSWindow.
//
import CoreGraphics

enum ZoomMarketplaceWindowPlacement {
    struct Frames: Equatable { var guide: CGRect; var zoom: CGRect }

    /// Narrowest Zoom window worth keeping beside a guide that stays where it is.
    static let minWidth: CGFloat = 640
    /// Narrowest it may be squeezed to when the guide has to move.
    static let floorWidth: CGFloat = 480
    static let maxWidth: CGFloat = 1200
    static let aloneHeight: CGFloat = 850

    /// Room on a side of the guide: Zoom goes there and the guide stays. Neither: the guide moves
    /// to the left edge (same size) and Zoom takes the right.
    static func frames(screen: CGRect, guide: CGRect) -> Frames {
        var g = guide
        g.origin.x = min(max(g.minX, screen.minX), max(screen.minX, screen.maxX - g.width))
        g.origin.y = min(max(g.minY, screen.minY), max(screen.minY, screen.maxY - g.height))
        func zoom(x: CGFloat, width: CGFloat) -> CGRect { CGRect(x: x, y: screen.minY, width: width, height: screen.height) }
        let right = screen.maxX - g.maxX
        let left = g.minX - screen.minX
        if right >= minWidth {
            return Frames(guide: g, zoom: zoom(x: g.maxX, width: min(right, maxWidth)))
        }
        if left >= minWidth {
            let w = min(left, maxWidth)
            return Frames(guide: g, zoom: zoom(x: g.minX - w, width: w))
        }
        g.origin.x = screen.minX
        let w = min(max(screen.width - g.width, floorWidth), maxWidth)
        return Frames(guide: g, zoom: zoom(x: min(g.maxX, screen.maxX - w), width: w))
    }

    /// With no guide on screen: centred, at the usual size or the screen's if smaller.
    static func alone(screen: CGRect) -> CGRect {
        let w = min(maxWidth, screen.width), h = min(aloneHeight, screen.height)
        return CGRect(x: (screen.midX - w / 2).rounded(), y: (screen.midY - h / 2).rounded(), width: w, height: h)
    }
}
