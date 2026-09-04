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

            MeetingSDKSettingsTab()
                .tabItem { Label("Meeting Chat", systemImage: "bubble.left.and.bubble.right.fill") }

            StartMeetingSettingsTab()
                .tabItem { Label("Start Meeting", systemImage: "video.badge.plus") }

            TransferSettingsTab()
                .tabItem { Label("Transfer", systemImage: "square.and.arrow.up.on.square") }
        }
        .frame(width: 760, height: 730)
        // Secrets are loaded lazily (see loadSecretsIfNeeded) - opening
        // Settings is the first moment the fields actually need them.
        .onAppear { coordinator.loadSecretsIfNeeded() }
    }
}

private struct WebcamSettingsTab: View {
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
    private var isLivePreview: Bool { coordinator.shapePreviewFrame != nil }
    /// The aspect the picture on screen is drawn at, so the drag layer measures
    /// against the same rect the teacher is looking at. A value, not the image,
    /// so a new frame with identical dimensions does not invalidate anything.
    private var previewAspect: CGSize {
        coordinator.shapePreviewFrame?.size ?? CGSize(width: 16, height: 10)
    }
    /// Presenter is the one shape with nothing to drag: layoutPresenter rebuilds
    /// the whole scene rather than placing a source, so there is no single
    /// position or size behind it to edit.
    private var isAdjustable: Bool { coordinator.webcamShape != .presenterLarge }

    /// 16:9, matching the fallback GreenroomScene uses when it cannot read the
    /// source dimensions. It would be wrong to take this from
    /// shapePreviewFrame: that is the OBS CANVAS, and what shapes the webcam is
    /// the CAMERA's aspect. The two agree for most cameras, which is exactly
    /// why reading the wrong one would go unnoticed.
    private static let assumedCameraAspect = 16.0 / 9.0

    private var editMode: BubbleDragLayer.Mode {
        if isCutout { return .cutout(aspect: Self.assumedCameraAspect) }
        // Circle crops the camera square before masking, so its box is square.
        // The rectangular shapes keep the full frame, so theirs is not.
        return .bubble(aspect: coordinator.webcamShape.cropsToSquare
                       ? 1 : Self.assumedCameraAspect)
    }

    @EnvironmentObject private var coordinator: CoordinatorController

    var body: some View {
        Form {
            Picker("Bubble shape", selection: $coordinator.webcamShape) {
                ForEach(WebcamShape.allCases) { shape in
                    Text(shape.label).tag(shape)
                }
            }
            .pickerStyle(.segmented)

            // Live preview of the real composite when OBS is warm;
            // schematic fallback otherwise. Shape changes while idle are
            // applied to the warm scene immediately, so the live picture
            // tracks the picker.
            //
            // The drag layer is a SIBLING of the picture, not an overlay on it,
            // and that is load-bearing. shapePreviewFrame is republished every
            // 150ms (see startShapePreview), so anything nested inside the
            // `if let frame` branch is rebuilt about seven times a second -
            // which tore down the layer's @State and any in-flight gesture
            // before a drag could travel more than a few pixels. Out here its
            // identity survives a new frame arriving, so a drag survives too.
            ZStack {
                Group {
                    if let frame = coordinator.shapePreviewFrame {
                        Image(nsImage: frame)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(alignment: .topLeading) {
                                HStack(spacing: 4) {
                                    Circle().fill(.green).frame(width: 6, height: 6)
                                    Text("LIVE").font(.caption2.bold())
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.78), in: Capsule()) // opaque enough over any video frame
                                .foregroundStyle(.white)
                                .padding(6)
                            }
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
                            onCommit: {
                                Task { await coordinator.applyShapeForPreview() }
                            })
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 400)
            .padding(.vertical, 6)
            .onAppear { coordinator.startShapePreview() }
            .onDisappear { coordinator.stopShapePreview() }
            .onChange(of: coordinator.webcamShape) { _ in
                Task { await coordinator.applyShapeForPreview() }
            }

            Text(shapeCaption)
                .font(.caption)
                .foregroundStyle(.secondary)

            // Presenter is the one shape with nothing to place: layoutPresenter
            // rebuilds the whole scene rather than positioning a source.
            if isAdjustable {
                placementControls
            }

            Divider()

            Toggle("Keep the last 5 minutes clippable", isOn: $coordinator.clipBufferEnabled)

            Text("\u{2325}\u{2318}1, \u{2325}\u{2318}2 and \u{2325}\u{2318}5 save the last 1, 2 or 5 minutes as a clip \u{2014} even when you are not recording. Held in memory, about 300MB, and never written to disk unless you press one of those keys. Off: the shortcuts only work while a recording is running.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Start recording automatically with the meeting", isOn: $coordinator.autoRecordOnStart)

            Text("Off: record manually with the Record button or \u{2325}\u{2318}R. Either way, recordings save to Documents/Greenroom and stop safely when the session ends.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Keep OBS ready in the background", isOn: $coordinator.keepOBSWarm)

            Text("Launches OBS with Greenroom and leaves it running between sessions, so Start skips OBS's slow cold launch. OBS still quits when Greenroom quits.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    /// Numbers and a hint, under the preview.
    ///
    /// Dragging is quick but never exact, and the values live as canvas
    /// fractions, so without a readout the teacher is eyeballing a percentage
    /// they cannot see. Typed fields are also the only way to copy a placement
    /// between machines, or to undo a drag that overshot by half a percent.
    @ViewBuilder private var placementControls: some View {
        let geometry = editedGeometry.wrappedValue
        VStack(alignment: .leading, spacing: 8) {
            Text(isCutout
                 ? "Drag to move it sideways, or a top corner to change its height. The bottom edge stays flush with the screen \u{2014} that is what makes a cutout stand on the edge instead of floating. Arrow keys nudge by 0.1%, \u{21E7} arrow by 1%. Hold \u{2325} while dragging to ignore the guides."
                 : "Drag the bubble to move it, or any corner to resize. Arrow keys nudge by 0.1%, \u{21E7} arrow by 1%. Hold \u{2325} while dragging to ignore the guides.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                percentField(isCutout ? "Height" : "Size",
                             value: Binding(get: { geometry.size },
                                            set: { commit(size: $0) }))
                percentField("From right",
                             value: Binding(get: { geometry.rightInset },
                                            set: { commit(rightInset: $0) }))
                if !isCutout {
                    percentField("From bottom",
                                 value: Binding(get: { geometry.bottomInset },
                                                set: { commit(bottomInset: $0) }))
                }
                Spacer()
                Button("Reset") {
                    coordinator.resetBubbleLayout()
                    Task { await coordinator.applyShapeForPreview() }
                }
                .controlSize(.small)
                .disabled(coordinator.bubbleIsAtDefault)
            }
        }
    }

    /// A percentage to one decimal - 0.1% is the arrow-key step, so anything
    /// coarser would round away a nudge the teacher just made.
    private func percentField(_ label: String, value: Binding<Double>) -> some View {
        let percent = Binding(get: { value.wrappedValue * 100 },
                              set: { value.wrappedValue = $0 / 100 })
        return HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("", value: percent, format: .number.precision(.fractionLength(1)))
                .labelsHidden()
                .frame(width: 54)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
            Text("%").font(.caption).foregroundStyle(.secondary)
            Stepper("", value: percent, step: 0.5)
                .labelsHidden()
        }
    }

    /// One write path for the typed fields, so clamping and the OBS re-place
    /// happen in exactly one place regardless of which field was edited.
    private func commit(size: Double? = nil, rightInset: Double? = nil,
                        bottomInset: Double? = nil) {
        var next = editedGeometry.wrappedValue
        if let size { next.size = size }
        if let rightInset { next.rightInset = rightInset }
        if let bottomInset { next.bottomInset = bottomInset }
        // The coordinator's didSet clamps every one of these, so a pasted or
        // typed value cannot put the source off-canvas.
        editedGeometry.wrappedValue = next
        Task { await coordinator.applyShapeForPreview() }
    }

    private var shapeCaption: String {
        switch coordinator.webcamShape {
        case .cutout:
            return "Cutout removes your background with a chroma key, so you appear as a cutout over the shared screen \u{2014} needs a real green screen behind you. Tune the key in OBS \u{2192} the webcam source \u{2192} Filters if the edges look rough."
        case .presenterLarge:
            return "The macOS Presenter Overlay (Large) look, built into the composite: the shared screen becomes a rounded panel and you stand in front of it at full height. Needs a real green screen behind you, like Cutout. Works on any Mac and needs no manual toggle each meeting."
        case .square, .circle, .roundedRectangle:
            return "Pick a shape, then start a session to apply it (Stop first if one is running)."
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

    private static let personGreen = Color(red: 0.373, green: 0.659, blue: 0.235)
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
            Rectangle().fill(Self.personGreen).frame(width: 1, height: canvas.height)
                .position(x: centre.x + box.width / 2, y: canvas.midY)
        }
        if snappedTo.contains(.bottom) {
            Rectangle().fill(Self.personGreen).frame(width: canvas.width, height: 1)
                .position(x: canvas.midX, y: centre.y + box.height / 2)
        }
    }

    @ViewBuilder private var outline: some View {
        if showsOutline {
            let clip = clipShape(size: min(box.width, box.height))
            clip.stroke(Self.personGreen, lineWidth: 2)
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
            .fill(Self.personGreen)
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


    private static let personGreen = Color(red: 0.373, green: 0.659, blue: 0.235)

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
            .foregroundStyle(Self.personGreen.gradient)
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
            clip.fill(Self.personGreen.opacity(0.22))
            Image(systemName: "person.fill")
                .resizable()
                .scaledToFit()
                .frame(height: height * 0.62)
                .foregroundStyle(Self.personGreen.gradient)
                .offset(y: height * 0.12)
        }
        .frame(width: width, height: height)
        .clipShape(clip)
        .overlay(clip.stroke(Self.personGreen.opacity(0.7), lineWidth: 1.5))
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

private struct LayoutSettingsTab: View {
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
                Text("Greenroom's own browser window \u{2014} tiled directly, with no Accessibility or Automation permission to grant. Tabs, back and forward, find in page (\u{2318}F), history (\u{2318}Y), an address bar that also searches, and the usual shortcuts (\u{2318}T, \u{2318}W, \u{2318}L). Sign-ins are remembered between sessions. Pick Chrome or another browser above if you need extensions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Reopen last session\u{2019}s tabs on Start", isOn: $coordinator.browserRestoresTabs)
                Text("On: the tabs that were open when Greenroom last quit come back, with the website above opened alongside them. Off: each Start begins with just that website.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Suggest searches as you type", isOn: $coordinator.browserSearchSuggestions)
                Text("On: the address bar sends what you type to Google as you type and shows its completions, as Chrome and Safari do. Off: only pages from your own history are suggested, and nothing leaves the Mac until you press Return.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Close the browser window when the session ends", isOn: $coordinator.browserClosesOnStop)
                Text("On: Stop closes the browser along with the meeting windows; its tabs are kept and come back on the next Start. Off: the browser stays where it is, like any other main app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

                LayoutSchematicView(layout: $coordinator.workspaceLayout,
                                    appName: coordinator.mainAppDisplayName,
                                    appIcon: AppCatalog.icon(forBundleID: coordinator.mainAppBundleID))
                    .frame(height: 140)
                    .padding(.vertical, 4)

                Text("Drag the handle between the panes to set the main app's width; drag the one between Zoom and Chat to balance the side column. A live session re-tiles on Snap Windows Back (\u{2325}\u{2318}S).")
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
                Toggle("Hide my own video tile (Zoom's \u{201C}Hide Self View\u{201D})", isOn: $coordinator.hideSelfView)
                Text("On: the speaker tile and participant view show only the others. Off: your tile appears among them like anyone else's. The class receives your video either way \u{2014} this only changes what you see. Applies immediately, even mid-meeting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Quick-hide mode: speaker tile hidden by default (\u{2325}\u{2318}Z shows it)", isOn: $coordinator.speakerTileShortcutEnabled)
                Text("On: sessions start with the speaker hidden and the chat using the full column height \u{2014} press \u{2325}\u{2318}Z to show the speaker (the chat shrinks below it), and again to hide it. Off: the normal speaker-above-chat layout stays put and the shortcut does nothing. Applies immediately, works system-wide.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shared screen") {
                Picker("Screen to share", selection: $coordinator.screenCaptureDisplayUUID) {
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

                Text("This is the screen your class sees. Automatic follows your main display, which is what you want unless you teach from a second monitor. If the display you pick isn't plugged in when a session starts, Greenroom shares your main one and says so in the status log.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Toggle("Send anonymous usage analytics", isOn: $coordinator.analyticsEnabled)
                Text("Counts and timings only \u{2014} which features get used, which settings are on or off, how long sessions run, whether something failed. Never student names, meeting IDs, file paths, web addresses or chat. Turning this off stops all network calls to the analytics service, including registering this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Second display") {
                Toggle("Show the participant view on another display", isOn: $coordinator.peopleViewOnStart)

                if coordinator.peopleViewOnStart, coordinator.customUIMode {
                    Toggle("Allow it on this screen when no second display is connected",
                           isOn: $coordinator.participantPanelOnMainDisplay)
                    Text("Off by default. The panel is large and meant for a display only you can see, so on a single screen it covers the tiled workspace. Turn it on to try the panel without a reference monitor.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if coordinator.peopleViewOnStart, !coordinator.customUIMode {
                    Text("With Zoom's own meeting UI, this is Zoom's participant grid. On a second display it goes full-screen there. With no second display it still opens \u{2014} behind the workspace, so it never covers your tiled windows; Mission Control or \u{2318}` brings it forward.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if coordinator.peopleViewOnStart, coordinator.customUIMode {
                    Text("With the custom meeting UI on, this view also carries the host controls \u{2014} mute, spotlight, admit, rename, remove. It is meant for a display only you can see. With no second display it opens as an ordinary window you can move and resize.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if coordinator.peopleViewOnStart {
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
                } else {
                    Text("On Start, a full-screen view of every participant opens on another display \u{2014} your reference monitor. Your tiled workspace, and any display mirroring it (e.g. a class projector), stay on your main screen. Works with the built-in meeting client.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                displays = DisplayResolver.connectedDisplays()
            }

            Toggle("Open the main app automatically on Start", isOn: $coordinator.mainAppOnStart)

            Text("The Zoom meeting tile and chat window tile themselves into whatever space the main pane leaves free.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

private struct MeetingSDKSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController

    var body: some View {
        // Form centers short content vertically in whatever height the
        // TabView gives it (fixed at 520 by SettingsView) rather than
        // pinning to the top - three fields read as floating in a mostly
        // empty pane (reproduced live, /qa pass). The trailing Spacer
        // claims the leftover space instead.
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Client ID", text: $coordinator.sdkClientID)
                SecureField("Client Secret", text: $coordinator.sdkClientSecret)

                Text("From your Zoom Marketplace app (General App \u{2192} Features \u{2192} Embed \u{2192} Meeting SDK). Only works for meetings hosted under this same Zoom account - joining a meeting hosted elsewhere fails with Zoom's cross-account restriction.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Toggle("Custom meeting UI (experimental)", isOn: $coordinator.customUIMode)

                if coordinator.customUIModeNeedsRelaunch {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Not active yet \u{2014} quit and reopen Greenroom. Zoom fixes the meeting UI when it first starts a session, and this launch has already started one.")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                Text("Renders the speaker inside a Greenroom window instead of using Zoom's own meeting windows, so there is no Zoom toolbar or info button to manage, and the participant view becomes a full control surface with mute, spotlight and the rest. Zoom fixes the meeting UI when it first starts a session, so changing this only takes effect after you quit and reopen Greenroom.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }
}

private struct StartMeetingSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController

    var body: some View {
        // See MeetingSDKSettingsTab - same top-align fix for Form's
        // vertical centering of shorter-than-520pt content.
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Account ID", text: $coordinator.s2sAccountID)
                TextField("Client ID", text: $coordinator.s2sClientID)
                SecureField("Client Secret", text: $coordinator.s2sClientSecret)

                Text("A different Zoom app than Meeting Chat's - create one at marketplace.zoom.us: Build App \u{2192} Server-to-Server OAuth, then copy its Account ID/Client ID/Secret here. Add all four scopes on its Scopes page: meeting:write:meeting:admin, meeting:read:list_meetings:admin, meeting:read:meeting:admin, user:read:token:admin. The setup guide (? on the main window) walks through it and can test the result. Same Zoom account as the Meeting Chat app = hosting and chat work in every meeting this creates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Toggle("Use built-in meeting client", isOn: $coordinator.useBuiltInClient)
                TextField("Your display name", text: $coordinator.userDisplayName)

                Text("On (default): New Meeting runs entirely inside Greenroom's built-in Zoom client \u{2014} one participant (you), hosting directly, chat sent as you, no separate Zoom app. Off: the classic flow \u{2014} the native Zoom app plus a hidden \u{201C}Greenroom Chat\u{201D} participant carrying the chat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
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
        // See MeetingSDKSettingsTab - same top-align fix; this tab's two
        // buttons were the most visibly stranded of the three (reproduced
        // live: a near-empty pane with buttons floating mid-height).
        VStack(alignment: .leading, spacing: 0) {
            Form {
                HStack {
                    // Confirmation before writing secrets in plaintext - the
                    // risk shouldn't live only in small caption text below
                    // (Codex design audit #6).
                    Button("Export Settings\u{2026}") { confirmingExport = true }
                        .confirmationDialog("This file will contain your Zoom secrets in plain text.",
                                            isPresented: $confirmingExport, titleVisibility: .visible) {
                            Button("Export Plaintext File") { exportSettings() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Hand it over directly (e.g. AirDrop) and delete it after importing.")
                        }
                    Button("Import Settings\u{2026}") { importSettings() }
                }

                Text("One file with every setting on this screen, Zoom credentials included \u{2014} in plaintext. Hand it over directly (e.g. AirDrop) and delete it once imported.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !statusMessage.isEmpty {
                    Text(statusMessage).font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
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
