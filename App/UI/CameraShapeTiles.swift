//
//  CameraShapeTiles.swift
//
//  The camera's shape as one row of choice tiles (Rounded, Circle, Square, Cutout, Presenter), shared by
//  Home's Look pop-out and the camera inspector in Layouts (R33). The tile is HomeTileChoiceRow's, so
//  both places look and answer the keys the same way. The caller says what a pick does.
//
import SwiftUI

struct CameraShapeTiles: View {
    let selected: WebcamShape
    var autofocus = false
    let pick: (WebcamShape) -> Void

    /// The tile's glyph for a shape (also Home's Look dock tile).
    static func symbol(for shape: WebcamShape) -> String {
        switch shape {
        case .square: return "square"
        case .circle: return "circle"
        case .roundedRectangle: return "app"
        case .cutout, .presenterLarge: return "person.crop.rectangle"
        }
    }

    var body: some View {
        HomeTileChoiceRow(
            choices: WebcamShape.allCases.map {
                HomeTileChoice(id: $0.id, title: $0.label, symbol: Self.symbol(for: $0), selected: selected == $0)
            },
            autofocus: autofocus
        ) { pick(WebcamShape.allCases[$0]) }
    }
}
