//
//  StageConfiguration.swift
//  Greenroom
//
//  Everything the compositor is told, beside the layout (StageLayout.swift).
//
import CoreGraphics
import Foundation

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
    /// Also capture the sound of what is shared (the Mac's sound), for the
    /// recorder to mix in. Changing it restarts the screen capture.
    var captureSystemAudio = false

    /// The share target has the last word on content, and there is always
    /// something to show .
    var normalizedLayout: StageLayout {
        var l = layout
        if share.sharesNothing { l.showsContent = false }
        if !l.showsContent { l.showsCamera = true }
        return l
    }
}
