//
//  SegmentedMath.swift
//
//  Sizing and index maths for GreenroomSegmented, kept free of SwiftUI so
//  the test target can compile it.
//
import CoreGraphics

/// Pure sizing and index maths, kept apart so tests can reach it.
enum SegmentedMath {
    /// Every segment is as wide as the widest label plus padding.
    static func segmentWidth(labelWidths: [CGFloat], padding: CGFloat) -> CGFloat {
        (labelWidths.max() ?? 0) + padding * 2
    }

    /// The index one step from `current`, clamped to the ends.
    static func step(from current: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(current + delta, 0), count - 1)
    }

    /// The one gap between the toolbar capsule and the selection pill, on all
    /// four sides.
    static let inset: CGFloat = 3
    /// Selection pill height in the toolbar: 28 + 2 x 3 = 34pt capsule, the
    /// height of a macOS 26 toolbar button such as Sessions.
    static let toolbarPillHeight: CGFloat = 28

    static func capsuleHeight(pillHeight: CGFloat, inset: CGFloat = inset) -> CGFloat { pillHeight + 2 * inset }

    /// The pill that sits `inset` inside a capsule of this size.
    static func pillSize(capsule: CGSize, inset: CGFloat = inset) -> CGSize {
        CGSize(width: max(capsule.width - 2 * inset, 0), height: max(capsule.height - 2 * inset, 0))
    }

    /// Concentric curves: the pill's radius is the capsule's minus the inset.
    static func pillRadius(capsuleRadius: CGFloat, inset: CGFloat = inset) -> CGFloat { max(capsuleRadius - inset, 0) }
}
