//
//  StageLayout.swift
//  Greenroom
//
//  What the compositor is told to draw. The numbers and their defaults are
//  the ones `GreenroomScene.BubbleLayout` carries (App/OBS/GreenroomScene.swift
//  :222), copied rather than shared so that Stage has no dependency on the OBS
//  code it is replacing. `StageLayout+OBS.swift` converts from the old type
//  until the OBS code is deleted.
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
    /// Shared content on, camera on. Same meaning as in GreenroomScene.
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
    /// Camera uniqueIDs in cut order. Slot = index. All are opened at once.
    var cameraUIDs: [String] = []

    /// The share target has the last word on content, and there is always
    /// something to show (GreenroomScene.ensureConfigured, :289-293).
    var normalizedLayout: StageLayout {
        var l = layout
        if share.kind == .nothing { l.showsContent = false }
        if !l.showsContent { l.showsCamera = true }
        return l
    }
}
