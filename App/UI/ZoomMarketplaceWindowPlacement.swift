//
//  ZoomMarketplaceWindowPlacement.swift
//  Greenroom
//
//  Where the Zoom window opens (spec R1): large and centred on the setup
//  guide's screen, about 85% of its visible frame, capped at 1400x1000 and
//  never under 900x700 (unless the screen itself is smaller). The setup guide
//  is not moved or resized. Frames are in screen coordinates. Pure: no NSWindow.
//
import CoreGraphics

enum ZoomMarketplaceWindowPlacement {
    static let share: CGFloat = 0.85
    static let maxSize = CGSize(width: 1400, height: 1000)
    static let minSize = CGSize(width: 900, height: 700)

    static func frame(screen: CGRect) -> CGRect {
        func side(_ visible: CGFloat, _ cap: CGFloat, _ floor: CGFloat) -> CGFloat {
            min(visible, max(floor, min(cap, (visible * share).rounded())))
        }
        let w = side(screen.width, maxSize.width, minSize.width)
        let h = side(screen.height, maxSize.height, minSize.height)
        return CGRect(x: (screen.midX - w / 2).rounded(), y: (screen.midY - h / 2).rounded(), width: w, height: h)
    }
}
