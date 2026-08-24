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
    /// The macOS "Presenter Overlay (Large)" look, rebuilt inside the OBS
    /// composite (Apple's own can't be triggered programmatically, is
    /// Apple-silicon-only, and wouldn't ride our virtual-camera pipeline):
    /// the shared screen shrinks into a rounded inset panel and the person
    /// stands keyed at full height in front of it. Same green-screen
    /// requirement as Cutout.
    case presenterLarge

    var id: String { rawValue }

    var label: String {
        switch self {
        case .square: return "Square"
        case .circle: return "Circle"
        case .roundedRectangle: return "Rounded"
        case .cutout: return "Cutout"
        case .presenterLarge: return "Presenter"
        }
    }

    /// These key the background out instead of masking a bubble shape.
    var usesChromaKey: Bool { self == .cutout || self == .presenterLarge }

    /// Presenter mode reshapes the whole scene (screen panel + big keyed
    /// person), not just the webcam item.
    var isPresenterStyle: Bool { self == .presenterLarge }

    /// Whether the camera is centre-cropped to a square before the shape mask.
    ///
    /// Only the circle. A circle mask stretched over a 16:9 frame is an
    /// ellipse, and a 16:9 frame inside a square box letterboxes. The
    /// rectangular shapes have neither problem and would only lose 43.75% of
    /// the camera's width for nothing.
    var cropsToSquare: Bool { self == .circle }
}
