//
//  LayoutEveryonePicture.swift
//  Greenroom
//
//  Preview: Everyone in Settings -> Layouts (R37): the meeting's real picture, 16:9, drawn from
//  `EveryonePicture` (the numbers `StageRenderer` draws with). Read-only: nothing here takes a click.
//
import SwiftUI

struct LayoutEveryonePicture: View {
    let picture: EveryonePicture
    let pieces: [LayoutPiece]
    let displaySize: CGSize
    let look: (LayoutPiece) -> LayoutPieceLook
    let camera: LayoutCameraModel?

    /// `--ink` (`StageFrame.ink`), the compositor's backdrop.
    static let backdrop = Color(red: StageFrame.ink.red, green: StageFrame.ink.green, blue: StageFrame.ink.blue)

    var body: some View {
        GeometryReader { geo in
            let k = geo.size.width / StageFrame.output.width
            ZStack(alignment: .topLeading) {
                Self.backdrop
                if picture.whiteboardCard, let c = picture.content {
                    Rectangle().fill(Color.white).frame(width: c.width * k, height: c.height * k)
                        .offset(x: c.minX * k, y: c.minY * k)
                }
                ForEach(picture.tiles, id: \.id) { tile in
                    if let piece = pieces.first(where: { $0.id == tile.id }) {
                        let size = CGSize(width: tile.rect.width * k, height: tile.rect.height * k)
                        let box = LayoutGeometry.pointSize(of: piece.rect, display: displaySize)
                        LayoutPieceTile(piece: piece, look: look(piece), size: size, pointSize: box,
                                        columns: LayoutGeometry.cellSpan(of: piece.rect).cols.count, selected: false)
                            .frame(width: size.width, height: size.height)
                            .offset(x: tile.rect.minX * k, y: tile.rect.minY * k)
                    }
                }
                if let rect = picture.camera, let camera {
                    CameraStandIn(shape: StageFrame.cameraShape(camera.shape, showsContent: picture.content != nil), meaning: .camera(camera.state), off: false,
                                  size: CGSize(width: rect.width * k, height: rect.height * k))
                        .frame(width: rect.width * k, height: rect.height * k)
                        .offset(x: rect.minX * k, y: rect.minY * k)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
        .aspectRatio(StageFrame.output.width / StageFrame.output.height, contentMode: .fit)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview: what everyone sees")
    }
}
