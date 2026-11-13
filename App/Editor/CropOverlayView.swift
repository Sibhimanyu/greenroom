// Ported from Recorditor (ZRecorditor @7210322, native/MacRecorder/Editor/CropOverlayView.swift).
import SwiftUI

/// Drag on the video to draw a crop rectangle. The rect is stored normalized
/// (0…1) relative to the video frame, origin at the video's top-left.
struct CropOverlayView: View {
    @EnvironmentObject private var vm: EditorViewModel
    let containerSize: CGSize

    @State private var dragStart: CGPoint?
    @State private var dragRect: CGRect?

    private var displayRect: CGRect {
        videoDisplayRect(container: containerSize, video: vm.videoSize)
    }

    var body: some View {
        let display = displayRect
        ZStack {
            // Dim everything, then punch out the active crop rect.
            if let rect = activeRectInView {
                Color.black.opacity(0.55)
                    .reverseMask {
                        Rectangle()
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                Rectangle()
                    .stroke(Color.yellow, lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                Text(cropLabel)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.yellow)
                    .position(x: rect.midX, y: max(rect.minY - 14, 10))
            } else {
                Color.black.opacity(0.25)
                Text("Drag over the video to select the crop area")
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.7), in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let start = dragStart ?? clamp(value.startLocation, to: display)
                    dragStart = start
                    let current = clamp(value.location, to: display)
                    dragRect = CGRect(
                        x: min(start.x, current.x),
                        y: min(start.y, current.y),
                        width: abs(current.x - start.x),
                        height: abs(current.y - start.y))
                }
                .onEnded { _ in
                    defer {
                        dragStart = nil
                        dragRect = nil
                    }
                    guard let rect = dragRect, rect.width > 20, rect.height > 20, display.width > 0 else { return }
                    let normalized = CGRect(
                        x: (rect.minX - display.minX) / display.width,
                        y: (rect.minY - display.minY) / display.height,
                        width: rect.width / display.width,
                        height: rect.height / display.height)
                    vm.setCrop(normalized)
                }
        )
    }

    /// The in-progress drag rect, or the committed crop rect mapped into view space.
    private var activeRectInView: CGRect? {
        if let dragRect { return dragRect }
        guard let crop = vm.cropRect else { return nil }
        let display = displayRect
        return CGRect(
            x: display.minX + crop.minX * display.width,
            y: display.minY + crop.minY * display.height,
            width: crop.width * display.width,
            height: crop.height * display.height)
    }

    private var cropLabel: String {
        guard let crop = vm.cropRect ?? normalizedDragRect else { return "" }
        let w = Int(crop.width * vm.videoSize.width)
        let h = Int(crop.height * vm.videoSize.height)
        return "\(w) × \(h)"
    }

    private var normalizedDragRect: CGRect? {
        guard let rect = dragRect else { return nil }
        let display = displayRect
        guard display.width > 0 else { return nil }
        return CGRect(
            x: (rect.minX - display.minX) / display.width,
            y: (rect.minY - display.minY) / display.height,
            width: rect.width / display.width,
            height: rect.height / display.height)
    }

    private func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY))
    }
}

extension View {
    /// Masks this view with everything EXCEPT the given shape (a "hole").
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay(mask().blendMode(.destinationOut))
                .compositingGroup()
        }
    }
}
