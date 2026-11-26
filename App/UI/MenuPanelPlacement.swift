//
//  MenuPanelPlacement.swift
//  Greenroom
//
//  Where a MeetingMenuPanel goes, pure (Foundation only) so it is tested. AppKit screen space:
//  origin bottom-left, y up. `area` is the screen's visibleFrame (menu bar and Dock out).
//
//  The whole menu is always on the screen, last row included (the camera menu's Stop video is
//  its last row): on its side of the control (above for the bar, below for the menu bar) when it
//  fits, else the other side, else shifted onto the screen over the control. Only a menu taller
//  than the whole visible frame is cut to that height, and then it scrolls.
//
import Foundation

struct MenuPanelPlacement: Equatable {
    /// The panel's frame in screen space.
    var frame: CGRect
    /// The menu is taller than the screen: the frame is cut to it and the rows scroll.
    var scrolls: Bool

    /// Between the control and the menu.
    static let gap: CGFloat = 4

    /// `size` is the menu's whole size; `anchor` the control (a zero-size point for a right-click);
    /// `below` the side it prefers.
    static func place(size: CGSize, anchor: CGRect, area: CGRect, below: Bool) -> MenuPanelPlacement {
        let height = min(size.height, area.height)
        let above = anchor.maxY + gap
        let under = anchor.minY - gap - height
        let fitsAbove = above + height <= area.maxY
        let fitsUnder = under >= area.minY
        let y: CGFloat
        if below {
            y = fitsUnder || !fitsAbove ? under : above
        } else {
            y = fitsAbove || !fitsUnder ? above : under
        }
        return fit(origin: CGPoint(x: anchor.minX, y: y), size: CGSize(width: size.width, height: height), area: area,
                   scrolls: height < size.height)
    }

    /// `origin` moved just enough to put the whole frame on `area` (height cut to it at most).
    static func fit(origin: CGPoint, size: CGSize, area: CGRect, scrolls: Bool = false) -> MenuPanelPlacement {
        let height = min(size.height, area.height)
        let x = min(max(origin.x, area.minX), max(area.minX, area.maxX - size.width))
        let y = min(max(origin.y, area.minY), area.maxY - height)
        return MenuPanelPlacement(frame: CGRect(x: x, y: y, width: size.width, height: height),
                                  scrolls: scrolls || height < size.height)
    }
}
