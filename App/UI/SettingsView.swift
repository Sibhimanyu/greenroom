//
//  SettingsView.swift
//  Greenroom
//
//  Everything here is "set once, rarely touched" - opened via
//  Greenroom -> Settings... (⌘,), the standard macOS location, rather
//  than cluttering the main window's day-to-day flow. Shares the same
//  CoordinatorController instance as ContentView (injected via
//  .environmentObject in GreenroomApp.swift), so changes take effect
//  immediately.
//
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var coordinator: CoordinatorController

    var body: some View {
        TabView {
            WebcamSettingsTab()
                .tabItem { Label("Webcam", systemImage: "video.fill") }

            LayoutSettingsTab()
                .tabItem { Label("Layout", systemImage: "rectangle.split.2x1") }

            ZoomSettingsTab()
                .tabItem { Label("Zoom", systemImage: "video.fill") }

            YouTubeSettingsTab()
                .tabItem { Label("YouTube", systemImage: "play.rectangle.fill") }

            CuesSettingsTab()
                .tabItem { Label("Cues", systemImage: "waveform.and.magnifyingglass") }
            ScreenroomSettingsTab()
                .tabItem { Label("Screenroom", systemImage: "chart.bar.doc.horizontal") }

            TransferSettingsTab()
                .tabItem { Label("Transfer", systemImage: "square.and.arrow.up.on.square") }
        }
        .frame(width: 760, height: 730)
        // Secrets are loaded lazily (see loadSecretsIfNeeded) - opening
        // Settings is the first moment the fields actually need them.
        .onAppear { coordinator.loadSecretsIfNeeded() }
    }
}

/// What the class sees, and how you appear in it.
///
/// Laid out in the order someone thinks about it: the picture first, then the
/// look, then where you sit and what is shared behind you, and the setup
/// details (cameras, recording) last.
///
/// Every control here writes the setting and then asks the coordinator to
/// apply it (`requestShapeApply`), which coalesces a burst of changes into
/// one. The live picture is the only view that watches the 150ms frame feed;
/// see `CoordinatorController.shapePreview` for what happened when the whole
/// tab watched it.
private struct WebcamSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @State private var displays: [DisplayInfo] = DisplayResolver.connectedDisplays()

    /// Bridges the coordinator's separate published fractions to the one binding
    /// the drag layer wants. Two shapes, two sets of numbers: a cutout keeps the
    /// camera's real aspect and pins its bottom edge, so it stores a height and
    /// a horizontal position rather than the bubble's three.
    private var editedGeometry: Binding<BubbleDragLayer.Geometry> {
        isCutout
            ? Binding(
                get: { .init(size: coordinator.cutoutHeightFraction,
                             rightInset: coordinator.cutoutRightInset,
                             bottomInset: 0) },
                set: { updated in
                    coordinator.cutoutHeightFraction = updated.size
                    coordinator.cutoutRightInset = updated.rightInset
                })
            : Binding(
                get: { .init(size: coordinator.bubbleWidthFraction,
                             rightInset: coordinator.bubbleRightInset,
                             bottomInset: coordinator.bubbleBottomInset) },
                set: { updated in
                    coordinator.bubbleWidthFraction = updated.size
                    coordinator.bubbleRightInset = updated.rightInset
                    coordinator.bubbleBottomInset = updated.bottomInset
                })
    }

    private var isCutout: Bool { coordinator.webcamShape == .cutout }
    private var isLivePreview: Bool { coordinator.shapePreviewAspect != nil }
    /// The aspect the picture on screen is drawn at, so the drag layer measures
    /// against the same rect the teacher is looking at.
    private var previewAspect: CGSize {
        coordinator.shapePreviewAspect ?? CGSize(width: 16, height: 10)
    }
    /// Presenter is the one shape with nothing to drag: layoutPresenter rebuilds
    /// the whole scene rather than placing a source, so there is no single
    /// position or size behind it to edit.
    private var isAdjustable: Bool { coordinator.webcamShape != .presenterLarge }

    /// 16:9, matching the fallback GreenroomScene uses when it cannot read the
    /// source dimensions. It would be wrong to take this from the preview:
    /// that is the OBS CANVAS, and what shapes the webcam is the CAMERA's
    /// aspect.
    private static let assumedCameraAspect = 16.0 / 9.0

    private var editMode: BubbleDragLayer.Mode {
        if isCutout { return .cutout(aspect: Self.assumedCameraAspect) }
        // Circle crops the camera square before masking, so its box is square.
        // The rectangular shapes keep the full frame, so theirs is not.
        return .bubble(aspect: coordinator.webcamShape.cropsToSquare
                       ? 1 : Self.assumedCameraAspect)
    }

    var body: some View {
        Form {
            Section {
                picture
                pictureStatus
            } header: { Text("What the class sees") }

            Section {
                ShapeCardPicker(selection: Binding(
                    get: { coordinator.webcamShape },
                    set: { coordinator.webcamShape = $0; coordinator.requestShapeApply() }),
                                needsGreenScreen: coordinator.backgroundRemoval == .greenScreen)
                Text(shapeCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Shown for every look, greyed out where there is no
                // background to remove, so it is found before it is needed.
                Picker("Remove your background", selection: $coordinator.backgroundRemoval) {
                    ForEach(BackgroundRemoval.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!coordinator.webcamShape.usesChromaKey)
            } header: { Text("How you appear") }

            if isAdjustable {
                Section {
                    placementControls
                } header: { Text(isCutout ? "Size and position" : "Bubble size and position") }
            }

            Section {
                ShareTargetSettings(displays: displays,
                                    onChange: { coordinator.requestShapeApply(rebuild: true) })
            } header: { Text("What you share behind you") }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                displays = DisplayResolver.connectedDisplays()
            }

            // Below the look now, not above it. It used to come first because
            // it was once lost under a 400pt preview; the preview is shorter
            // and the sections are headed, so it is one scroll away and named.
            Section {
                CameraSwitchSection()
            } header: { Text("Cameras") }

            Section {
                Toggle(isOn: $coordinator.clipBufferEnabled) {
                    SettingLabel(title: "Keep the last 5 minutes clippable",
                                 subtitle: "\u{2325}\u{2318}1 / 2 / 5 save the last minutes as a clip, recording or not. About 300 MB in memory, never on disk until you press.")
                }
                Toggle(isOn: $coordinator.autoRecordOnStart) {
                    SettingLabel(title: "Start recording automatically with the meeting",
                                 subtitle: "Off: press Record or \u{2325}\u{2318}R. Either way the file lands in Documents/Greenroom.")
                }
                Toggle(isOn: $coordinator.keepOBSWarm) {
                    SettingLabel(title: "Keep OBS ready in the background",
                                 subtitle: "Start skips OBS\u{2019}s cold launch, and this page can show the real picture. OBS still quits with Greenroom.")
                }
            } header: { Text("Recording") }
        }
        .formStyle(.grouped)
        .onAppear {
            displays = DisplayResolver.connectedDisplays()
            coordinator.startShapePreview()
        }
        .onDisappear { coordinator.stopShapePreview() }
    }

    // MARK: The picture

    /// The live composite when OBS is running, the sketch otherwise, with the
    /// drag layer as a SIBLING of both - never inside the picture, which
    /// refreshes on a timer (DESIGN.md, Affordances).
    private var picture: some View {
        ZStack {
            Group {
                if isLivePreview {
                    LiveCompositePicture(feed: coordinator.shapePreview)
                } else {
                    WebcamShapePreview(shape: coordinator.webcamShape,
                                       geometry: editedGeometry,
                                       mode: editMode)
                }
            }
            .allowsHitTesting(false)   // the layer above owns every gesture

            if isAdjustable {
                GeometryReader { box in
                    BubbleDragLayer(
                        geometry: editedGeometry,
                        mode: editMode,
                        shape: coordinator.webcamShape,
                        canvas: WebcamShapePreview.fittedCanvas(
                            in: box.size, aspect: previewAspect),
                        showsOutline: isLivePreview,
                        onCommit: { coordinator.requestShapeApply() })
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
        .padding(.vertical, 4)
    }

    private var pictureStatus: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(isLivePreview ? Brand.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            Text(isLivePreview
                 ? "Live from OBS. This is the picture the meeting gets."
                 : "A sketch. Turn on \u{201C}Keep OBS ready\u{201D} under Recording to see the real picture here.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if isAdjustable {
                Text("Drag yourself to move, a corner to resize.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Placement

    @ViewBuilder private var placementControls: some View {
        let geometry = editedGeometry.wrappedValue
        let sizeRange = editMode.sizeRange

        if !isCutout {
            LabeledContent("Corner") {
                HStack(spacing: 4) {
                    ForEach(BubbleCorner.allCases) { corner in
                        Button { place(at: corner) } label: {
                            Image(systemName: corner.symbol)
                                .frame(width: 28, height: 20)
                        }
                        .help(corner.label)
                        .accessibilityLabel(corner.label)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }

        percentSlider(isCutout ? "Height" : "Size",
                      value: geometry.size, range: sizeRange) { commit(size: $0) }
        percentSlider("From the right edge",
                      value: geometry.rightInset,
                      range: 0...max(0.05, isCutout ? 0.95 : 1 - geometry.size)) { commit(rightInset: $0) }
        if !isCutout {
            percentSlider("From the bottom edge",
                          value: geometry.bottomInset, range: 0...0.8) { commit(bottomInset: $0) }
        }

        HStack {
            Text(isCutout
                 ? "A cutout always stands on the bottom edge, so it rises from the screen instead of floating."
                 : "Arrow keys nudge the selected bubble by 0.1%, \u{21E7} arrow by 1%.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Reset") {
                coordinator.resetBubbleLayout()
                coordinator.requestShapeApply()
            }
            .disabled(coordinator.bubbleIsAtDefault)
        }
    }

    /// A slider with its value beside it. Live while dragging: the coordinator
    /// coalesces the stream into one re-layout.
    private func percentSlider(_ title: String, value: Double, range: ClosedRange<Double>,
                               set: @escaping (Double) -> Void) -> some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) },
                                      set: set),
                       in: range)
                    .frame(minWidth: 180)
                Text("\(Int((value * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }

    /// One write path for every placement control, so clamping and the OBS
    /// re-place happen in exactly one place.
    private func commit(size: Double? = nil, rightInset: Double? = nil,
                        bottomInset: Double? = nil) {
        var next = editedGeometry.wrappedValue
        if let size { next.size = size }
        if let rightInset { next.rightInset = rightInset }
        if let bottomInset { next.bottomInset = bottomInset }
        // The coordinator's didSet clamps every one of these.
        editedGeometry.wrappedValue = next
        coordinator.requestShapeApply()
    }

    /// Puts the bubble in a corner with the shipped margins. The bubble's
    /// height as a fraction of the canvas depends on both aspects, so it is
    /// worked out from the picture actually showing.
    private func place(at corner: BubbleCorner) {
        let shipped = GreenroomScene.BubbleLayout()
        let size = coordinator.bubbleWidthFraction
        let canvasAspect = previewAspect.width / max(previewAspect.height, 1)
        let boxHeight = size * canvasAspect / editMode.aspect
        let right = corner.isRight ? shipped.rightInset : 1 - size - shipped.rightInset
        let bottom = corner.isBottom ? shipped.bottomInset : 1 - boxHeight - shipped.bottomInset
        commit(rightInset: max(0, right), bottomInset: max(0, bottom))
    }

    private var shapeCaption: String {
        switch coordinator.webcamShape {
        case .square, .roundedRectangle:
            return "Your camera in a box over what you share. Drag it anywhere, or pick a corner below."
        case .circle:
            return "Your camera cropped to a circle over what you share. Drag it anywhere, or pick a corner below."
        case .cutout:
            return coordinator.backgroundRemoval == .automatic
                ? "You, without your background, standing on the bottom edge of the picture. Greenroom finds you in the camera and removes the rest; no green screen needed."
                : "You, without your background, standing on the bottom edge of the picture. OBS keys out the green screen behind you."
        case .presenterLarge:
            return coordinator.backgroundRemoval == .automatic
                ? "What you share becomes a rounded panel and you stand beside it at full height, like macOS Presenter Overlay. No green screen needed."
                : "What you share becomes a rounded panel and you stand beside it at full height, like macOS Presenter Overlay. OBS keys out the green screen behind you."
        }
    }
}

/// The live composite, observing the frame feed and nothing else, so a new
/// frame redraws this picture and only this picture.
private struct LiveCompositePicture: View {
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

private enum BubbleCorner: CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: Self { self }
    var isRight: Bool { self == .topRight || self == .bottomRight }
    var isBottom: Bool { self == .bottomLeft || self == .bottomRight }
    var symbol: String {
        switch self {
        case .topLeft: return "arrow.up.left"
        case .topRight: return "arrow.up.right"
        case .bottomLeft: return "arrow.down.left"
        case .bottomRight: return "arrow.down.right"
        }
    }
    var label: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}

/// The five looks as cards you can see, instead of five words in a
/// segmented control. Each card sketches the look; the two that remove your
/// background say so on the card, and say "Green screen" when that is how
/// background removal is set, before they are picked rather than after.
private struct ShapeCardPicker: View {
    @Binding var selection: WebcamShape
    /// Background removal is set to a real green screen, so the looks that
    /// remove the background need one.
    var needsGreenScreen: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(WebcamShape.allCases) { shape in
                card(shape)
            }
        }
        .padding(.vertical, 4)
    }

    private func card(_ shape: WebcamShape) -> some View {
        let selected = shape == selection
        return Button { selection = shape } label: {
            VStack(spacing: 8) {
                ShapeGlyph(shape: shape, highlighted: selected)
                    .frame(height: 52)
                Text(shape.label)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Text(shape.usesChromaKey ? (needsGreenScreen ? "Green screen" : "No background") : " ")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Brand.green.opacity(0.12) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Brand.green : Color.secondary.opacity(0.25),
                              lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(shape.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A thumbnail of a look: the shared screen as a grey panel, the person in
/// the accent colour.
private struct ShapeGlyph: View {
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

/// The drag and resize affordance for the webcam's placement, over whichever
/// picture is showing.
///
/// This used to live inside `WebcamShapePreview`, which meant it existed only on
/// the schematic. The moment OBS went warm the live composite replaced that
/// schematic - the better picture, so it should win - and took the only
/// draggable bubble with it, while the caption underneath went on telling the
/// teacher to drag something that was no longer on screen. Since OBS is warm for
/// anyone who has run a class today, that was very nearly always.
///
/// The interaction belongs to the setting, not to one of the two ways of drawing
/// it. So it is a layer now, and both pictures wear it.
struct BubbleDragLayer: View {

    /// What the layer edits, in canvas fractions.
    ///
    /// One struct, two shapes. `size` is a bubble's width as a fraction of
    /// canvas WIDTH, but a cutout's height as a fraction of canvas HEIGHT -
    /// a cutout keeps the camera's real aspect, so no single width describes
    /// it. `Mode` says which is meant.
    struct Geometry: Equatable {
        var size: Double
        var rightInset: Double
        var bottomInset: Double
    }

    /// What the shape allows to be changed.
    enum Mode: Equatable {
        /// Moves in both axes, resizes from any corner. `aspect` is the box's
        /// width over its height: 1 for a circle, whose camera is cropped
        /// square ahead of the mask, and the camera's own aspect for the
        /// rectangular shapes, which keep their full frame. Matching
        /// GreenroomScene here is the point - a square box drawn over a 16:9
        /// bubble is what made the corner look unreachable.
        case bubble(aspect: Double)
        /// The camera's real aspect, bottom edge pinned flush to the canvas.
        /// Horizontal position and height only: lifting a cutout off the bottom
        /// leaves the keyed person hovering above nothing, which is the bug the
        /// comment on `GreenroomScene.layoutCutout` records being found in use.
        case cutout(aspect: Double)

        var pinsBottom: Bool {
            if case .cutout = self { return true }
            return false
        }
        /// Cutout's floor is high on purpose: too small a frame was the other
        /// reason it stopped reusing the bubble box, because a raised hand left
        /// the frame and clipped.
        var sizeRange: ClosedRange<Double> {
            switch self {
            case .bubble: return 0.08...0.6
            case .cutout: return 0.3...1.0
            }
        }
        /// Box width over height.
        var aspect: Double {
            switch self {
            case .bubble(let value), .cutout(let value):
                return value.isFinite && value > 0 ? value : 1
            }
        }
        var corners: [Corner] {
            pinsBottom ? [.topLeft, .topRight] : Corner.allCases
        }
    }

    enum Corner: CaseIterable, Hashable { case topLeft, topRight, bottomLeft, bottomRight }
    private enum Guide: Hashable { case right, bottom }

    @Binding var geometry: Geometry
    let mode: Mode
    let shape: WebcamShape
    /// The picture's real rect inside the space this layer was given.
    let canvas: CGRect
    /// Drawn over the live composite, where nothing else marks the region out as
    /// adjustable. Off over the schematic, which already draws the shape.
    var showsOutline = false
    var onCommit: () -> Void

    @State private var dragStart: Geometry?
    @State private var snappedTo: Set<Guide> = []
    @State private var keyCommit: Task<Void, Never>?
    @FocusState private var focused: Bool

    /// Roughly six points on screen, expressed in canvas fractions so snapping
    /// feels the same however large the preview is.
    private var snapThresholdX: Double { 6 / canvas.width }
    private var snapThresholdY: Double { 6 / canvas.height }

    // MARK: Geometry

    private func box(for value: Geometry) -> CGSize {
        switch mode {
        case .bubble:
            // Sized by WIDTH, matching positionBubble's widthFraction.
            let width = canvas.width * value.size
            return CGSize(width: width, height: width / mode.aspect)
        case .cutout:
            // Sized by HEIGHT, matching layoutCutout.
            let height = canvas.height * value.size
            return CGSize(width: height * mode.aspect, height: height)
        }
    }
    private var box: CGSize { box(for: geometry) }
    private var centre: CGPoint {
        CGPoint(x: canvas.maxX - canvas.width * geometry.rightInset - box.width / 2,
                y: canvas.maxY - canvas.height * geometry.bottomInset - box.height / 2)
    }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Focus lives on a layer UNDER the controls, not on the container
            // around them. `.focusable()` takes focus on click, and on the
            // container that click is the same one the drag needs; underneath,
            // clicking bare canvas arms the keyboard and clicking the bubble
            // drags it. The gestures set focus themselves so the arrows work
            // straight after a drag without a second click.
            Color.clear
                .contentShape(Rectangle())
                .focusable()
                .focused($focused)
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], action: nudge)

            guides

            outline
                .frame(width: box.width, height: box.height)
                // Before .position: that modifier wraps a view in a container
                // filling its parent, so a gesture added afterwards responds
                // across the whole canvas rather than on the thing being moved.
                .contentShape(Rectangle())
                .gesture(moveGesture)
                .onHover { inside in
                    (inside ? NSCursor.openHand : NSCursor.arrow).set()
                }
                .position(centre)

            ForEach(mode.corners, id: \.self) { corner in
                handle(corner)
                    .position(point(of: corner))
            }
        }
        .overlay(alignment: .topLeading) {
            if focused {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .frame(width: canvas.width, height: canvas.height)
                    .offset(x: canvas.minX, y: canvas.minY)
                    .allowsHitTesting(false)
            }
        }
    }

    /// A hairline along an edge the drag has snapped to, so a value that stopped
    /// moving reads as deliberate rather than stuck.
    @ViewBuilder private var guides: some View {
        if snappedTo.contains(.right) {
            Rectangle().fill(Brand.green).frame(width: 1, height: canvas.height)
                .position(x: centre.x + box.width / 2, y: canvas.midY)
        }
        if snappedTo.contains(.bottom) {
            Rectangle().fill(Brand.green).frame(width: canvas.width, height: 1)
                .position(x: canvas.midX, y: centre.y + box.height / 2)
        }
    }

    @ViewBuilder private var outline: some View {
        if showsOutline {
            let clip = clipShape(size: min(box.width, box.height))
            clip.stroke(Brand.green, lineWidth: 2)
                .background(clip.fill(.white.opacity(0.001)))   // hit area, invisible
        } else {
            Color.clear
        }
    }

    private func clipShape(size: CGFloat) -> AnyShape {
        switch shape {
        case .circle: return AnyShape(Circle())
        case .roundedRectangle: return AnyShape(RoundedRectangle(cornerRadius: size * 0.18))
        default: return AnyShape(Rectangle())
        }
    }

    private func point(of corner: Corner) -> CGPoint {
        let half = CGPoint(x: box.width / 2, y: box.height / 2)
        switch corner {
        case .topLeft:     return CGPoint(x: centre.x - half.x, y: centre.y - half.y)
        case .topRight:    return CGPoint(x: centre.x + half.x, y: centre.y - half.y)
        case .bottomLeft:  return CGPoint(x: centre.x - half.x, y: centre.y + half.y)
        case .bottomRight: return CGPoint(x: centre.x + half.x, y: centre.y + half.y)
        }
    }

    /// 12pt of grip inside 28pt of hit area. The grip stays small so it does not
    /// crowd a bubble at its 8% minimum; the target is more than twice that, so
    /// catching it is not a pixel hunt.
    private func handle(_ corner: Corner) -> some View {
        Circle()
            .fill(Brand.green)
            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
            .frame(width: 12, height: 12)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .gesture(resizeGesture(corner))
            .onHover { inside in
                (inside ? NSCursor.crosshair : NSCursor.arrow).set()
            }
            .help("Drag to resize. Hold \u{2325} to ignore the guides.")
    }

    // MARK: Gestures

    /// Insets are measured from the right and bottom edges, so a drag right
    /// DECREASES rightInset. Working in the scene's own coordinates rather than
    /// converting at the end keeps this and OBS in agreement.
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? geometry
                if dragStart == nil { dragStart = start; focused = true }
                let size = box(for: start)
                let widthFraction = size.width / canvas.width
                let heightFraction = size.height / canvas.height

                var right = start.rightInset - value.translation.width / canvas.width
                var bottom = mode.pinsBottom
                    ? 0 : start.bottomInset - value.translation.height / canvas.height
                var hit: Set<Guide> = []

                // NSEvent rather than the gesture, which does not report
                // modifiers. Option means "I want the value between the guides".
                if !NSEvent.modifierFlags.contains(.option) {
                    let snappedRight = snap(right, to: rightTargets(widthFraction: widthFraction),
                                            threshold: snapThresholdX)
                    right = snappedRight.value
                    if snappedRight.hit { hit.insert(.right) }
                    if !mode.pinsBottom {
                        let snappedBottom = snap(bottom, to: [0, 0.02, 0.045, 0.06],
                                                 threshold: snapThresholdY)
                        bottom = snappedBottom.value
                        if snappedBottom.hit { hit.insert(.bottom) }
                    }
                }
                snappedTo = hit
                geometry = Geometry(size: start.size,
                                    rightInset: clamp(right, upper: 1 - widthFraction),
                                    bottomInset: clamp(bottom, upper: 1 - heightFraction))
            }
            .onEnded { _ in
                dragStart = nil
                snappedTo = []
                onCommit()
            }
    }

    /// Resizes about the corner OPPOSITE the handle, so the corner you are not
    /// touching stays where it is. For a cutout the bottom edge is pinned
    /// regardless of which handle is used.
    private func resizeGesture(_ corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? geometry
                if dragStart == nil { dragStart = start; focused = true }
                let startBox = box(for: start)
                let rightEdge = canvas.maxX - canvas.width * start.rightInset
                let bottomEdge = canvas.maxY - canvas.height * start.bottomInset
                let leftEdge = rightEdge - startBox.width
                let topEdge = bottomEdge - startBox.height

                // Growth is the drag projected away from the anchored corner.
                let dx = value.translation.width, dy = value.translation.height
                var growth: CGFloat
                switch corner {
                case .topLeft:     growth = (-dx - dy) / 2
                case .topRight:    growth = ( dx - dy) / 2
                case .bottomLeft:  growth = (-dx + dy) / 2
                case .bottomRight: growth = ( dx + dy) / 2
                }
                // A cutout is sized by HEIGHT, so only the vertical half of the
                // drag means anything to it.
                if mode.pinsBottom { growth = -dy }

                let unit = mode.pinsBottom ? canvas.height : canvas.width
                var size = clamp(start.size + growth / unit,
                                 lower: mode.sizeRange.lowerBound,
                                 upper: mode.sizeRange.upperBound)
                if !NSEvent.modifierFlags.contains(.option) {
                    size = snap(size, to: [0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.6, 0.75],
                                threshold: 6 / unit).value
                }
                let newBox = box(for: Geometry(size: size, rightInset: start.rightInset,
                                               bottomInset: start.bottomInset))

                var newRight = rightEdge
                if corner == .topRight || corner == .bottomRight { newRight = leftEdge + newBox.width }
                var newBottom = bottomEdge
                if !mode.pinsBottom, corner == .bottomLeft || corner == .bottomRight {
                    newBottom = topEdge + newBox.height
                }

                geometry = Geometry(
                    size: size,
                    rightInset: clamp((canvas.maxX - newRight) / canvas.width,
                                      upper: 1 - newBox.width / canvas.width),
                    bottomInset: mode.pinsBottom ? 0
                        : clamp((canvas.maxY - newBottom) / canvas.height,
                                upper: 1 - newBox.height / canvas.height))
            }
            .onEnded { _ in
                dragStart = nil
                onCommit()
            }
    }

    /// Arrow keys, for the precision a pointer cannot reach: 0.1% a press, 1%
    /// with shift. On a 1920-wide canvas that is about 2px and 19px.
    ///
    /// For a cutout, up and down resize instead of moving - the bottom edge is
    /// pinned, so vertical movement is the one thing it has no freedom in, and
    /// height is the one thing left that a key could usefully change.
    private func nudge(_ press: KeyPress) -> KeyPress.Result {
        let step = press.modifiers.contains(.shift) ? 0.01 : 0.001
        var next = geometry
        switch press.key {
        case .leftArrow:  next.rightInset += step
        case .rightArrow: next.rightInset -= step
        case .upArrow:
            if mode.pinsBottom { next.size += step } else { next.bottomInset += step }
        case .downArrow:
            if mode.pinsBottom { next.size -= step } else { next.bottomInset -= step }
        default: return .ignored
        }
        let sized = box(for: next)
        next.size = clamp(next.size, lower: mode.sizeRange.lowerBound,
                          upper: mode.sizeRange.upperBound)
        next.rightInset = clamp(next.rightInset, upper: 1 - sized.width / canvas.width)
        next.bottomInset = mode.pinsBottom
            ? 0 : clamp(next.bottomInset, upper: 1 - sized.height / canvas.height)
        geometry = next

        // Key repeat fires far faster than OBS wants to be asked to re-place a
        // source, so the commit waits for the keyboard to go quiet.
        keyCommit?.cancel()
        keyCommit = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            onCommit()
        }
        return .handled
    }

    // MARK: Numbers

    /// Insets worth stopping on: the canvas edges, the values the app ships
    /// with, and dead centre.
    private func rightTargets(widthFraction: Double) -> [Double] {
        [0, 0.02, 0.045, 0.06, (1 - widthFraction) / 2, 1 - widthFraction]
    }

    private func snap(_ value: Double, to targets: [Double],
                      threshold: Double) -> (value: Double, hit: Bool) {
        guard let best = targets.min(by: { abs($0 - value) < abs($1 - value) }),
              abs(best - value) < threshold else { return (value, false) }
        return (best, true)
    }

    private func clamp(_ value: Double, lower: Double = 0, upper: Double) -> Double {
        min(max(value, lower), max(lower, upper))
    }
}

/// A miniature of what the virtual camera will actually send for the chosen
/// shape: the shared screen, with "you" composited the way OBS will do it -
/// bubble in the corner, keyed cutout, or the Presenter panel arrangement.
/// Mirrors the geometry in GreenroomScene. Internal (not private): the
/// onboarding's "Your setup" step reuses it as a read-only schematic.
///
/// The numbers behind it are the same ones GreenroomScene sends to OBS, so what
/// is dragged here is literally the scene transform rather than a picture of one.
struct WebcamShapePreview: View {
    let shape: WebcamShape
    /// Where to DRAW the webcam. Nil falls back to the shipped defaults, which
    /// is what the onboarding screen wants. This view no longer owns any
    /// interaction: `BubbleDragLayer` is hoisted alongside it in Settings, so a
    /// live frame arriving cannot tear a drag down. See the note there.
    var geometry: Binding<BubbleDragLayer.Geometry>?
    /// Which shape's geometry `geometry` is expressing.
    var mode: BubbleDragLayer.Mode = .bubble(aspect: 1)


    /// A chroma-key green screen, not the brand: DESIGN.md asks for the two
    /// to be named apart even though they share a value.
    private static let chromaGreen = Color(red: 0.373, green: 0.659, blue: 0.235)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                // The canvas - only visible around the Presenter panel.
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.82))

                if shape.isPresenterStyle {
                    screenPanel(cornerRadius: 7)
                        .frame(width: w * 0.78, height: h * 0.78)
                        .position(x: w - w * 0.025 - (w * 0.78) / 2, y: h / 2)
                    person(height: h * 1.1)
                        .position(x: w * 0.24, y: h - (h * 1.1) / 2 + h * 0.04)
                } else {
                    screenPanel(cornerRadius: 8)
                        .frame(width: w, height: h)
                        .position(x: w / 2, y: h / 2)
                    if shape == .cutout {
                        // Flush with the bottom edge, like the real scene - the
                        // person rises from the screen edge, no float. Height and
                        // horizontal position now come from the stored geometry
                        // rather than being guessed, so the schematic and OBS
                        // agree the way the bubble path already did.
                        let live = geometry?.wrappedValue
                            ?? .init(size: 0.5, rightInset: 0.02, bottomInset: 0)
                        let figure = h * live.size
                        let aspect: CGFloat = {
                            if case .cutout(let value) = mode { return value }
                            return 16.0 / 9.0
                        }()
                        let frameWidth = figure * aspect
                        person(height: figure)
                            .position(x: w - w * live.rightInset - frameWidth / 2,
                                      y: h - figure / 2)
                    } else {
                        // Sized off the WIDTH, matching positionBubble in
                        // GreenroomScene - the bubble is a square whose side is a
                        // fraction of canvas width, not height.
                        let live = geometry?.wrappedValue
                            ?? .init(size: 0.24, rightInset: 0.045, bottomInset: 0.06)
                        let bubbleWidth = w * live.size
                        let bubbleHeight = bubbleWidth / mode.aspect
                        let centreX = w - w * live.rightInset - bubbleWidth / 2
                        let centreY = h - h * live.bottomInset - bubbleHeight / 2
                        bubble(width: bubbleWidth, height: bubbleHeight)
                            .position(x: centreX, y: centreY)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .animation(.snappy(duration: 0.25), value: shape)
    }

    /// Where a `scaledToFit` picture of `aspect` actually lands inside `box`.
    ///
    /// The bubble's fractions are relative to the OBS CANVAS, not to the box the
    /// canvas was placed in, and a fitted image is usually narrower than its
    /// container. Measuring against the container would put the drag target a
    /// little to the right of the bubble the teacher can see.
    static func fittedCanvas(in box: CGSize, aspect: CGSize) -> CGRect {
        guard aspect.width > 0, aspect.height > 0, box.width > 0, box.height > 0 else {
            return CGRect(origin: .zero, size: box)
        }
        let ratio = aspect.width / aspect.height
        let size = box.width / box.height > ratio
            ? CGSize(width: box.height * ratio, height: box.height)
            : CGSize(width: box.width, height: box.width / ratio)
        return CGRect(x: (box.width - size.width) / 2,
                      y: (box.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// The shared screen, mocked as a document.
    private func screenPanel(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                VStack(alignment: .leading, spacing: 7) {
                    bar(width: 0.42, emphasis: true)
                    bar(width: 0.9)
                    bar(width: 0.84)
                    bar(width: 0.88)
                    bar(width: 0.58)
                    bar(width: 0.86)
                }
                .padding(14),
                alignment: .topLeading
            )
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.separator, lineWidth: 1))
    }

    private func bar(width fraction: CGFloat, emphasis: Bool = false) -> some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 2)
                .fill(emphasis ? Color.secondary.opacity(0.55) : Color.secondary.opacity(0.22))
                .frame(width: geo.size.width * fraction)
        }
        .frame(height: 7)
    }

    /// "You" - keyed, no background.
    private func person(height: CGFloat) -> some View {
        Image(systemName: "person.fill")
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .foregroundStyle(Self.chromaGreen.gradient)
    }

    /// "You" in a corner bubble - the webcam frame, background included.
    ///
    /// Drawn at the shape's real aspect, not always square: the circle's camera
    /// is cropped square before masking, the rectangular shapes keep their full
    /// 16:9 frame, and a schematic that showed both as squares was the reason
    /// the settings preview disagreed with the composite.
    private func bubble(width: CGFloat, height: CGFloat) -> some View {
        let clip: AnyShape
        switch shape {
        case .circle: clip = AnyShape(Circle())
        case .roundedRectangle:
            clip = AnyShape(RoundedRectangle(cornerRadius: min(width, height) * 0.18))
        default: clip = AnyShape(Rectangle())
        }
        return ZStack {
            clip.fill(Self.chromaGreen.opacity(0.22))
            Image(systemName: "person.fill")
                .resizable()
                .scaledToFit()
                .frame(height: height * 0.62)
                .foregroundStyle(Self.chromaGreen.gradient)
                .offset(y: height * 0.12)
        }
        .frame(width: width, height: height)
        .clipShape(clip)
        .overlay(clip.stroke(Self.chromaGreen.opacity(0.7), lineWidth: 1.5))
    }
}

/// The generalized main-pane + side-column arrangement: pick any app for
/// the main pane, choose how much of the screen it takes, and toggle what
/// fills the leftover column - with a live schematic of the result.
/// What can hold keyboard focus in this tab.
///
/// Exists so that NOTHING does by default. The website field was the tab's only
/// text field, so SwiftUI made it the initial first responder - and macOS Tab
/// moves between text fields, of which there was exactly one, so focus could not
/// be moved off it at all. Every keystroke went into it, which is how a control
/// character ended up in a saved URL.
private enum LayoutSettingsFocus: Hashable {
    case websiteURL
}

/// Re-draws its content whenever the director or the probe publishes.
///
/// Both are ObservableObjects owned by the coordinator, and SwiftUI does not
/// see through one observable to another: reading `coordinator.cameraDirector
/// .sight` subscribes to the coordinator, which never changes when the sight
/// does. So the angle and the switch countdown only moved when something else
/// happened to redraw the window. Observing the two directly fixes that
/// without making the whole coordinator republish three times a second.
private struct LiveReadings<Content: View>: View {
    @ObservedObject var director: CameraDirector
    @ObservedObject var probe: CameraProbe
    @ViewBuilder var content: () -> Content

    var body: some View { content() }
}

/// Setting up the two-camera cut.
///
/// The hard part of this feature is not the software, it is aiming a camera,
/// and that cannot be done blind. So the angle this camera currently reads is
/// on screen the whole time the tab is open - move the camera, watch the
/// number fall. Nothing cuts while you are in here; see
/// CameraDirector.startObserving.
private struct CameraSwitchSection: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @State private var cameras: [LocalDeviceResolver.Camera] = []
    /// Which camera the preview and the angle readout are currently on.
    @State private var aiming: String?

    private var settings: Binding<CameraDirectorSettings> { $coordinator.cameraDirectorSettings }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: settings.enabled) {
                SettingLabel(title: "Cut between cameras as you turn",
                             subtitle: "For two monitors. Put a camera on each, and the class sees whichever one you are facing instead of the side of your head.")
            }

            // Shown whether or not switching is on, like the rest of Settings.
            // Choosing and aiming the cameras stays live - it is the setup a
            // teacher does BEFORE trusting the feature, and the angle readout
            // is how they check it - while the two settings that only shape a
            // cut grey out until there are cuts to shape.
            LiveReadings(director: coordinator.cameraDirector, probe: coordinator.cameraProbe) {
                chooser
            }
            Group {
                dwell
                transition
            }
            .disabled(!coordinator.cameraDirectorSettings.enabled)
            LiveReadings(director: coordinator.cameraDirector, probe: coordinator.cameraProbe) {
                readout
            }
        }
        .onAppear { cameras = LocalDeviceResolver.availableCameras() }
        .onDisappear {
            // A settings window left open would otherwise hold a camera - and
            // its light on - for as long as the app ran.
            coordinator.stopAiming()
            aiming = nil
        }
    }

    // MARK: Which cameras, and in what order

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CAMERAS, IN ORDER \u{00B7} A SESSION STARTS ON THE FIRST")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(.tertiary)

            if cameras.count < 2 {
                Text("Only one camera is plugged in, so there is nothing to cut to. Your iPhone counts \u{2014} put it on the other monitor and it appears here as a camera.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(cameras) { camera in
                let position = coordinator.cameraDirectorSettings.cameraUIDs.firstIndex(of: camera.id)
                Toggle(isOn: Binding(
                    get: { position != nil },
                    set: { wanted in toggle(camera, on: wanted) })) {
                    HStack(spacing: 8) {
                        // The order is the whole point, so it is a number
                        // rather than a checkmark: "which one do I start on"
                        // is the question a teacher actually has.
                        Text(position.map { "\($0 + 1)" } ?? "\u{2013}")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(position == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Brand.text))
                            .frame(width: 14, alignment: .trailing)
                        Text(camera.name)
                        if coordinator.cameraDirector.liveCameraName == camera.name {
                            Text("LIVE")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Brand.fill, in: Capsule())
                        }
                        Spacer(minLength: 8)
                        // Aiming the second camera is the setup task, and the
                        // angle below reports whichever camera OBS is on. So
                        // there has to be a way to put it on this one.
                        if !coordinator.virtualCamActive {
                            Button(aiming == camera.id ? "Looking\u{2026}" : "Aim this one") {
                                aiming = camera.id
                                coordinator.aimCamera(uid: camera.id)
                            }
                            .controlSize(.small)
                            .disabled(aiming == camera.id)
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }
            Button("Refresh the list") { cameras = LocalDeviceResolver.availableCameras() }
                .controlSize(.small)
        }
    }

    /// Ticking a camera appends it, so the order follows the order they were
    /// chosen in. That makes "the first one" something the teacher decided
    /// rather than something the device enumeration decided for them.
    private var aimingName: String? {
        aiming.flatMap { uid in cameras.first { $0.id == uid }?.name }
    }

    /// The live reading. During a class it is the director's, because the
    /// director owns the cameras then; otherwise it is the probe's.
    private var sight: CameraSight {
        coordinator.virtualCamActive ? coordinator.cameraDirector.sight : coordinator.cameraProbe.sight
    }

    private func toggle(_ camera: LocalDeviceResolver.Camera, on: Bool) {
        var uids = coordinator.cameraDirectorSettings.cameraUIDs
        if on {
            guard !uids.contains(camera.id) else { return }
            uids.append(camera.id)
        } else {
            uids.removeAll { $0 == camera.id }
        }
        coordinator.cameraDirectorSettings.cameraUIDs = uids
    }

    // MARK: How patient it is

    private var dwell: some View {
        HStack(spacing: 10) {
            Text("Cut after").font(.callout)
            Slider(value: settings.dwellSeconds, in: 0.5...6, step: 0.5)
                .frame(width: 180)
            Text(String(format: "%.1fs", coordinator.cameraDirectorSettings.dwellSeconds))
                .font(.system(size: 12, design: .monospaced))
                .monospacedDigit()
                .frame(width: 42, alignment: .leading)
            Text("facing another camera")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: What the class sees

    /// Every camera is already open, so a cut has no hitch in it either way;
    /// this is only taste. Applies live, from the next switch.
    private var transition: some View {
        Picker(selection: settings.transition) {
            ForEach(CameraTransition.allCases) { style in
                Text(style.label).tag(style)
            }
        } label: {
            SettingLabel(title: "When it switches",
                         subtitle: "A cut is instant. A crossfade dissolves over half a second.")
        }
        .pickerStyle(.segmented)
    }

    // MARK: Proof that it is working

    /// The number that makes this setup-able.
    ///
    /// Aim the camera, read the angle, aim again. Below the threshold it is
    /// looking at you; above it, this camera has lost you, and another one
    /// that has you face-on would take over. Without this a
    /// teacher is guessing, and the first thing they would do is guess wrong
    /// and decide the feature is broken.
    private var readout: some View {
        let threshold = coordinator.cameraDirectorSettings.awayDegrees
        let degrees = sight.degrees
        let here = (degrees ?? .infinity) <= threshold
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(degrees.map { "\(Int($0.rounded()))\u{00B0}" } ?? "\u{2014}")
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(here ? AnyShapeStyle(Brand.text) : AnyShapeStyle(.secondary))
                    .frame(width: 60, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            // What the switch is decided on: every camera's angle, side by
            // side. The single number above is the live camera alone, which
            // cannot say why the shot moved - the comparison can. Lower wins,
            // once it is clearly lower for the whole delay.
            if coordinator.virtualCamActive, coordinator.cameraDirector.isRunning {
                comparison
            }
            // The same countdown the self view shows, for setting the dwell
            // by feel: drag the slider, turn, watch how long it takes.
            if coordinator.virtualCamActive, let pending = coordinator.cameraDirector.pendingSwitch {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: pending.progress)
                        .progressViewStyle(.linear)
                        .tint(Brand.green)
                        .animation(.linear(duration: CameraDirector.readingSeconds), value: pending.progress)
                    Text("Switching to \(pending.cameraName)\u{2026}")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if coordinator.virtualCamActive, coordinator.cameraDirector.cuts > 0 {
                Text("\(coordinator.cameraDirector.cuts) cut\(coordinator.cameraDirector.cuts == 1 ? "" : "s") this session.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var comparison: some View {
        let director = coordinator.cameraDirector
        let names = director.cameraNamesInOrder
        let angles = director.angles
        let best = angles.enumerated()
            .compactMap { index, angle in angle.map { (index, $0) } }
            .min { $0.1 < $1.1 }?.0
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                let angle = angles.indices.contains(index) ? angles[index] : nil
                HStack(spacing: 8) {
                    Text(angle.map { "\(Int($0.rounded()))\u{00B0}" } ?? "\u{2014}")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(index == best ? AnyShapeStyle(Brand.text) : AnyShapeStyle(.secondary))
                        .frame(width: 40, alignment: .leading)
                    Text(name).font(.caption).lineLimit(1)
                    if index == director.liveSlot {
                        Text("LIVE")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Brand.fill, in: Capsule())
                    }
                    Spacer()
                }
            }
            Text("Lower is more head-on. The class gets whichever camera is clearly lower for the whole delay.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One line per state, and never the wrong one.
    ///
    /// The first version printed "No face in this camera right now" whenever
    /// the angle was missing - including when nothing was looking at all,
    /// which is what a reader saw while sitting in front of their own camera.
    /// Every branch here is a different thing to DO about it.
    private var headline: String {
        switch sight {
        case .idle:
            return aiming == nil
                ? "Press \u{201C}Aim this one\u{201D} on a camera to see the angle it reads you at."
                : "Opening the camera\u{2026}"
        case .noPicture(let why):
            return why
        case .noFace:
            return "A picture, but nobody in it."
        case .noAngle:
            return "Found a face, but couldn\u{2019}t measure which way it is turned."
        case .seen(let degrees):
            return degrees <= coordinator.cameraDirectorSettings.awayDegrees
                ? "Looking at this camera."
                : "Turned away from this camera. In a class, a camera that sees you face-on would take over."
        }
    }

    private var detail: String {
        if coordinator.virtualCamActive {
            return "Measured through OBS while the class runs."
        }
        guard let aimingName else {
            return "Nothing is looking through a camera yet."
        }
        return "Looking through \(aimingName). Move it and watch this change."
    }
}

private struct LayoutSettingsTab: View {
    /// Half, two thirds, three quarters - what the fixed widths used to be.
    private static let widthPresets: [Double] = [0.5, 2.0 / 3.0, 0.75]
    @EnvironmentObject private var coordinator: CoordinatorController
    @FocusState private var focus: LayoutSettingsFocus?
    @State private var apps: [AppInfo] = []
    @State private var displays: [DisplayInfo] = DisplayResolver.connectedDisplays()
    @State private var hasAccessibilityPermission = AppWindowManager.hasAccessibilityPermission

    // AXIsProcessTrusted() has no change notification, so poll it while
    // the tab is visible - the warning below disappears on its own once
    // the user flips the switch in System Settings.
    private let permissionTick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Picker("Main app", selection: $coordinator.mainAppBundleID) {
                ForEach(apps) { app in
                    HStack(spacing: 6) {
                        if let icon = AppCatalog.icon(forBundleID: app.bundleID) {
                            Image(nsImage: sized(icon))
                        }
                        Text(app.name)
                    }
                    .tag(app.bundleID)
                }
            }

            if AppCatalog.isBrowser(coordinator.mainAppBundleID) {
                // .roundedBorder, not the Form default borderless: the
                // borderless field rendered as an apparently-dead empty
                // row (macOS hides the prompt until focus), so nothing
                // signalled "type a URL here" (design-review F2).
                TextField("Open website", text: $coordinator.mainAppURL, prompt: Text("e.g. docs.google.com"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .websiteURL)
            }

            if AppCatalog.isBuiltInBrowser(coordinator.mainAppBundleID) {
                Text("Greenroom\u{2019}s own browser: tabs, find in page, local history, no permissions to grant. Pick Chrome above if you need extensions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(isOn: $coordinator.browserRestoresTabs) {
                    SettingLabel(title: "Reopen last session\u{2019}s tabs on Start",
                                 subtitle: "Yesterday\u{2019}s tabs come back beside the website above.")
                }
                Toggle(isOn: $coordinator.browserSearchSuggestions) {
                    SettingLabel(title: "Suggest searches as you type",
                                 subtitle: "Sends what you type to Google for completions. Off: history only, nothing leaves until Return.")
                }
                Toggle(isOn: $coordinator.browserClosesOnStop) {
                    SettingLabel(title: "Close the browser window when the session ends",
                                 subtitle: "Tabs are kept for the next Start.")
                }
            } else if AppCatalog.isBrowser(coordinator.mainAppBundleID) {
                // The same switch for an outside browser, which Greenroom
                // can close only because it made that window itself.
                Toggle(isOn: $coordinator.browserClosesOnStop) {
                    SettingLabel(title: "Close the window Start opened when the session ends",
                                 subtitle: "Only that window. Your other \(AppCatalog.displayName(forBundleID: coordinator.mainAppBundleID) ?? "browser") windows and tabs stay open. Works with Chrome and browsers built like it (Ulaa, Edge, Brave).")
                }
            }

            if needsAccessibility && !hasAccessibilityPermission {
                accessibilityWarning
            }

            Section {
                Picker("Main pane side", selection: $coordinator.workspaceLayout.mainOnLeft) {
                    Text("Left").tag(true)
                    Text("Right").tag(false)
                }
                .pickerStyle(.segmented)

                // Presets AND the drag, not one instead of the other. The fixed
                // widths were replaced by the drag handles in August, which made
                // any width possible and the three common ones fiddly: getting
                // exactly half by hand is a hunt for a pixel. A width the handles
                // left somewhere else simply has no segment lit.
                Picker("Main pane width", selection: Binding(
                    get: { Self.widthPresets.first { abs($0 - coordinator.workspaceLayout.clampedMainFraction) < 0.005 } ?? -1 },
                    set: { fraction in
                        withAnimation(.snappy(duration: 0.25)) {
                            coordinator.workspaceLayout.mainFraction = fraction
                        }
                    })) {
                    Text("\u{00BD}").tag(0.5)
                    Text("\u{2154}").tag(2.0 / 3.0)
                    Text("\u{00BE}").tag(0.75)
                }
                .pickerStyle(.segmented)

                LayoutSchematicView(layout: $coordinator.workspaceLayout,
                                    appName: coordinator.mainAppDisplayName,
                                    appIcon: AppCatalog.icon(forBundleID: coordinator.mainAppBundleID))
                    .frame(height: 140)
                    .padding(.vertical, 4)

                Text("Pick a width or drag the handles to size the panes. A live session re-tiles as you change it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Side column") {
                Toggle("Zoom meeting tile", isOn: $coordinator.workspaceLayout.sideShowsZoomTile)
                Toggle("Chat window", isOn: $coordinator.workspaceLayout.sideShowsChat)
                // Tile-vs-chat balance is set by dragging the handle in the
                // preview above - the old slider duplicated it.
            }

            Section("Meeting view") {
                Toggle(isOn: $coordinator.hideSelfView) {
                    SettingLabel(title: "Hide my own video tile",
                                 subtitle: "Only changes what you see; the class still gets your video.")
                }
                Toggle(isOn: $coordinator.speakerTileShortcutEnabled) {
                    SettingLabel(title: "Quick-hide mode",
                                 subtitle: "Sessions start with the speaker hidden and the chat full height; \u{2325}\u{2318}Z shows it.")
                }
            }

            Section("Privacy") {
                Toggle(isOn: $coordinator.analyticsEnabled) {
                    SettingLabel(title: "Send anonymous usage analytics",
                                 subtitle: "Counts and timings only. Never names, meeting IDs, addresses or chat.")
                }
            }

            Section("Second display") {
                Toggle(isOn: $coordinator.peopleViewOnStart) {
                    SettingLabel(title: "Show the participant view on another display",
                                 subtitle: coordinator.customUIMode
                                     ? "Every student and the host controls, full-screen on your reference monitor."
                                     : "Zoom\u{2019}s participant grid, full-screen on your reference monitor.")
                }

                // Greyed out rather than hidden while the view is off, like the
                // rest of Settings. The main-display option stays hidden with
                // Zoom's own grid, because there it does not exist at all.
                if coordinator.customUIMode {
                    Toggle(isOn: $coordinator.participantPanelOnMainDisplay) {
                        SettingLabel(title: "Allow it on this screen when no second display is connected",
                                     subtitle: "It is large and covers the workspace; for trying the panel without a second monitor.")
                    }
                    .disabled(!coordinator.peopleViewOnStart)
                }

                Group {
                    Picker("Participant-view display", selection: $coordinator.peopleViewDisplayUUID) {
                        Text("Automatic (a non-main display)").tag("")
                        ForEach(displays) { display in
                            Text(display.label).tag(display.id)
                        }
                        // Keep a saved-but-disconnected choice visible/valid.
                        if !coordinator.peopleViewDisplayUUID.isEmpty,
                           !displays.contains(where: { $0.id == coordinator.peopleViewDisplayUUID }) {
                            Text("Saved display (not connected)").tag(coordinator.peopleViewDisplayUUID)
                        }
                    }

                    Text(displayHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!coordinator.peopleViewOnStart)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                displays = DisplayResolver.connectedDisplays()
            }

            Toggle(isOn: $coordinator.mainAppOnStart) {
                SettingLabel(title: "Open the main app automatically on Start",
                             subtitle: "The Zoom tile and chat take whatever the main pane leaves free.")
            }
        }
        .formStyle(.grouped)
        // Nothing focused when the tab opens. Without this the website field
        // claimed focus immediately and could not be escaped, because macOS Tab
        // cycles text fields and this tab has only one.
        .defaultFocus($focus, nil)
        // Escape always releases it, which is the habit people already have and
        // the only way out when Tab has nowhere to go.
        .onExitCommand { focus = nil }
        .onAppear {
            apps = pickerApps()
            displays = DisplayResolver.connectedDisplays()
            focus = nil
        }
        .onReceive(permissionTick) { _ in
            hasAccessibilityPermission = AppWindowManager.hasAccessibilityPermission
        }
    }

    /// Caption under the participant-view display picker, adapting to how
    /// many displays are actually connected.
    private var displayHelp: String {
        if displays.count <= 1 {
            return "Only your main display is connected right now \u{2014} plug in your reference display and it will appear here. Mirrored displays show as their main and aren't listed separately, so pick your separate, extended monitor."
        }
        return "Pick your reference monitor. Mirrored displays (e.g. a class projector matching your main screen) show as their main and aren't listed separately \u{2014} choose the separate, extended display. \u{201C}Automatic\u{201D} uses the first non-main display."
    }

    /// Browsers are driven through the Chromium AppleScript dictionary
    /// (per-app Automation permission, prompted on first use) - only
    /// non-browser apps need the system-wide Accessibility grant to be
    /// moved. (A non-Chromium browser would fall back to Accessibility
    /// too, but that's rare enough to keep this warning simple.)
    private var needsAccessibility: Bool {
        !AppCatalog.isBrowser(coordinator.mainAppBundleID)
    }

    /// Without this, picking an ungranted app just silently fails to move
    /// its window at Start - say so up front, with a way to fix it.
    private var accessibilityWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 3) {
                Text("Greenroom can't move \(coordinator.mainAppDisplayName)'s window yet.")
                    .font(.callout.weight(.medium))
                Text("Non-browser apps are positioned with the Accessibility API. Allow Greenroom under System Settings \u{2192} Privacy & Security \u{2192} Accessibility \u{2014} until then, \(coordinator.mainAppDisplayName) will open but stay wherever it is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open Settings\u{2026}") {
                AppWindowManager.promptForAccessibilityPermission()
                AppWindowManager.openAccessibilitySettings()
            }
        }
        .padding(10)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Installed + running apps, with the saved choice force-included so
    /// the picker never shows blank if that app has since been removed.
    private func pickerApps() -> [AppInfo] {
        var list = AppCatalog.installedAndRunning()
        if !list.contains(where: { $0.bundleID == coordinator.mainAppBundleID }) {
            list.insert(AppInfo(bundleID: coordinator.mainAppBundleID,
                                name: AppCatalog.displayName(forBundleID: coordinator.mainAppBundleID) ?? coordinator.mainAppBundleID,
                                url: nil),
                        at: 0)
        }
        return list
    }

    /// NSWorkspace icons come at 32pt+; menu rows want 16.
    private func sized(_ icon: NSImage) -> NSImage {
        let copy = icon.copy() as! NSImage
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

/// A miniature live preview of the three panes: the main app's slice, and
/// the side column with the Zoom tile stacked over the chat - everything
/// proportioned exactly as the real layout will be, updating as the
/// controls above change.
/// What the class sees behind the webcam: a whole display, one app or one
/// window. Its own view because the window list has state of its own and
/// refreshes on its own schedule.
private struct ShareTargetSettings: View {
    let displays: [DisplayInfo]
    /// Called after any change, so the live picture can rebuild for it.
    var onChange: () -> Void = {}
    @EnvironmentObject private var coordinator: CoordinatorController
    @State private var apps: [(bundleID: String, name: String)] = []
    @State private var windows: [ShareTarget.Window] = []
    @State private var canSeeTitles = CGPreflightScreenCaptureAccess()

    var body: some View {
        Picker("Share", selection: kind) {
            ForEach(ShareTarget.Kind.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)

        switch coordinator.shareTarget.kind {
        case .display:
            displayPicker(title: "Screen to share")
        case .app:
            appPicker
            displayPicker(title: "Screen it is on")
        case .window:
            windowPicker
        }

        Text(caption)
            .font(.caption)
            .foregroundStyle(.secondary)
            .onAppear(perform: refresh)
            .onChange(of: coordinator.shareTarget) { _ in onChange() }
            .onChange(of: coordinator.screenCaptureDisplayUUID) { _ in onChange() }
    }

    private var caption: String {
        switch coordinator.shareTarget.kind {
        case .display:
            return "The screen your class sees. If it is unplugged at Start, the main display is shared instead."
        case .app:
            return "Only this app\u{2019}s windows are shown; everything else on that screen stays private. During a session, changes apply at the next Start."
        case .window:
            return "Only this window is shown, framed on a dark backdrop. If its title has changed by Start, the app\u{2019}s front window is shared. During a session, changes apply at the next Start."
        }
    }

    private var kind: Binding<ShareTarget.Kind> {
        Binding(
            get: { coordinator.shareTarget.kind },
            set: { coordinator.shareTarget.kind = $0; refresh() })
    }

    private func displayPicker(title: String) -> some View {
        Picker(title, selection: $coordinator.screenCaptureDisplayUUID) {
            Text("Automatic (your main display)").tag("")
            ForEach(displays) { display in
                Text(display.label).tag(display.id)
            }
            // Keep a saved-but-disconnected choice visible and valid,
            // so unplugging a monitor does not silently reset it.
            if !coordinator.screenCaptureDisplayUUID.isEmpty,
               !displays.contains(where: { $0.id == coordinator.screenCaptureDisplayUUID }) {
                Text("Saved display (not connected)").tag(coordinator.screenCaptureDisplayUUID)
            }
        }
    }

    private var appPicker: some View {
        Picker("App", selection: Binding(
            get: { coordinator.shareTarget.appBundleID },
            set: { id in
                coordinator.shareTarget.appBundleID = id
                coordinator.shareTarget.appName = apps.first { $0.bundleID == id }?.name ?? ""
                coordinator.shareTarget.windowTitle = ""
            })) {
            Text("Choose an app").tag("")
            ForEach(apps, id: \.bundleID) { app in
                Text(app.name).tag(app.bundleID)
            }
            // A saved app that is not open stays selectable, for the same
            // reason as a disconnected display.
            let saved = coordinator.shareTarget.appBundleID
            if !saved.isEmpty, !apps.contains(where: { $0.bundleID == saved }) {
                Text("\(coordinator.shareTarget.displayName) (not open)").tag(saved)
            }
        }
    }

    @ViewBuilder
    private var windowPicker: some View {
        let target = coordinator.shareTarget
        let selected = target.appBundleID.isEmpty ? "" : ShareTarget.windowKey(bundleID: target.appBundleID,
                                                                                 title: target.windowTitle)
        HStack {
            Picker("Window", selection: Binding(
                get: { selected },
                set: { key in
                    guard let window = windows.first(where: { $0.key == key }) else { return }
                    coordinator.shareTarget.appBundleID = window.bundleID
                    coordinator.shareTarget.appName = window.appName
                    coordinator.shareTarget.windowTitle = window.title
                })) {
                Text("Choose a window").tag("")
                ForEach(windows) { window in
                    Text(window.title.isEmpty ? window.appName : "\(window.appName) \u{2013} \(window.title)")
                        .tag(window.key)
                }
                if !selected.isEmpty, !windows.contains(where: { $0.key == selected }) {
                    // Not listed under that title, but the app may still be
                    // open - and then Start shares its front window.
                    let open = windows.contains { $0.bundleID == target.appBundleID }
                    let name = target.windowTitle.isEmpty
                        ? target.displayName
                        : "\(target.displayName) \u{2013} \(target.windowTitle)"
                    Text(open ? "\(name) (front window)" : "\(name) (not open)")
                        .tag(selected)
                }
            }
            Button("Refresh", action: refresh)
        }
        if !canSeeTitles {
            HStack {
                Text("Without Screen Recording permission, windows are listed by app only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Allow\u{2026}") {
                    ScreenroomScreenEngine.askForPermission()
                    canSeeTitles = CGPreflightScreenCaptureAccess()
                    refresh()
                }
            }
        }
    }

    /// Without titles every window of an app has the same key, so only the
    /// first (the front one) is listed; picking it shares the front window,
    /// which is what an untitled choice means at Start too.
    private func refresh() {
        apps = ShareTarget.runningApps()
        var seen = Set<String>()
        windows = ShareTarget.windows().filter { seen.insert($0.key).inserted }
        canSeeTitles = CGPreflightScreenCaptureAccess()
    }
}

private struct LayoutSchematicView: View {
    @Binding var layout: WorkspaceLayout
    let appName: String
    let appIcon: NSImage?

    private let spacing: CGFloat = 4
    @State private var draggingSplit = false
    @State private var draggingSlot = false

    var body: some View {
        GeometryReader { geo in
            let fraction = layout.clampedMainFraction
            let mainWidth = (geo.size.width - spacing) * fraction
            let sideWidth = geo.size.width - spacing - mainWidth
            let dividerX = layout.mainOnLeft ? mainWidth + spacing / 2 : sideWidth + spacing / 2
            let sideCenterX = layout.mainOnLeft ? mainWidth + spacing + sideWidth / 2 : sideWidth / 2

            ZStack(alignment: .topLeading) {
                HStack(spacing: spacing) {
                    if layout.mainOnLeft {
                        mainPane.frame(width: mainWidth)
                        sideColumn(height: geo.size.height).frame(width: sideWidth)
                    } else {
                        sideColumn(height: geo.size.height).frame(width: sideWidth)
                        mainPane.frame(width: mainWidth)
                    }
                }

                // Vertical divider: drag to resize main pane vs side column.
                grabber(width: 6, height: 44, active: draggingSplit)
                    .frame(width: 18, height: geo.size.height)
                    .contentShape(Rectangle())
                    .position(x: dividerX, y: geo.size.height / 2)
                    // NSCursor.set() rather than push/pop: the push/pop
                    // stack desynced across enter/exit events and left the
                    // wrong cursor orientation showing (reported live).
                    // Re-set every drag tick too - AppKit resets the cursor
                    // once the pointer leaves the hover area mid-drag.
                    .onHover { inside in
                        (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("schematic"))
                            .onChanged { value in
                                draggingSplit = true
                                NSCursor.resizeLeftRight.set()
                                let raw = Double(value.location.x / geo.size.width)
                                let fraction = layout.mainOnLeft ? raw : 1 - raw
                                layout.mainFraction = min(max(fraction, WorkspaceLayout.minMainFraction),
                                                          WorkspaceLayout.maxMainFraction)
                            }
                            .onEnded { _ in
                                draggingSplit = false
                                NSCursor.arrow.set()
                            }
                    )
                    // Keyboard/VoiceOver path for the mouse-only drag
                    // (Codex design audit #4).
                    .accessibilityElement()
                    .accessibilityLabel("Main pane width")
                    .accessibilityValue("\(Int((layout.clampedMainFraction * 100).rounded())) percent")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment:
                            layout.mainFraction = min(layout.clampedMainFraction + 0.05, WorkspaceLayout.maxMainFraction)
                        case .decrement:
                            layout.mainFraction = max(layout.clampedMainFraction - 0.05, WorkspaceLayout.minMainFraction)
                        @unknown default: break
                        }
                    }

                // Horizontal divider: drag to balance Zoom tile vs chat.
                if layout.sideShowsZoomTile && layout.sideShowsChat {
                    let slotY = (geo.size.height - spacing) * layout.effectiveZoomSlotRatio + spacing / 2
                    grabber(width: 44, height: 6, active: draggingSlot)
                        .frame(width: max(sideWidth - 16, 24), height: 18)
                        .contentShape(Rectangle())
                        .position(x: sideCenterX, y: slotY)
                        .onHover { inside in
                            (inside ? NSCursor.resizeUpDown : NSCursor.arrow).set()
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("schematic"))
                                .onChanged { value in
                                    draggingSlot = true
                                    NSCursor.resizeUpDown.set()
                                    let ratio = Double(value.location.y / geo.size.height)
                                    layout.zoomSlotRatio = min(max(ratio, 0.15), 0.85)
                                }
                                .onEnded { _ in
                                    draggingSlot = false
                                    NSCursor.arrow.set()
                                }
                        )
                        .accessibilityElement()
                        .accessibilityLabel("Zoom tile height")
                        .accessibilityValue("\(Int((layout.effectiveZoomSlotRatio * 100).rounded())) percent")
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: layout.zoomSlotRatio = min(layout.zoomSlotRatio + 0.05, 0.85)
                            case .decrement: layout.zoomSlotRatio = max(layout.zoomSlotRatio - 0.05, 0.15)
                            @unknown default: break
                            }
                        }
                }
            }
            .coordinateSpace(name: "schematic")
        }
        // Snappy preset-style animation for external changes only - never
        // mid-drag, where it would lag the pointer.
        .animation(draggingSplit || draggingSlot ? nil : .snappy(duration: 0.25), value: layout)
    }

    /// Deliberately assertive, not decorative: the handles ARE the width
    /// controls now (the preset picker and slider are gone), so they must
    /// read as grabbable at a glance (design-review F5).
    private func grabber(width: CGFloat, height: CGFloat, active: Bool) -> some View {
        Capsule()
            .fill(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.85)))
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.35), radius: active ? 3 : 1.5)
    }

    private var mainPane: some View {
        pane(tint: .blue) {
            VStack(spacing: 4) {
                if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 24, height: 24)
                }
                Text(appName)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                if draggingSplit {
                    Text("\(Int((layout.clampedMainFraction * 100).rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func sideColumn(height: CGFloat) -> some View {
        VStack(spacing: spacing) {
            if layout.sideShowsZoomTile {
                pane(tint: .indigo) {
                    VStack(spacing: 2) {
                        Label("Zoom", systemImage: "video.fill")
                            .font(.caption2.weight(.medium))
                        if draggingSlot {
                            Text("\(Int((layout.effectiveZoomSlotRatio * 100).rounded()))%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: layout.sideShowsChat
                       ? (height - spacing) * layout.effectiveZoomSlotRatio
                       : nil)
            }
            if layout.sideShowsChat {
                pane(tint: .teal) {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
                        .font(.caption2.weight(.medium))
                }
            }
            if !layout.sideShowsZoomTile && !layout.sideShowsChat {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .overlay(Text("Free").font(.caption2).foregroundStyle(.tertiary))
            }
        }
    }

    private func pane<Content: View>(tint: Color, @ViewBuilder content: () -> Content) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(tint.opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(tint.opacity(0.45), lineWidth: 1)
            )
            .overlay(content().foregroundStyle(tint))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Both Zoom Marketplace apps on one page.
///
/// They were two tabs, Meeting Chat and Start Meeting, named after what each
/// credential unlocks rather than after what it is. Both are Zoom tokens, both
/// come from the same account, and the second tab's own footer had to say "on
/// the same Zoom account as Meeting Chat" - a sentence that exists only
/// because the two were apart. Setting Greenroom up means pasting six values
/// from one place, and it should be one page.
///
/// Two sections, kept separate, because they really are two different
/// Marketplace apps and pretending otherwise would be the opposite mistake:
/// Zoom's headless token grant is exclusive to the Server-to-Server type and
/// the Meeting SDK embed is exclusive to the General App type, so nobody can
/// consolidate them into one set of credentials. Vendor/README.md records the
/// attempt.
private struct ZoomSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController

    var body: some View {
        Form {
            Section {
                TextField("Client ID", text: $coordinator.sdkClientID)
                SecureField("Client Secret", text: $coordinator.sdkClientSecret)
            } header: { Text("Meeting SDK app") } footer: {
                Text("Powers the built-in meeting client and the chat window. Zoom Marketplace \u{2192} General App \u{2192} Features \u{2192} Embed \u{2192} Meeting SDK. Works only in meetings hosted under this Zoom account.")
            }

            Section {
                TextField("Account ID", text: $coordinator.s2sAccountID)
                TextField("Client ID", text: $coordinator.s2sClientID)
                SecureField("Client Secret", text: $coordinator.s2sClientSecret)
            } header: { Text("Server-to-Server OAuth app") } footer: {
                Text("Powers New Meeting and the scheduled list. A second Marketplace app on the same Zoom account. Scopes: meeting:write:meeting:admin, meeting:read:list_meetings:admin, meeting:read:meeting:admin, user:read:token:admin, meeting:update:status:admin. The setup guide (?) walks through it and tests the result.")
            }

            Section {
                Toggle(isOn: $coordinator.useBuiltInClient) {
                    SettingLabel(title: "Use built-in meeting client",
                                 subtitle: "The whole meeting runs inside Greenroom. Off: the Zoom app, with a hidden chat participant.")
                }
                TextField("Your display name", text: $coordinator.userDisplayName)

                Toggle(isOn: $coordinator.customUIMode) {
                    SettingLabel(title: "Custom meeting UI (experimental)",
                                 subtitle: "Greenroom draws the speaker and the participant panel itself. Takes effect after a relaunch.")
                }
                if coordinator.customUIModeNeedsRelaunch {
                    Label("Not active yet \u{2014} quit and reopen Greenroom.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: { Text("In the meeting") } footer: {
                Text("How the meeting appears once it starts. Nothing here needs a credential.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Uploading recordings to YouTube - the one feature that sends class
/// content off the Mac, so it opens on "Do nothing" and every line of copy
/// says where the file goes.
private struct YouTubeSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @State private var connecting = false

    var body: some View {
        Form {
            Section {
                Picker(selection: $coordinator.youtubeUploadMode) {
                    ForEach(YouTubeUploadMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                } label: {
                    SettingLabel(title: "After a recording",
                                 subtitle: "\u{201C}Ask\u{201D} shows one Upload / Not now card. The file stays in Documents/Greenroom either way.")
                }
                Picker(selection: $coordinator.youtubePrivacy) {
                    Text("Unlisted").tag("unlisted")
                    Text("Private").tag("private")
                } label: {
                    SettingLabel(title: "Visibility",
                                 subtitle: coordinator.youtubePrivacy == "private" ? "Only the channel\u{2019}s account can watch." : "Anyone with the link can watch.")
                }
            } header: { Text("Upload") } footer: {
                Text("The one place class content leaves the Mac: the recording, over HTTPS, to the connected channel. Progress is in the menu bar; the link is copied when it finishes.")
            }

            Section {
                TextField("Client ID", text: $coordinator.youtubeClientID)
                SecureField("Client Secret", text: $coordinator.youtubeClientSecret)
                LabeledContent {
                    HStack(spacing: 12) {
                        if coordinator.youtubeConnected {
                            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(Brand.green)
                            Button("Disconnect") { Task { await coordinator.disconnectYouTube() } }
                        } else {
                            Button(connecting ? "Waiting for Google\u{2026}" : "Connect\u{2026}") {
                                connecting = true
                                Task {
                                    await coordinator.connectYouTube()
                                    connecting = false
                                }
                            }
                            .disabled(connecting || coordinator.youtubeClientID.isEmpty || coordinator.youtubeClientSecret.isEmpty)
                        }
                        if coordinator.isUploadingToYouTube {
                            ProgressView().controlSize(.small)
                        }
                    }
                } label: {
                    SettingLabel(title: "Google account",
                                 subtitle: coordinator.youtubeStatus.isEmpty
                                     ? "Signs in once in your browser. Greenroom can upload and edit your own videos, nothing else."
                                     : coordinator.youtubeStatus)
                }
            } header: { Text("Account") } footer: {
                Text("From a Google Cloud OAuth client of type \u{201C}Desktop app\u{201D} with the YouTube Data API v3 enabled. The setup guide (? on the main window) has the clicks; while the Google project is in Testing, the sign-in lasts seven days.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Export/import all of the above as one JSON file - the whole point is
/// setting up a teammate's machine without them ever touching the Zoom
/// Marketplace: send them the app + this file, they import it, done.
private struct TransferSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @State private var statusMessage = ""
    @State private var confirmingExport = false

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    // Confirmation before writing secrets in plaintext - the
                    // risk shouldn't live only in small caption text below
                    // (Codex design audit #6).
                    Button("Export\u{2026}") { confirmingExport = true }
                        .confirmationDialog("This file will contain your Zoom secrets in plain text.",
                                            isPresented: $confirmingExport, titleVisibility: .visible) {
                            Button("Export Plaintext File") { exportSettings() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Hand it over directly (e.g. AirDrop) and delete it after importing.")
                        }
                } label: {
                    SettingLabel(title: "Export settings", subtitle: "One file with every setting, credentials included, in plain text.")
                }
                LabeledContent {
                    Button("Import\u{2026}") { importSettings() }
                } label: {
                    SettingLabel(title: "Import settings", subtitle: "Sets up this Mac from a file a colleague exported.")
                }
            } header: { Text("Transfer") } footer: {
                Text(statusMessage.isEmpty ? "Hand the file over directly (AirDrop) and delete it once imported." : statusMessage)
            }
        }
        .formStyle(.grouped)
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Greenroom Settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try coordinator.exportSettingsData().write(to: url, options: .atomic)
            statusMessage = "Exported to \(url.lastPathComponent)."
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try coordinator.importSettings(from: Data(contentsOf: url))
            statusMessage = "Imported from \(url.lastPathComponent). You can delete that file now."
        } catch {
            statusMessage = "Import failed: \(error.localizedDescription)"
        }
    }
}
