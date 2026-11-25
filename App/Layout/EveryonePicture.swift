//
//  EveryonePicture.swift
//  Greenroom
//
//  What Preview: Everyone draws, in output pixels (1920x1080, top-left origin): the shared content's
//  rect, the pieces in it and the camera. Pure; the numbers come from `StageFrame` and
//  `PresenceGeometry`, the same ones the compositor draws with.
//
import CoreGraphics
import Foundation

struct EveryonePicture: Equatable {
    struct Tile: Equatable { var id: UUID; var rect: CGRect }
    struct Camera { var box: PresenceBox; var shape: WebcamShape; var everyoneSees = true }

    var content: CGRect?
    var whiteboardCard = false
    var tiles: [Tile] = []
    var camera: CGRect?

    /// `displaySize` is the shared display in points; a piece's unit rect is a fraction of it.
    static func make(share: Visibility.Target, pieces: [LayoutPiece], displaySize: CGSize, camera: Camera?) -> EveryonePicture {
        let presenter = StageFrame.usesPresenterPanel(showsCamera: camera?.everyoneSees ?? false, shape: camera?.shape ?? .circle)
        let kind: StageFrame.ShareKind
        switch share {
        case .wholeScreen: kind = .wholeScreen
        case .window: kind = .window
        case .whiteboard: kind = .whiteboard
        case .justMe: kind = .justMe
        }
        // The piece a One window share shows: the chosen window's.
        let chosen: LayoutPiece? = {
            guard case let .window(id) = share else { return nil }
            return pieces.first { $0.kind.app?.bundleID == id }
        }()
        let sourceAspect: CGFloat
        switch kind {
        case .wholeScreen: sourceAspect = displaySize.width / max(displaySize.height, 1)
        case .whiteboard: sourceAspect = 16.0 / 9
        case .window:
            sourceAspect = chosen.map { p in
                (p.rect.w * displaySize.width) / max(p.rect.h * displaySize.height, 1)
            } ?? displaySize.width / max(displaySize.height, 1)
        case .justMe: sourceAspect = 1
        }
        var picture = EveryonePicture()
        picture.content = StageFrame.contentRect(shareKind: kind, sourceAspect: sourceAspect, presenter: presenter)
        picture.whiteboardCard = kind == .whiteboard
        if let c = picture.content {
            switch kind {
            case .wholeScreen:
                picture.tiles = pieces.filter { Visibility.everyoneSees(piece: $0, target: share).isOn }.map {
                    Tile(id: $0.id, rect: CGRect(x: c.minX + $0.rect.x * c.width, y: c.minY + $0.rect.y * c.height,
                                                 width: $0.rect.w * c.width, height: $0.rect.h * c.height))
                }
            case .window:
                if let chosen { picture.tiles = [Tile(id: chosen.id, rect: c)] }
            case .whiteboard, .justMe: break
            }
        }
        if let camera, camera.everyoneSees {
            // With nothing shared a bubble shape gives way to the full frame; StageFrame owns that fallback.
            let hasContent = kind != .justMe
            let shape = StageFrame.cameraShape(camera.shape, showsContent: hasContent)
            var box = camera.box
            box.isCutout = shape == .cutout && hasContent
            let aspect = shape.cropsToSquare ? 1 : 16.0 / 9.0
            picture.camera = StageFrame.cameraFillsFrame(shape: shape, showsContent: hasContent)
                ? StageFrame.fullFrameCameraRect(aspect: aspect)
                : StageFrame.cameraRect(box: box, shape: shape, aspect: aspect, content: picture.content)
        }
        return picture
    }
}
