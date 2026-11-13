//
//  StageLayout.swift
//  Greenroom
//
//  What the compositor is told to draw, with the shipped defaults.
//
import CoreGraphics
import Foundation

struct StageLayout: Equatable {
    var widthFraction: Double = 0.24
    var rightInset: Double = 0.045
    var bottomInset: Double = 0.06
    var cutoutHeightFraction: Double = 0.5
    var cutoutRightInset: Double = 0.02
    var shape: WebcamShape = .circle
    /// Shared content on, camera on. Both on is shared content with you in it. Content off is a talking head; camera off is the shared content alone.
    var showsContent = true
    var showsCamera = true

    /// With nothing shared the camera IS the picture, so bubble shapes give
    /// way to the full frame; Cutout and Presenter keep their removal.
    var cameraShape: WebcamShape {
        showsContent || shape.usesChromaKey ? shape : .square
    }
}

/// Everything the compositor needs to know that can change mid-class.
struct StageConfiguration: Equatable {
    var layout = StageLayout()
    var share = ShareTarget()
    /// `screenCaptureDisplayUUID`. Empty means the main display.
    var displayUUID = ""
    var backgroundRemoval: BackgroundRemoval = .automatic
    /// Blur or a picture behind you in the bubble shapes. Ignored by Cutout
    /// and Presenter, which remove the background instead.
    var cameraBackground: CameraBackground = .normal
    /// Which picture, for `.image`: a `CameraBackgroundPreset` raw value or
    /// `custom-<stamp>` (see CameraBackgroundLibrary).
    var cameraBackgroundImage = CameraBackgroundPreset.defaultChoice
    /// Camera uniqueIDs in cut order. Slot = index. All are opened at once.
    var cameraUIDs: [String] = []

    /// The share target has the last word on content, and there is always
    /// something to show .
    var normalizedLayout: StageLayout {
        var l = layout
        if share.kind == .nothing { l.showsContent = false }
        if !l.showsContent { l.showsCamera = true }
        return l
    }
}
