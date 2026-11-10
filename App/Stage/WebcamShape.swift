//
//  WebcamShape.swift
//  Greenroom
//
//  The webcam bubble's outline. Square needs no extra work (just the
//  existing bounding-box crop) - circle and rounded rectangle need an actual
//  alpha mask, since a plain crop can only do rectangles.
//
import AppKit
import Foundation

enum WebcamShape: String, CaseIterable, Identifiable {
    case square, circle, roundedRectangle
    /// Not a shape at all: no mask, chroma key ON, so the person appears
    /// as a background-free cutout standing over the shared screen.
    /// Requires an actual green screen behind them.
    case cutout
    /// The macOS "Presenter Overlay (Large)" look, rebuilt in
    /// Greenroom's own picture (Apple's own can't be triggered programmatically, is
    /// Apple-silicon-only, and wouldn't be what the meeting receives):
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

/// The live composite, for the Webcam tab's picture and nothing else. See
/// `CoordinatorController.shapePreview` for why it is not on the controller.
@MainActor
final class ShapePreviewFeed: ObservableObject {
    @Published var frame: NSImage?
}

/// How Cutout and Presenter take your background away.
enum BackgroundRemoval: String, CaseIterable, Identifiable, Codable {
    /// Greenroom finds you in the picture and removes the rest. No green
    /// screen. See CutoutPublisher.
    case automatic
    /// Greenroom keys out a real green screen behind you.
    case greenScreen

    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "Automatically"
        case .greenScreen: return "With a green screen"
        }
    }
}
