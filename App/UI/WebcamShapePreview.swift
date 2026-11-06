//
//  WebcamShapePreview.swift
//  Greenroom
//
//  The webcam page's sketch of the composite and the drag layer that places
//  the bubble on it. Pure views: no coordinator, so the page can be rendered
//  off screen with sample values.
//
import SwiftUI

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

    /// Every drag is measured here, in the layer's own fixed space.
    ///
    /// A DragGesture's default space is the view it is attached to - the
    /// bubble, or a corner handle - and that view moves with the drag. Each
    /// time it moved, the next reading of the pointer shifted back by the same
    /// amount, so the bubble chased the pointer, overshot, and pulled back:
    /// the jitter, and the drag that seemed to stick. The layer itself never
    /// moves, so a translation measured against it is the pointer's own.
    private static let space = "BubbleDragLayer.canvas"
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
        .coordinateSpace(name: Self.space)
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
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
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
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
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
