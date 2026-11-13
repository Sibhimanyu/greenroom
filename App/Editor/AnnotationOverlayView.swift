// Ported from Recorditor (ZRecorditor @7210322, native/MacRecorder/Editor/AnnotationOverlayView.swift).
import SwiftUI

/// Drag a box on the player to place the pending annotation (blur / text /
/// arrow). Mirrors CropOverlayView's normalized-rect math.
struct AnnotationPlacementOverlay: View {
    @EnvironmentObject private var vm: EditorViewModel
    let containerSize: CGSize

    @State private var dragStart: CGPoint?
    @State private var dragRect: CGRect?

    private var displayRect: CGRect {
        videoDisplayRect(container: containerSize, video: vm.displayVideoSize)
    }

    var body: some View {
        let display = displayRect
        ZStack {
            Color.black.opacity(0.35)
            if let rect = dragRect {
                if vm.pendingAnnotationKind == .arrow, let anchor = dragStart {
                    ArrowShape(from: anchor,
                               to: CGPoint(x: anchor.x + rect.width * (rect.minX == anchor.x ? 1 : -1),
                                           y: anchor.y + rect.height * (rect.minY == anchor.y ? 1 : -1)))
                        .stroke(Color(red: 0.98, green: 0.75, blue: 0.14),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                } else {
                    Rectangle()
                        .stroke(EditorTheme.accent, lineWidth: 2)
                        .background(Rectangle().fill(EditorTheme.accent.opacity(0.15)))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: vm.pendingAnnotationKind == .blur
                          ? "eye.slash" : vm.pendingAnnotationKind == .text
                          ? "textformat" : "arrow.up.right")
                        .font(.title2)
                    Text(placementHint)
                        .font(.callout)
                }
                .foregroundStyle(.white)
                .padding(14)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if dragStart == nil { dragStart = value.startLocation }
                    guard let anchor = dragStart else { return }
                    dragRect = CGRect(
                        x: min(anchor.x, value.location.x),
                        y: min(anchor.y, value.location.y),
                        width: abs(value.location.x - anchor.x),
                        height: abs(value.location.y - anchor.y))
                }
                .onEnded { value in
                    defer {
                        dragStart = nil
                        dragRect = nil
                    }
                    guard var rect = dragRect, display.width > 0 else { return }
                    // Arrows are directional: keep the drag's true corners.
                    if vm.pendingAnnotationKind == .arrow, let anchor = dragStart {
                        rect = CGRect(origin: anchor,
                                      size: CGSize(width: value.location.x - anchor.x,
                                                   height: value.location.y - anchor.y))
                    }
                    guard abs(rect.size.width) > 12 || abs(rect.size.height) > 12 else { return }
                    // rect.size, NOT rect.width/height: CGRect.width returns
                    // the ABSOLUTE value, which silently flipped upward or
                    // leftward arrows to point down-right at placement.
                    let normalized = CGRect(
                        x: (rect.origin.x - display.origin.x) / display.width,
                        y: (rect.origin.y - display.origin.y) / display.height,
                        width: rect.size.width / display.width,
                        height: rect.size.height / display.height)
                    vm.placeAnnotation(rect: normalized)
                }
        )
        .overlay(alignment: .topTrailing) {
            Button("Cancel") { vm.pendingAnnotationKind = nil }
                .padding(10)
        }
    }

    private var placementHint: String {
        switch vm.pendingAnnotationKind {
        case .blur: return "Drag over the area to blur"
        case .text: return "Drag where the note should sit"
        case .arrow: return "Drag from the arrow's tail to its tip"
        case nil: return ""
        }
    }
}

/// Live, EDITABLE annotations over the player — Photos-Markup style:
/// click to select, drag to move, handles to reshape (arrow tail/tip,
/// box corner), and text edits inline right on the video.
struct AnnotationPreviewOverlay: View {
    @EnvironmentObject private var vm: EditorViewModel
    let containerSize: CGSize

    @State private var dragBaseRect: CGRect?
    /// Start location of the drag that seeded dragBaseRect. A cancelled
    /// drag never fires onEnded, so "base == nil" is NOT a reliable
    /// new-drag test — a fresh startLocation is.
    @State private var dragAnchor: CGPoint?
    /// Editing (the TextField being live) is separate from selection —
    /// swapping Text→TextField mid-drag used to destroy the move gesture.
    @State private var editingTextID: UUID?
    @FocusState private var textFocused: UUID?

    private let gold = Color(red: 0.98, green: 0.75, blue: 0.14)

    var body: some View {
        let display = videoDisplayRect(container: containerSize, video: vm.displayVideoSize)
        ZStack {
            // A selected annotation deselects by clicking anywhere else.
            if vm.selectedAnnotationID != nil {
                Color.black.opacity(0.001)
                    .onTapGesture {
                        vm.selectedAnnotationID = nil
                        editingTextID = nil
                        textFocused = nil
                    }
            }
            ForEach($vm.annotations) { $annotation in
                if vm.playhead >= annotation.start, vm.playhead <= annotation.end {
                    annotationBody($annotation, display: display)
                }
            }
            // Arrows are dragged through raw AppKit events — SwiftUI drag
            // gestures delivered wrong-space / flipped values here. The
            // layer claims only points near an arrow; all other clicks
            // fall through to the SwiftUI views below.
            ArrowDragLayer(
                items: arrowItems(display: display),
                onSelect: { id in
                    vm.selectedAnnotationID = id
                    editingTextID = nil
                    textFocused = nil
                },
                onDrag: { id, tail, tip in
                    guard display.width > 0, display.height > 0,
                          let index = vm.annotations.firstIndex(where: { $0.id == id })
                    else { return }
                    vm.annotations[index].rect = CGRect(
                        x: (tail.x - display.origin.x) / display.width,
                        y: (tail.y - display.origin.y) / display.height,
                        width: (tip.x - tail.x) / display.width,
                        height: (tip.y - tail.y) / display.height)
                })
        }
        .onChange(of: vm.selectedAnnotationID) { _, selected in
            // A freshly placed (still empty) text note opens straight into
            // its field; existing notes edit on tap, move on drag.
            if let selected,
               let annotation = vm.annotations.first(where: { $0.id == selected }),
               annotation.kind == .text, annotation.text.isEmpty {
                editingTextID = selected
                textFocused = selected
            }
        }
    }

    // MARK: per-annotation interactive body

    @ViewBuilder
    private func annotationBody(_ binding: Binding<EditorViewModel.EditorAnnotation>,
                                display: CGRect) -> some View {
        let annotation = binding.wrappedValue
        let selected = vm.selectedAnnotationID == annotation.id
        let originX = display.origin.x + annotation.rect.origin.x * display.width
        let originY = display.origin.y + annotation.rect.origin.y * display.height
        // Raw signed size: CGRect.width/.height return ABSOLUTE values,
        // which redrew every up/left-pointing arrow as down-right — the
        // root cause of the long "arrow moves opposite" saga.
        let width = annotation.rect.size.width * display.width
        let height = annotation.rect.size.height * display.height

        let tint = annotation.color.color
        switch annotation.kind {
        case .arrow:
            let tail = CGPoint(x: originX, y: originY)
            let tip = CGPoint(x: originX + width, y: originY + height)
            // Purely visual — ALL arrow mouse handling lives in the
            // ArrowDragLayer (AppKit) stacked above the annotations.
            ZStack {
                ArrowShape(from: tail, to: tip)
                    .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .shadow(color: .black.opacity(selected ? 0.6 : 0), radius: 3)
                if selected {
                    endpointHandle(at: tail)
                    endpointHandle(at: tip)
                    selectionToolbar(binding, showColors: true,
                                     anchor: CGPoint(x: (tail.x + tip.x) / 2,
                                                     y: min(tail.y, tip.y)))
                }
            }
            .allowsHitTesting(selected)   // toolbar buttons only; the layer
                                          // handles the line and the dots

        case .blur:
            let rect = CGRect(x: originX, y: originY, width: width, height: height).standardized
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(selected ? EditorTheme.accent : Color.white.opacity(0.6),
                                style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected ? [] : [4])))
                    .frame(width: max(8, rect.width), height: max(8, rect.height))
                    .position(x: rect.midX, y: rect.midY)
                    .onTapGesture { select(annotation.id) }
                    .gesture(moveGesture(binding, display: display))
                if selected {
                    resizeHandle(at: CGPoint(x: rect.maxX, y: rect.maxY))
                        .gesture(resizeGesture(binding, display: display))
                    selectionToolbar(binding, showColors: false,
                                     anchor: CGPoint(x: rect.midX, y: rect.minY))
                }
            }

        case .text:
            let rect = CGRect(x: originX, y: originY, width: width, height: height).standardized
            ZStack {
                if editingTextID == annotation.id {
                    HStack(spacing: 6) {
                        // Grip: drag here to move while the field is open.
                        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                            .font(.caption.bold())
                            .foregroundStyle(annotation.color.textColor.opacity(0.6))
                            .padding(4)
                            .contentShape(Rectangle())
                            .gesture(moveGesture(binding, display: display))
                        TextField("Type here…", text: binding.text)
                            .textFieldStyle(.plain)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(annotation.color.textColor)
                            .focused($textFocused, equals: annotation.id)
                            .frame(width: max(140, rect.width))
                            .onSubmit {
                                editingTextID = nil
                                vm.selectedAnnotationID = nil
                                textFocused = nil
                            }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(tint.opacity(0.95), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(EditorTheme.accent, lineWidth: 2))
                    .position(x: rect.midX, y: rect.midY)
                } else {
                    // Drag anywhere to move; tap to edit the wording.
                    Text(annotation.text.isEmpty ? "Type here…" : annotation.text)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(annotation.color.textColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(tint.opacity(0.95), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(selected ? EditorTheme.accent : .clear, lineWidth: 2))
                        .position(x: rect.midX, y: rect.midY)
                        .gesture(moveGesture(binding, display: display))
                        .onTapGesture {
                            select(annotation.id)
                            editingTextID = annotation.id
                            textFocused = annotation.id
                        }
                }
                if selected || editingTextID == annotation.id {
                    selectionToolbar(binding, showColors: true,
                                     anchor: CGPoint(x: rect.midX, y: rect.minY))
                }
            }
        }
    }

    /// Screen-space geometry for every arrow visible at the playhead,
    /// plus the selected arrow's toolbar rect (excluded from the layer so
    /// those clicks reach the SwiftUI buttons).
    private func arrowItems(display: CGRect) -> [ArrowDragNSView.Item] {
        vm.annotations.compactMap { annotation in
            guard annotation.kind == .arrow,
                  vm.playhead >= annotation.start, vm.playhead <= annotation.end
            else { return nil }
            let tail = CGPoint(x: display.origin.x + annotation.rect.origin.x * display.width,
                               y: display.origin.y + annotation.rect.origin.y * display.height)
            let tip = CGPoint(x: tail.x + annotation.rect.size.width * display.width,
                              y: tail.y + annotation.rect.size.height * display.height)
            var exclusion = CGRect.zero
            if vm.selectedAnnotationID == annotation.id {
                let anchorY = max(min(tail.y, tip.y) - 30, 18)
                exclusion = CGRect(x: (tail.x + tip.x) / 2 - 150, y: anchorY - 18,
                                   width: 300, height: 36)
            }
            return ArrowDragNSView.Item(id: annotation.id, tail: tail, tip: tip,
                                        exclusion: exclusion)
        }
    }

    // MARK: gestures & handles

    private func select(_ id: UUID) {
        vm.selectedAnnotationID = id
    }

    private func moveGesture(_ binding: Binding<EditorViewModel.EditorAnnotation>,
                             display: CGRect) -> some Gesture {
        // 6pt threshold: a mouse click always slips a pixel or two, and at
        // 2pt every click-to-select nudged the annotation out of place.
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if dragAnchor != value.startLocation {
                    dragAnchor = value.startLocation
                    select(binding.wrappedValue.id)
                    dragBaseRect = binding.wrappedValue.rect
                }
                guard let base = dragBaseRect, display.width > 0 else { return }
                binding.wrappedValue.rect.origin = CGPoint(
                    x: base.origin.x + value.translation.width / display.width,
                    y: base.origin.y + value.translation.height / display.height)
            }
            .onEnded { _ in
                dragBaseRect = nil
                dragAnchor = nil
            }
    }

    private func resizeGesture(_ binding: Binding<EditorViewModel.EditorAnnotation>,
                               display: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragAnchor != value.startLocation {
                    dragAnchor = value.startLocation
                    dragBaseRect = binding.wrappedValue.rect
                }
                guard let base = dragBaseRect, display.width > 0 else { return }
                binding.wrappedValue.rect.size = CGSize(
                    width: max(0.02, base.width + value.translation.width / display.width),
                    height: max(0.02, base.height + value.translation.height / display.height))
            }
            .onEnded { _ in
                dragBaseRect = nil
                dragAnchor = nil
            }
    }


    /// Floating controls above the selected annotation: color dots (where a
    /// color applies) and delete.
    private func selectionToolbar(_ binding: Binding<EditorViewModel.EditorAnnotation>,
                                  showColors: Bool, anchor: CGPoint) -> some View {
        HStack(spacing: 7) {
            if showColors {
                ForEach(AnnotationColor.allCases) { option in
                    Button {
                        binding.wrappedValue.color = option
                    } label: {
                        Circle()
                            .fill(option.color)
                            .frame(width: 15, height: 15)
                            .overlay(Circle().stroke(
                                binding.wrappedValue.color == option ? Color.white : .white.opacity(0.25),
                                lineWidth: binding.wrappedValue.color == option ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                }
                Divider().frame(height: 14)
            }
            Button {
                let id = binding.wrappedValue.id
                vm.selectedAnnotationID = nil
                editingTextID = nil
                textFocused = nil
                vm.removeAnnotation(id: id)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Delete this annotation")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .greenroomGlass(in: Capsule(), interactive: true)
        .position(x: anchor.x, y: max(anchor.y - 30, 18))
    }

    private func endpointHandle(at point: CGPoint) -> some View {
        // The visible dot is 14pt, but the hit target is 32pt — with a
        // mouse, the bare dot was nearly impossible to grab before the fat
        // move-line underneath caught the drag and moved the whole arrow.
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(EditorTheme.accent, lineWidth: 2))
            .frame(width: 14, height: 14)
            .shadow(radius: 2)
            .padding(9)
            .contentShape(Circle())
            .position(point)
    }

    private func resizeHandle(at point: CGPoint) -> some View {
        Circle()
            .fill(EditorTheme.accent)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .frame(width: 13, height: 13)
            .padding(9)
            .contentShape(Circle())
            .position(point)
    }
}

struct ArrowShape: Shape {
    let from: CGPoint
    let to: CGPoint

    func path(in _: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        let angle = atan2(to.y - from.y, to.x - from.x)
        let head: CGFloat = 14
        path.move(to: to)
        path.addLine(to: CGPoint(x: to.x - head * cos(angle - 0.45),
                                 y: to.y - head * sin(angle - 0.45)))
        path.move(to: to)
        path.addLine(to: CGPoint(x: to.x - head * cos(angle + 0.45),
                                 y: to.y - head * sin(angle + 0.45)))
        return path
    }
}
