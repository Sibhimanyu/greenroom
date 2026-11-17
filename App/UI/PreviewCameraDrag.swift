//
//  PreviewCameraDrag.swift
//
//  The drag layer over Home's live preview: an invisible hit rect over the
//  camera (the picture underneath is the composited output, so the camera is
//  already drawn in it), a thin outline on hover, and corner handles to
//  resize. It places the camera exactly as the floating bubble does, through
//  PresenceGeometry with the frame as the display (PreviewFrameRules).
//
//  Smooth by construction: a drag step moves only this layer's own @State and
//  tells the compositor (`onStep`, off the main thread). The coordinator's
//  @Published values and UserDefaults are written once, at the end (`onCommit`).
//
import SwiftUI

struct PreviewCameraDragLayer: View {
    /// The committed placement (the coordinator's).
    let box: PresenceBox
    let shape: WebcamShape
    /// The camera's width over height in the picture: 1 for a circle.
    let aspect: Double
    /// The content rect, canvas px; nil: the canvas fills the frame.
    let content: CGRect?
    /// The builder: the canvas is the usable area of a display, the camera is
    /// placed on the whole display. Nil (Home): the frame is the display.
    var space: LayoutCameraSpace?
    var onStep: (PresenceBox) -> Void
    var onCommit: (PresenceBox) -> Void
    /// Drawn inside the camera's rect (it follows the drag). Nil on Home, where
    /// the picture underneath already shows the camera; the layout builder draws
    /// its own stand-in here.
    var fill: ((CGSize) -> AnyView)?

    @State private var draft: PresenceBox?
    @State private var start: (box: PresenceBox, rect: CGRect)?
    @State private var hovering = false

    private static let space = "PreviewCameraDragLayer.frame"
    private var isCutout: Bool { shape == .cutout }
    private var corners: [BubbleDragLayer.Corner] { isCutout ? [.topLeft, .topRight] : BubbleDragLayer.Corner.allCases }

    var body: some View {
        GeometryReader { geo in
            let frame = geo.size
            let current = draft ?? box
            let rect = rect(of: current, frame: frame)
            let active = hovering || start != nil
            ZStack(alignment: .topLeading) {
                // Hover tracking over the camera and a little beyond, so the
                // corner handles (half outside the rect) keep it alive.
                Color.clear
                    .frame(width: rect.width + 28, height: rect.height + 28)
                    .contentShape(Rectangle())
                    .onHover { hovering = $0 }
                    .offset(x: rect.minX - 14, y: rect.minY - 14)
                    .allowsHitTesting(false)

                if let fill {
                    fill(rect.size)
                        .frame(width: rect.width, height: rect.height)
                        .allowsHitTesting(false)
                        .offset(x: rect.minX, y: rect.minY)
                }

                outline(size: rect.size, active: active)
                    .frame(width: rect.width, height: rect.height)
                    .contentShape(Rectangle())
                    .onHover { inside in (inside ? NSCursor.openHand : NSCursor.arrow).set(); hovering = inside || hovering }
                    .gesture(move(frame: frame))
                    .offset(x: rect.minX, y: rect.minY)
                    .help("Drag to move your camera. It moves for everyone.")

                if active {
                    ForEach(corners, id: \.self) { corner in
                        handle
                            .gesture(resize(corner, frame: frame))
                            .onHover { inside in (inside ? Self.cursor(for: corner) : NSCursor.arrow).set(); hovering = inside || hovering }
                            .offset(x: point(of: corner, in: rect).x - 14, y: point(of: corner, in: rect).y - 14)
                    }
                    .transition(.opacity)
                }
            }
            .coordinateSpace(name: Self.space)
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .clipped()   // builder: the part over the menu bar / Dock is cut at the canvas edge
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your camera in the preview")
        .accessibilityHint("Drag to move it. It moves for everyone.")
    }

    // MARK: Placement

    private func rect(of box: PresenceBox, frame: CGSize) -> CGRect {
        if let space { return LayoutCameraRules.rect(box: box, aspect: aspect, frame: frame, space: space) }
        return PreviewFrameRules.cameraRect(box: box, aspect: aspect, frame: frame, content: content)
    }

    private func boxFor(_ rect: CGRect, from box: PresenceBox, frame: CGSize) -> PresenceBox {
        if let space { return LayoutCameraRules.box(applying: rect, to: box, aspect: aspect, frame: frame, space: space) }
        return PreviewFrameRules.box(applying: rect, to: box, aspect: aspect, frame: frame, content: content)
    }

    private func widthRange(for box: PresenceBox, aspect: Double, frame: CGSize) -> ClosedRange<CGFloat> {
        if let space { return LayoutCameraRules.widthRange(for: box, aspect: aspect, frame: frame, space: space) }
        return PreviewFrameRules.geometry(frame: frame, content: content).widthRange(for: box, aspect: aspect)
    }

    // MARK: Drawing

    @ViewBuilder private func outline(size: CGSize, active: Bool) -> some View {
        let clip = clipShape(min(size.width, size.height))
        clip.stroke(Brand.green, lineWidth: 1.5)
            .opacity(active ? 1 : 0)
            .background(clip.fill(.white.opacity(0.001)))   // the hit area, invisible
            .animation(.easeOut(duration: 0.12), value: active)
    }

    private func clipShape(_ size: CGFloat) -> AnyShape {
        switch shape {
        case .circle: return AnyShape(Circle())
        case .roundedRectangle: return AnyShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
        default: return AnyShape(Rectangle())
        }
    }

    private var handle: some View {
        Circle()
            .fill(Brand.green)
            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
            .frame(width: 10, height: 10)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
    }

    /// The system's diagonal resize cursor (macOS 15), else a crosshair.
    private static func cursor(for corner: BubbleDragLayer.Corner) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch corner {
            case .topLeft: position = .topLeft
            case .topRight: position = .topRight
            case .bottomLeft: position = .bottomLeft
            case .bottomRight: position = .bottomRight
            }
            return NSCursor.frameResize(position: position, directions: [.inward, .outward])
        }
        return .crosshair
    }

    private func point(of corner: BubbleDragLayer.Corner, in r: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        }
    }

    // MARK: Gestures

    private func begin(frame: CGSize) -> (box: PresenceBox, rect: CGRect) {
        if let start { return start }
        let s = (box: draft ?? box,
                 rect: rect(of: draft ?? box, frame: frame))
        start = s
        NSCursor.closedHand.set()
        return s
    }

    private func place(_ rect: CGRect, from s: (box: PresenceBox, rect: CGRect), frame: CGSize) {
        let next = boxFor(rect, from: s.box, frame: frame)
        guard next != draft else { return }
        draft = next
        onStep(next)
    }

    private func move(frame: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let s = begin(frame: frame)
                // A cutout stands on the bottom edge: horizontal only.
                place(s.rect.offsetBy(dx: value.translation.width, dy: isCutout ? 0 : value.translation.height),
                      from: s, frame: frame)
            }
            .onEnded { _ in finish() }
    }

    /// Resizes about the corner opposite the handle (a cutout: by height, bottom pinned).
    private func resize(_ corner: BubbleDragLayer.Corner, frame: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let s = begin(frame: frame)
                let r = s.rect
                let dx = value.translation.width, dy = value.translation.height
                var growth: CGFloat
                switch corner {
                case .topLeft: growth = (-dx - dy) / 2
                case .topRight: growth = (dx - dy) / 2
                case .bottomLeft: growth = (-dx + dy) / 2
                case .bottomRight: growth = (dx + dy) / 2
                }
                let a = CGFloat(max(aspect, 0.1))
                var width: CGFloat
                if isCutout {
                    width = (r.height - dy) * a        // height follows the vertical drag
                } else {
                    width = r.width + growth
                }
                let range = widthRange(for: s.box, aspect: Double(a), frame: frame)
                width = min(max(width, range.lowerBound), range.upperBound)
                let height = width / a
                let left = (corner == .topLeft || corner == .bottomLeft) ? r.maxX - width : r.minX
                let top = isCutout ? r.maxY - height
                    : ((corner == .topLeft || corner == .topRight) ? r.maxY - height : r.minY)
                place(CGRect(x: left, y: top, width: width, height: height), from: s, frame: frame)
            }
            .onEnded { _ in finish() }
    }

    private func finish() {
        let last = draft
        start = nil
        if let last { onCommit(last) }
        // The coordinator now holds the same numbers; the draft is done.
        draft = nil
        NSCursor.arrow.set()
    }
}

/// The live composite cropped to `crop` (a unit rect of the canvas), filling
/// its frame. Observes the frame feed and nothing else.
struct CroppedLivePicture: View {
    @ObservedObject var feed: ShapePreviewFeed
    let crop: CGRect

    var body: some View {
        GeometryReader { geo in
            if let frame = feed.frame {
                let canvas = PreviewFrameRules.canvasRect(frame: CGRect(origin: .zero, size: geo.size), crop: crop)
                Image(nsImage: frame)
                    .resizable()
                    .frame(width: canvas.width, height: canvas.height)
                    .offset(x: canvas.minX, y: canvas.minY)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    .clipped()
            }
        }
    }
}
