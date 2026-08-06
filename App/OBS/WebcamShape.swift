//
//  WebcamShape.swift
//  Greenroom
//
//  The webcam bubble's outline. Square needs no extra work (just the
//  existing bounding-box crop) - circle and rounded rectangle need an actual
//  alpha mask, since OBS's scene-item transform can only do rectangles.
//
import Foundation

enum WebcamShape: String, CaseIterable, Identifiable {
    case square, circle, roundedRectangle
    /// Not a shape at all: no mask, chroma key ON, so the person appears
    /// as a background-free cutout standing over the shared screen.
    /// Requires an actual green screen behind them.
    case cutout

    var id: String { rawValue }

    var label: String {
        switch self {
        case .square: return "Square"
        case .circle: return "Circle"
        case .roundedRectangle: return "Rounded"
        case .cutout: return "Cutout"
        }
    }

    /// Cutout keys the background out instead of masking a bubble shape.
    var usesChromaKey: Bool { self == .cutout }
}
