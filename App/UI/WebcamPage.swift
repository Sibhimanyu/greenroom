//
//  WebcamPage.swift
//  Greenroom
//
//  Settings -> Webcam: what the class sees, and how you appear in it.
//
//  Built to be looked at rather than read. The picture is the stage; every
//  choice on the page is a picture of itself (looks, sizes, corners, what is
//  shared); explanations live in hover help, not in captions. Camera tools
//  converge on this - Loom's three bubble sizes, Screen Studio's corner
//  layouts, Apple's video-effects thumbnails - and it is what a page of five
//  paragraphs was missing.
//
//  `WebcamPageContent` takes plain bindings, not the coordinator, so the same
//  view can be rendered off screen with sample values to check it by eye.
//  `WebcamSettingsTab` is the thin layer that feeds it from the coordinator.
//
import SwiftUI

// MARK: - The tab

struct WebcamSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @State private var displays: [DisplayInfo] = DisplayResolver.connectedDisplays()

    /// The coordinator's separate fractions as the one value the page edits.
    /// A cutout keeps the camera's aspect and stands on the bottom edge, so it
    /// stores a height and a horizontal position rather than the bubble's three.
    private var geometry: Binding<BubbleDragLayer.Geometry> {
        coordinator.webcamShape == .cutout
            ? Binding(
                get: { .init(size: coordinator.cutoutHeightFraction,
                             rightInset: coordinator.cutoutRightInset, bottomInset: 0) },
                set: {
                    coordinator.cutoutHeightFraction = $0.size
                    coordinator.cutoutRightInset = $0.rightInset
                })
            : Binding(
                get: { .init(size: coordinator.bubbleWidthFraction,
                             rightInset: coordinator.bubbleRightInset,
                             bottomInset: coordinator.bubbleBottomInset) },
                set: {
                    coordinator.bubbleWidthFraction = $0.size
                    coordinator.bubbleRightInset = $0.rightInset
                    coordinator.bubbleBottomInset = $0.bottomInset
                })
    }

    var body: some View {
        WebcamPageContent(
            shape: Binding(get: { coordinator.webcamShape },
                           set: { coordinator.webcamShape = $0; coordinator.requestShapeApply() }),
            removal: $coordinator.backgroundRemoval,
            geometry: geometry,
            shareKind: $coordinator.shareTarget.kind,
            previewAspect: coordinator.shapePreviewAspect,
            cameraSeesYou: coordinator.cameraSeesYou || !coordinator.webcamShape.usesChromaKey,
            isAtDefault: coordinator.bubbleIsAtDefault,
            apply: { coordinator.requestShapeApply() },
            reset: {
                coordinator.resetBubbleLayout()
                coordinator.requestShapeApply()
            },
            livePicture: { LiveCompositePicture(feed: coordinator.shapePreview) },
            shareDetail: {
                ShareTargetSettings(displays: displays,
                                    onChange: { coordinator.requestShapeApply(rebuild: true) })
            },
            cameras: { CameraSwitchSection() },
            recording: {
                Toggle("Keep the last 5 minutes clippable", isOn: $coordinator.clipBufferEnabled)
                    .help("\u{2325}\u{2318}1, 2 or 5 saves the last minutes as a clip, recording or not. About 300 MB of memory, nothing on disk until you press.")
                Toggle("Record automatically with the meeting", isOn: $coordinator.autoRecordOnStart)
                    .help("Off: press Record or \u{2325}\u{2318}R. Files land in Documents/Greenroom.")
                Toggle("Keep OBS ready in the background", isOn: $coordinator.keepOBSWarm)
                    .help("Start skips OBS\u{2019}s launch, and this page shows the real picture. OBS still quits with Greenroom.")
            })
        .onAppear {
            displays = DisplayResolver.connectedDisplays()
            coordinator.startShapePreview()
        }
        .onDisappear { coordinator.stopShapePreview() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = DisplayResolver.connectedDisplays()
        }
    }
}

/// The live composite, observing the frame feed and nothing else, so a new
/// frame redraws this picture and only this picture.
struct LiveCompositePicture: View {
    @ObservedObject var feed: ShapePreviewFeed

    var body: some View {
        if let frame = feed.frame {
            Image(nsImage: frame)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - The page

struct WebcamPageContent<LivePicture: View, ShareDetail: View, Cameras: View, Recording: View>: View {
    @Binding var shape: WebcamShape
    @Binding var removal: BackgroundRemoval
    @Binding var geometry: BubbleDragLayer.Geometry
    @Binding var shareKind: ShareTarget.Kind
    /// The live picture's size, or nil while the sketch is showing.
    let previewAspect: CGSize?
    /// False while background removal finds nobody in the camera.
    var cameraSeesYou = true
    let isAtDefault: Bool
    let apply: () -> Void
    let reset: () -> Void
    @ViewBuilder let livePicture: () -> LivePicture
    @ViewBuilder let shareDetail: () -> ShareDetail
    @ViewBuilder let cameras: () -> Cameras
    @ViewBuilder let recording: () -> Recording

    /// Where the bubble is while it is being dragged or nudged.
    ///
    /// A drag used to write every pointer move straight into the coordinator:
    /// three @Published values and three UserDefaults writes per event, each
    /// redrawing the whole Settings window. That is most of why dragging felt
    /// heavy. Now a drag moves only this, which redraws only the stage, and
    /// the coordinator hears once, when the drag ends.
    @State private var draft: BubbleDragLayer.Geometry?
    private var stageGeometry: Binding<BubbleDragLayer.Geometry> {
        Binding(get: { draft ?? geometry }, set: { draft = $0 })
    }

    /// The end of a drag or a burst of nudges: hand the result over, once.
    private func commitDraft() {
        if let draft { geometry = draft }
        draft = nil
        apply()
    }

    private var isLive: Bool { previewAspect != nil }
    private var isCutout: Bool { shape == .cutout }
    /// Presenter rebuilds the whole scene rather than placing a source, so it
    /// has no size or position to edit.
    private var isAdjustable: Bool { shape != .presenterLarge }
    private var canvasAspect: CGSize { previewAspect ?? CGSize(width: 16, height: 10) }

    /// 16:9, the fallback GreenroomScene uses when it cannot read the camera.
    /// Not the preview's aspect: that is the OBS canvas, not the camera.
    private static var cameraAspect: Double { 16.0 / 9.0 }

    private var mode: BubbleDragLayer.Mode {
        isCutout ? .cutout(aspect: Self.cameraAspect)
                 : .bubble(aspect: shape.cropsToSquare ? 1 : Self.cameraAspect)
    }

    var body: some View {
        Form {
            Section {
                stage
                if isAdjustable { stageControls }
            }

            Section("Look") {
                LookPicker(selection: $shape, removal: removal)
                if shape.usesChromaKey {
                    Picker("Background", selection: $removal) {
                        Label("Remove automatically", systemImage: "wand.and.stars").tag(BackgroundRemoval.automatic)
                        Label("Green screen", systemImage: "rectangle.fill").tag(BackgroundRemoval.greenScreen)
                    }
                    .pickerStyle(.segmented)
                    .help("Automatic finds you in the camera and removes the rest. Green screen keys out a real green backdrop instead.")
                }
            }

            Section("Behind you") {
                ShareKindPicker(selection: $shareKind)
                shareDetail()
            }

            Section("Cameras") { cameras() }
            Section("Recording") { recording() }
        }
        .formStyle(.grouped)
    }

    // MARK: Stage

    /// The live composite or the sketch, with the drag layer as a SIBLING of
    /// both - never inside the picture, which refreshes on a timer
    /// (DESIGN.md, Affordances).
    private var stage: some View {
        // One rect for all three layers: the picture is fitted to the canvas
        // aspect and centred, and the drag layer and the chip measure from
        // that same rect, so handles sit on the picture and not beside it.
        GeometryReader { box in
            let canvas = WebcamShapePreview.fittedCanvas(in: box.size, aspect: canvasAspect)
            ZStack(alignment: .topLeading) {
                Group {
                    if isLive {
                        livePicture()
                    } else {
                        WebcamShapePreview(shape: shape, geometry: stageGeometry, mode: mode)
                    }
                }
                .frame(width: canvas.width, height: canvas.height)
                .offset(x: canvas.minX, y: canvas.minY)
                .allowsHitTesting(false)

                if isAdjustable {
                    BubbleDragLayer(
                        geometry: stageGeometry, mode: mode, shape: shape,
                        canvas: canvas, showsOutline: isLive, onCommit: commitDraft)
                        .frame(width: box.size.width, height: box.size.height)
                }

                HStack(spacing: 6) {
                    StatusChip(isLive: isLive)
                    if isLive && !cameraSeesYou { NobodyChip() }
                }
                .offset(x: canvas.minX + 10, y: canvas.minY + 10)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 360)
        .help(isAdjustable ? "Drag yourself to move. Drag a corner to resize." : "")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview of what the class sees")
    }

    /// Size and position as pictures: three sizes, and a screen to tap a
    /// corner of. Dragging in the stage above is the fine control.
    private var stageControls: some View {
        HStack(spacing: 16) {
            SizePresetPicker(presets: sizePresets, value: geometry.size) { size in
                set(size: size)
            }
            Spacer(minLength: 0)
            PlacementPicker(spots: spots, current: currentSpot) { spot in
                place(spot)
            }
            Button { draft = nil; reset() } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .disabled(isAtDefault)
            .help("Back to where it started")
            .accessibilityLabel("Reset size and position")
        }
        .padding(.vertical, 2)
    }

    // MARK: Size

    private var sizePresets: [Double] {
        // Bubble: share of the canvas width. Cutout: share of its height.
        isCutout ? [0.36, 0.5, 0.7] : [0.16, 0.24, 0.34]
    }

    private func set(size: Double) {
        draft = nil
        var next = geometry
        // Keep the side it was hugging: a bigger bubble in the left corner
        // should still be in the left corner, not pushed off the edge.
        let spot = currentSpot
        next.size = size
        geometry = next
        if let spot { place(spot) } else { apply() }
    }

    // MARK: Position

    private var spots: [PlacementSpot] {
        isCutout ? [.bottomLeft, .bottom, .bottomRight]
                 : [.topLeft, .topRight, .bottomLeft, .bottomRight]
    }

    /// Margins the shipped layout uses, so a corner picked here lands where a
    /// fresh install would put it.
    private static var margin: (side: Double, bottom: Double, cutoutSide: Double) {
        let shipped = GreenroomScene.BubbleLayout()
        return (shipped.rightInset, shipped.bottomInset, shipped.cutoutRightInset)
    }

    private func target(for spot: PlacementSpot) -> BubbleDragLayer.Geometry {
        let canvas = canvasAspect.width / max(canvasAspect.height, 1)
        var next = geometry
        if isCutout {
            let width = geometry.size * Self.cameraAspect / canvas   // as a share of canvas width
            switch spot {
            case .bottomLeft: next.rightInset = 1 - width - Self.margin.cutoutSide
            case .bottom: next.rightInset = (1 - width) / 2
            default: next.rightInset = Self.margin.cutoutSide
            }
        } else {
            let height = geometry.size * canvas / mode.aspect      // as a share of canvas height
            next.rightInset = spot.isRight ? Self.margin.side : 1 - geometry.size - Self.margin.side
            next.bottomInset = spot.isBottom ? Self.margin.bottom : 1 - height - Self.margin.bottom
        }
        next.rightInset = max(0, next.rightInset)
        next.bottomInset = max(0, next.bottomInset)
        return next
    }

    private var currentSpot: PlacementSpot? {
        spots.first { spot in
            let goal = target(for: spot)
            return abs(goal.rightInset - geometry.rightInset) < 0.01
                && abs(goal.bottomInset - geometry.bottomInset) < 0.01
        }
    }

    private func place(_ spot: PlacementSpot) {
        draft = nil
        geometry = target(for: spot)
        apply()
    }
}

// MARK: - Pieces

/// LIVE over the real composite, PREVIEW over the sketch.
private struct StatusChip: View {
    let isLive: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isLive ? Brand.green : Color.white.opacity(0.6))
                .frame(width: 6, height: 6)
            Text(isLive ? "LIVE" : "PREVIEW")
                .font(.caption2.weight(.bold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.72), in: Capsule())
        .foregroundStyle(.white)
        .help(isLive ? "The picture the meeting gets, from OBS."
                     : "A sketch. Turn on \u{201C}Keep OBS ready\u{201D} under Recording to see the real picture.")
    }
}

/// Shown when background removal finds nobody: the picture is empty because
/// everything was removed, not because the camera is broken.
private struct NobodyChip: View {
    var body: some View {
        Label("Can\u{2019}t see you", systemImage: "eye.slash")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.72), in: Capsule())
            .foregroundStyle(.white)
            .help("Nobody is in view of the camera, so everything was removed. Check the camera is pointing at you.")
    }
}

/// The five looks as pictures. What each one does is in its hover help.
private struct LookPicker: View {
    @Binding var selection: WebcamShape
    let removal: BackgroundRemoval

    var body: some View {
        HStack(spacing: 8) {
            ForEach(WebcamShape.allCases) { shape in
                ChoiceTile(title: shape.label, selected: shape == selection,
                           badge: badge(for: shape)) {
                    ShapeGlyph(shape: shape, highlighted: shape == selection)
                } action: { selection = shape }
                .help(help(for: shape))
            }
        }
        .padding(.vertical, 4)
    }

    private func badge(for shape: WebcamShape) -> String? {
        guard shape.usesChromaKey else { return nil }
        return removal == .automatic ? "wand.and.stars" : "rectangle.fill"
    }

    private func help(for shape: WebcamShape) -> String {
        switch shape {
        case .square: return "Your camera in a box"
        case .roundedRectangle: return "Your camera in a rounded box"
        case .circle: return "Your camera in a circle"
        case .cutout: return "You without your background, standing on the bottom edge"
        case .presenterLarge: return "Your screen as a panel, you beside it at full height"
        }
    }
}

/// Whole screen, one app, or one window, as pictures.
private struct ShareKindPicker: View {
    @Binding var selection: ShareTarget.Kind

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ShareTarget.Kind.allCases) { kind in
                ChoiceTile(title: title(kind), selected: kind == selection, badge: nil) {
                    Image(systemName: symbol(kind))
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(kind == selection ? Brand.green : Color.secondary)
                        .frame(height: 32)
                } action: { selection = kind }
                .help(help(kind))
            }
        }
        .padding(.vertical, 4)
    }

    private func title(_ kind: ShareTarget.Kind) -> String {
        switch kind {
        case .display: return "Screen"
        case .app: return "App"
        case .window: return "Window"
        }
    }

    private func symbol(_ kind: ShareTarget.Kind) -> String {
        switch kind {
        case .display: return "display"
        case .app: return "square.grid.2x2"
        case .window: return "macwindow"
        }
    }

    private func help(_ kind: ShareTarget.Kind) -> String {
        switch kind {
        case .display: return "Everything on one screen"
        case .app: return "Only one app\u{2019}s windows"
        case .window: return "Just one window, on a dark backdrop"
        }
    }
}

/// A selectable card: a picture, a short name, an optional badge.
private struct ChoiceTile<Picture: View>: View {
    let title: String
    let selected: Bool
    let badge: String?
    @ViewBuilder let picture: () -> Picture
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                picture()
                    .frame(maxWidth: .infinity)
                Text(title)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Brand.green.opacity(0.12) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Brand.green : Color.secondary.opacity(0.25),
                              lineWidth: selected ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Image(systemName: badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(selected ? Brand.green : Color.secondary)
                        .padding(6)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// S, M, L as three bubbles of growing size.
private struct SizePresetPicker: View {
    let presets: [Double]
    let value: Double
    let choose: (Double) -> Void

    private static let names = ["Small", "Medium", "Large"]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(presets.enumerated()), id: \.offset) { index, preset in
                let selected = abs(value - preset) < 0.005
                Button { choose(preset) } label: {
                    Circle()
                        .fill(selected ? Brand.green : Color.secondary.opacity(0.45))
                        .frame(width: CGFloat(10 + index * 5), height: CGFloat(10 + index * 5))
                        .frame(width: 34, height: 28)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(selected ? Brand.green.opacity(0.12) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Self.names[index])
                .accessibilityLabel("\(Self.names[index]) size")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
    }
}

enum PlacementSpot: Hashable {
    case topLeft, topRight, bottomLeft, bottom, bottomRight
    var isRight: Bool { self == .topRight || self == .bottomRight }
    var isBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    var label: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottom: return "Bottom centre"
        case .bottomRight: return "Bottom right"
        }
    }
    /// Where the dot sits on the little screen, 0...1.
    var point: CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: 0, y: 0)
        case .topRight: return CGPoint(x: 1, y: 0)
        case .bottomLeft: return CGPoint(x: 0, y: 1)
        case .bottom: return CGPoint(x: 0.5, y: 1)
        case .bottomRight: return CGPoint(x: 1, y: 1)
        }
    }
}

/// A little screen with a dot at each place you can go. Tap a dot.
private struct PlacementPicker: View {
    let spots: [PlacementSpot]
    let current: PlacementSpot?
    let choose: (PlacementSpot) -> Void

    var body: some View {
        let width: CGFloat = 64, height: CGFloat = 40, inset: CGFloat = 9
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1.5)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.08)))
            ForEach(spots, id: \.self) { spot in
                let selected = spot == current
                Button { choose(spot) } label: {
                    Circle()
                        .fill(selected ? Brand.green : Color.secondary.opacity(0.5))
                        .frame(width: selected ? 10 : 7, height: selected ? 10 : 7)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(spot.label)
                .accessibilityLabel(spot.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .position(x: inset + spot.point.x * (width - 2 * inset),
                          y: inset + spot.point.y * (height - 2 * inset))
            }
        }
        .frame(width: width, height: height)
    }
}

/// A thumbnail of a look: the shared screen as a grey panel, the person in
/// the accent colour when picked.
struct ShapeGlyph: View {
    let shape: WebcamShape
    let highlighted: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let person = highlighted ? Brand.green : Color.secondary
            ZStack {
                if shape.isPresenterStyle {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: w * 0.62, height: h * 0.7)
                        .position(x: w * 0.66, y: h * 0.5)
                    Image(systemName: "person.fill")
                        .resizable().scaledToFit()
                        .foregroundStyle(person)
                        .frame(height: h * 0.85)
                        .position(x: w * 0.2, y: h * 0.55)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.18))
                    bubble(person: person, w: w, h: h)
                }
            }
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .frame(height: 44)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func bubble(person: Color, w: CGFloat, h: CGFloat) -> some View {
        let side = h * 0.42
        switch shape {
        case .square:
            Rectangle().fill(person)
                .frame(width: side * 1.3, height: side)
                .position(x: w - side * 0.65 - 4, y: h - side / 2 - 4)
        case .roundedRectangle:
            RoundedRectangle(cornerRadius: side * 0.25).fill(person)
                .frame(width: side * 1.3, height: side)
                .position(x: w - side * 0.65 - 4, y: h - side / 2 - 4)
        case .circle:
            Circle().fill(person)
                .frame(width: side, height: side)
                .position(x: w - side / 2 - 4, y: h - side / 2 - 4)
        case .cutout, .presenterLarge:
            Image(systemName: "person.fill")
                .resizable().scaledToFit()
                .foregroundStyle(person)
                .frame(height: h * 0.6)
                .position(x: w * 0.78, y: h - h * 0.3)
        }
    }
}
