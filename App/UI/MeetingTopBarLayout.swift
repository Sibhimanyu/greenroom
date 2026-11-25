//
//  MeetingTopBarLayout.swift
//  Greenroom
//
//  Where the Meeting window's top bar puts its right-hand buttons (View, and
//  Smaller to its left). Pure arithmetic, no views: MeetingTopBarView asks this
//  and draws. Foundation and CoreGraphics only, so the test target compiles it.
//
import CoreGraphics
import Foundation

enum MeetingTopBarLayout {

    struct Right: Equatable {
        var view: CGRect
        var shrink: CGRect
        /// Where the title may reach to on the right.
        var rightEdge: CGFloat
    }

    static let buttonHeight: CGFloat = 26
    /// The wash around a button's icon and words.
    static let buttonPadding: CGFloat = 14
    static let gap: CGFloat = 4
    /// From the window's right edge when nothing else is there.
    static let edge: CGFloat = 10

    /// `viewWidth` / `shrinkWidth` are the buttons' fitted widths (no padding).
    /// `trailingReserve` is what the title bar's own trailing accessories take
    /// (the share eye), measured from the window's right edge.
    static func right(width: CGFloat, height: CGFloat, viewWidth: CGFloat, shrinkWidth: CGFloat,
                      shrinkShown: Bool, trailingReserve: CGFloat) -> Right {
        let y = (height - buttonHeight) / 2
        let v = viewWidth + buttonPadding
        // After the buttons comes the eye, in its own place: never under it.
        let end = trailingReserve > 0 ? trailingReserve + gap / 2 : edge
        let view = CGRect(x: width - end - v, y: y, width: v, height: buttonHeight)
        var rightEdge = view.minX - gap
        let s = shrinkWidth + buttonPadding
        let shrink = CGRect(x: rightEdge - s, y: y, width: s, height: buttonHeight)
        if shrinkShown { rightEdge = shrink.minX - gap }
        return Right(view: view, shrink: shrink, rightEdge: rightEdge)
    }
}
