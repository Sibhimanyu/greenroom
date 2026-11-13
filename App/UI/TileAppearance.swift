//
//  TileAppearance.swift
//
//  The numbers behind `GreenroomTileStyle` (Tiles.swift), kept free of SwiftUI
//  so they can be unit-tested: what a tile looks like at rest, under the
//  pointer, pressed, or chosen. DESIGN.md, "Cards and tiles".
//
import CoreGraphics

enum GreenroomTileRole: Equatable {
    /// A grid of things to open (Sessions): no box at rest.
    case browse
    /// One of several pictures to pick between (Settings, onboarding).
    case choice(selected: Bool)
}

/// How strong the tile's backdrop fill is. Mapped to `.quinary` / `.quaternary`
/// by the style.
enum TileFill: Equatable {
    case none
    case quinary
    case quaternary
}

struct TileAppearance: Equatable {
    var fill: TileFill
    /// Vertical offset; negative lifts the tile.
    var offsetY: CGFloat
    var scale: CGFloat
    var shadowOpacity: Double
    /// The 2pt accent ring and the checkmark badge: a chosen choice tile only.
    var showsSelectionRing: Bool

    static func resolve(role: GreenroomTileRole, hovering: Bool, pressed: Bool, reduceMotion: Bool) -> TileAppearance {
        let selected: Bool
        if case .choice(let s) = role { selected = s } else { selected = false }
        let restFill: TileFill
        switch role {
        case .browse: restFill = .none
        case .choice: restFill = .quinary
        }
        // Hover: one step stronger. A browse tile has no box, so it gains one.
        let fill: TileFill = (hovering || pressed) ? (restFill == .none ? .quinary : .quaternary) : restFill
        // Reduce Motion: the fill changes, nothing moves.
        let lifts = hovering && !pressed && !reduceMotion
        return TileAppearance(
            fill: fill,
            offsetY: lifts ? -1 : 0,
            scale: (pressed && !reduceMotion) ? 0.98 : 1,
            shadowOpacity: lifts ? 0.12 : 0,
            showsSelectionRing: selected)
    }
}
