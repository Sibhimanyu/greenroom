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
    /// Only me: the camera is open for the owner's bubble but is not drawn into the picture
    /// (`Visibility.cameraMirrorOnly`). Never set with `showsCamera`.
    var mirrorsCamera = false

    /// With nothing shared the camera IS the picture, so bubble shapes give
    /// way to the full frame; Cutout and Presenter keep their removal.
    var cameraShape: WebcamShape {
        showsContent || shape.usesChromaKey ? shape : .square
    }

    /// The camera must be open: drawn for everyone, or mirrored for the owner.
    var opensCamera: Bool { showsCamera || mirrorsCamera }
}

extension StageLayout {
    var presenceBox: PresenceBox {
        PresenceBox(widthFraction: widthFraction, rightInset: rightInset, bottomInset: bottomInset,
                    cutoutHeightFraction: cutoutHeightFraction, cutoutRightInset: cutoutRightInset,
                    isCutout: cameraShape == .cutout)
    }

    mutating func apply(_ box: PresenceBox) {
        widthFraction = box.widthFraction
        rightInset = box.rightInset
        bottomInset = box.bottomInset
        cutoutHeightFraction = box.cutoutHeightFraction
        cutoutRightInset = box.cutoutRightInset
    }

    /// The look has a box the presenter can move. Presenter and the full-frame
    /// talking head have a fixed picture, so nothing is placed.
    var isPresencePlaceable: Bool { showsContent && opensCamera && cameraShape != .presenterLarge }
}
