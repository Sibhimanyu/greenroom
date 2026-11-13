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
}
