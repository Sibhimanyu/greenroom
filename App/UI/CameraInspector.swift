//
//  CameraInspector.swift
//  Greenroom
//
//  The camera piece's inspector in Settings -> Layouts (R11.1), kept plain: a header with a small
//  live picture (click to enlarge) and a ⋯ menu (corner, Reset size and position), then who sees
//  the camera, then shape and size (S / M / L; fine sizing is a drag on the canvas), then the
//  folded "Camera look · every layout". Plain values and bindings, so it renders off screen.
//
import SwiftUI

/// The live composite and what it can say about it.
struct CameraPreviewModel {
    let feed: ShapePreviewFeed
    /// The picture's size, or nil while no frame has arrived.
    var aspect: CGSize?
    /// False while background removal finds nobody in the camera.
    var seesYou = true
}

struct CameraInspector: View {
    let camera: LayoutCameraModel
    /// The saved piece the shape, size and spot edit; nil with no active layout.
    let piece: Binding<LayoutCamera>?
    /// The camera's canvas: the whole display's width over height.
    let canvasAspect: Double
    let readout: String
    @Binding var lookOpen: Bool
    @State private var largePreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            whoSees
            if let piece { shapeAndSize(piece) }
            if let look = camera.look {
                // The saved piece's shape, not the live one: the look follows the picker above.
                CameraLookGroup(look: look, shape: piece?.wrappedValue.shape ?? camera.shape, isOpen: $lookOpen)
            }
        }
    }

    // MARK: Rows

    /// A small live picture, the name, and a menu for the spot and Reset.
    private var header: some View {
        HStack(spacing: 8) {
            if let preview = camera.preview { thumbnail(preview) }
            Text("Your camera")
                .font(.callout.weight(.semibold))
            Text(readout)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            if let piece, CameraPlacementRules.isAdjustable(shape: piece.wrappedValue.shape) { moreMenu(piece) }
        }
    }

    private func thumbnail(_ preview: CameraPreviewModel) -> some View {
        let height: CGFloat = largePreview ? 135 : 36
        let ratio = preview.aspect.map { $0.width / max($0.height, 1) } ?? 16.0 / 9.0
        return Button {
            Collapse.animate { largePreview.toggle() }
        } label: {
            CameraLivePicture(feed: preview.feed, hasFrame: preview.aspect != nil, seesYou: preview.seesYou,
                              compact: !largePreview)
                .frame(width: height * ratio, height: height)
        }
        .buttonStyle(.plain)
        .help(largePreview ? "Click for a compact preview. Drag the camera on the canvas to move it, a corner to resize it."
                           : "What everyone sees. Click to enlarge it.")
        .accessibilityLabel(largePreview ? "Compact preview" : "Enlarge preview")
    }

    private func moreMenu(_ piece: Binding<LayoutCamera>) -> some View {
        let cam = piece.wrappedValue
        let spot = CameraPlacementRules.currentSpot(of: cam, canvasAspect: canvasAspect)
        return Menu {
            ForEach(CameraPlacementRules.spots(for: cam.shape), id: \.self) { chosen in
                Button {
                    piece.wrappedValue = CameraPlacementRules.placing(piece.wrappedValue, at: chosen, canvasAspect: canvasAspect)
                } label: {
                    Text(chosen == spot ? "\(chosen.label) \u{2713}" : chosen.label)
                }
            }
            Divider()
            Button("Reset size and position") { piece.wrappedValue = CameraPlacementRules.reset(piece.wrappedValue) }
                .disabled(CameraPlacementRules.isAtDefault(cam))
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Put the camera in a corner, or back where it started. The spot, size and shape are saved with this layout.")
        .accessibilityLabel("Camera position")
    }

    private var whoSees: some View {
        HStack(spacing: 24) {
            Text("Who sees my camera")
                .font(.callout)
            GreenroomSegmented("Who sees my camera", selection: Binding(get: { camera.state }, set: { camera.setState($0) }),
                               options: CameraState.allCases) { Text($0.name) }
                .segmentHelp { $0.detail }
                .help("Where each meeting starts. The bar and Home change it for one meeting only.")
            Spacer(minLength: 0)
        }
    }

    /// The shape, and S / M / L on the shared choice tile. Fine sizing is a drag on the canvas.
    private func shapeAndSize(_ piece: Binding<LayoutCamera>) -> some View {
        let cam = piece.wrappedValue
        let size = cam.shape == .cutout ? cam.cutoutHeightFraction : cam.widthFraction
        let names = ["Small", "Medium", "Large"]
        return HStack(spacing: 12) {
            Picker("Shape", selection: piece.shape) {
                ForEach(WebcamShape.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
            .help("The shape of your camera in this layout. The look (background, removal, mirror) is shared by every layout.")
            if CameraPlacementRules.isAdjustable(shape: cam.shape) {
                HStack(spacing: 6) {
                    ForEach(Array(CameraPlacementRules.sizePresets(for: cam.shape).enumerated()), id: \.offset) { index, preset in
                        let selected = abs(size - preset) < 0.005
                        Button {
                            piece.wrappedValue = CameraPlacementRules.sizing(piece.wrappedValue, to: preset, canvasAspect: canvasAspect)
                        } label: {
                            Circle()
                                .fill(Color.secondary.opacity(0.55))
                                .frame(width: CGFloat(10 + index * 5), height: CGFloat(10 + index * 5))
                                .frame(width: 48, height: 32)
                        }
                        .greenroomTile(role: .choice(selected: selected))
                        .help("\(names[index]). Drag a corner of the camera on the canvas for a finer size.")
                        .accessibilityLabel("\(names[index]) size")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// The live composite, observing the frame feed and nothing else, so a new frame redraws this
/// picture and only this picture. The "nobody in camera" mark lives on the picture alone.
private struct CameraLivePicture: View {
    @ObservedObject var feed: ShapePreviewFeed
    let hasFrame: Bool
    let seesYou: Bool
    /// The header thumbnail: a small eye mark instead of the chips.
    var compact = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(Color.black)
            if let frame = feed.frame {
                Image(nsImage: frame).resizable().scaledToFit()
            }
            if compact {
                if hasFrame, !seesYou {
                    Image(systemName: VisibilitySymbol.everyoneSees(false).name)
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(4)
                        .help("Nobody is in view of the camera, so everything was removed. Check the camera is pointing at you.")
                }
            } else {
                HStack(spacing: 6) {
                    PictureChip(text: hasFrame ? "LIVE" : "PREVIEW", dot: hasFrame ? Brand.green : Color.white.opacity(0.6))
                    if hasFrame, !seesYou {
                        PictureChip(text: "Can\u{2019}t see you", symbol: VisibilitySymbol.everyoneSees(false).name)
                            .help("Nobody is in view of the camera, so everything was removed. Check the camera is pointing at you.")
                    }
                }
                .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
