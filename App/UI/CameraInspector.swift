//
//  CameraInspector.swift
//  Greenroom
//
//  The camera piece's inspector in Settings -> Layouts (R11.1, R35): the same structure as every piece.
//  A header (the live picture, click to enlarge; name; one readout; a ⋯ menu with the corners and
//  Reset), then two rows: who sees the camera (four icons) with the "Camera look" fold beside it, and
//  the shape tiles with S / M / L (fine sizing is a drag on the canvas). Plain values and bindings,
//  so it renders off screen.
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
            whoSeesRow
            if let piece { shapeAndSize(piece) }
            if let look = camera.look {
                // The saved piece's shape, not the live one: the look follows the tiles above.
                Collapsible(hidden: !lookOpen) {
                    CameraLookContent(look: look, shape: piece?.wrappedValue.shape ?? camera.shape).padding(.top, 2)
                }
            }
        }
    }

    // MARK: Rows

    /// A small live picture, the name, one readout, and a menu for the spot and Reset.
    private var header: some View {
        HStack(spacing: 8) {
            if let preview = camera.preview {
                thumbnail(preview)
            } else {
                Image(systemName: VisibilitySymbol.camera(camera.state).name)
                    .foregroundStyle(.secondary).frame(width: 20, height: 20)
            }
            Text("Your camera")
                .font(.callout.weight(.semibold))
            Text(readout)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
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

    /// Row 1: who sees the camera, as four icons (tooltips say which), and the Camera look fold beside it.
    private var whoSeesRow: some View {
        HStack(spacing: 12) {
            Text("Who sees my camera")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            GreenroomSegmented("Who sees my camera", selection: Binding(get: { camera.state }, set: { camera.setState($0) }),
                               options: PieceInspectorRules.cameraChoices) { CameraStateIcon(state: $0) }
                .segmentHelp { PieceInspectorRules.cameraTip($0) }
            Spacer(minLength: 8)
            if let look = camera.look {
                Button {
                    Collapse.animate { lookOpen.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text("Camera look").font(.system(size: 11))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(lookOpen ? 90 : 0))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(CameraLookRules.sameInEveryLayout). " + CameraLookRules.summary(
                    shape: piece?.wrappedValue.shape ?? camera.shape, backgroundName: look.background.wrappedValue.rawValue,
                    removal: look.removal.wrappedValue, mirror: look.mirror.wrappedValue))
                .accessibilityLabel("Camera look")
                .accessibilityValue(lookOpen ? "Expanded" : "Collapsed")
            }
        }
    }

    /// Row 2: the shape tiles (shared with Home's Look) and S / M / L beside them. Fine sizing is a drag on the canvas.
    private func shapeAndSize(_ piece: Binding<LayoutCamera>) -> some View {
        let cam = piece.wrappedValue
        let size = cam.shape == .cutout ? cam.cutoutHeightFraction : cam.widthFraction
        let names = ["Small", "Medium", "Large"]
        let letters = ["S", "M", "L"]
        return HStack(alignment: .top, spacing: 16) {
            CameraShapeTiles(selected: cam.shape) { piece.wrappedValue.shape = $0 }
            if CameraPlacementRules.isAdjustable(shape: cam.shape) {
                HStack(spacing: HomeTileMetrics.tileGap) {
                    ForEach(Array(CameraPlacementRules.sizePresets(for: cam.shape).enumerated()), id: \.offset) { index, preset in
                        let selected = abs(size - preset) < 0.005
                        Button {
                            piece.wrappedValue = CameraPlacementRules.sizing(piece.wrappedValue, to: preset, canvasAspect: canvasAspect)
                        } label: {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(Color.secondary.opacity(0.55))
                                    .frame(width: CGFloat(10 + index * 6), height: CGFloat(10 + index * 6))
                                    .frame(width: 40, height: 40)
                                Text(letters[index])
                                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? .primary : .secondary)
                            }
                            .padding(.vertical, 6)
                            .frame(width: 48)
                        }
                        .greenroomTile(role: .choice(selected: selected), radius: 10)
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

/// One camera state as an icon: Zoom's camera, struck for Off, wearing the struck eye for Only me, in a dashed
/// outline for Only everyone (the same marks as the canvas, VisibilitySymbol). Spoken as the state's name.
struct CameraStateIcon: View {
    let state: CameraState

    var body: some View {
        let meaning = VisibilitySymbol.camera(state)
        Image(systemName: meaning.name)
            .font(.system(size: 12))
            .symbolBadge(meaning.badge, size: 7)
            .frame(width: 30, height: 18)
            .overlay {
                if meaning.dashed {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .padding(1)
                }
            }
            .accessibilityLabel(state.name)
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
                    Image(systemName: VisibilitySymbol.nobodyInCamera.name)
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(4)
                        .help("Nobody is in view of the camera, so everything was removed. Check the camera is pointing at you.")
                }
            } else {
                HStack(spacing: 6) {
                    PictureChip(text: hasFrame ? "LIVE" : "PREVIEW", dot: hasFrame ? Brand.green : Color.white.opacity(0.6))
                    if hasFrame, !seesYou {
                        PictureChip(text: "Can\u{2019}t see you", symbol: VisibilitySymbol.nobodyInCamera.name)
                            .help("Nobody is in view of the camera, so everything was removed. Check the camera is pointing at you.")
                    }
                }
                .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
