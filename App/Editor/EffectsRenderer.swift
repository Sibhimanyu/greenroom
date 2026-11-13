// Ported from Recorditor (ZRecorditor @7210322, native/MacRecorder/Editor/EffectsRenderer.swift).
import AVFoundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Everything the visual-effects pass draws, with every time already on the
/// FINAL exported timeline (cuts and speed segments applied upstream).
/// Coordinates are normalized 0…1 with a top-left origin.
/// Annotation palette shared by the editor preview and the export render.
enum AnnotationColor: String, Codable, CaseIterable, Identifiable {
    case yellow, red, orange, blue, green, white, black

    var id: String { rawValue }

    var nsColor: NSColor {
        switch self {
        case .yellow: return NSColor(calibratedRed: 0.98, green: 0.75, blue: 0.14, alpha: 1)
        case .red: return NSColor(calibratedRed: 0.92, green: 0.26, blue: 0.21, alpha: 1)
        case .orange: return NSColor(calibratedRed: 0.96, green: 0.52, blue: 0.12, alpha: 1)
        case .blue: return NSColor(calibratedRed: 0.25, green: 0.52, blue: 0.95, alpha: 1)
        case .green: return NSColor(calibratedRed: 0.22, green: 0.72, blue: 0.36, alpha: 1)
        case .white: return .white
        case .black: return .black
        }
    }

    /// Legible text on the bubble of this color.
    var textNSColor: NSColor {
        switch self {
        case .yellow, .white, .green, .orange: return .black
        case .red, .blue, .black: return .white
        }
    }

    var color: Color { Color(nsColor: nsColor) }
    var textColor: Color { Color(nsColor: textNSColor) }
}

struct EditedEffects {
    struct Ripple {
        let t: Double
        let x: Double
        let y: Double
    }

    struct KeyChip {
        let t: Double
        let text: String
    }

    struct Caption {
        let start: Double
        let end: Double
        let text: String
    }

    struct Annotation {
        enum Kind: String, Codable {
            case blur, text, arrow
        }

        let kind: Kind
        let rect: CGRect
        let start: Double
        let end: Double
        let text: String
        let color: AnnotationColor
    }

    struct ZoomKeyframe {
        let t: Double
        let center: CGPoint
        let scale: Double
    }

    /// A room comment drawn into the picture at its moment — the comment
    /// alone; who wrote it stays in the app's comments panel.
    struct RoomCommentPopup {
        let start: Double
        let end: Double
        let text: String
    }

    var ripples: [Ripple] = []
    var keyChips: [KeyChip] = []
    var captions: [Caption] = []
    var annotations: [Annotation] = []
    var zoomKeyframes: [ZoomKeyframe] = []
    var roomComments: [RoomCommentPopup] = []

    var isEmpty: Bool {
        ripples.isEmpty && keyChips.isEmpty && captions.isEmpty
            && annotations.isEmpty && zoomKeyframes.isEmpty && roomComments.isEmpty
    }
}

/// Pass 2 of the export: replays the already-edited video through a Core
/// Image composition that draws ripples, keystroke chips, captions,
/// annotations (blur/text/arrow), room-comment pop-ups and the auto-zoom
/// camera. One pipeline,
/// one timeline — every effect lands exactly where the editor promised.
enum EffectsRenderer {

    enum RenderError: LocalizedError {
        case sessionFailed

        var errorDescription: String? {
            switch self {
            case .sessionFailed: return "Could not create the effects render session."
            }
        }
    }

    /// CI-handler composition drawing `effects` over any asset (a flat file
    /// or an edited AVComposition) — compositionTime is that asset's own
    /// timeline, which for our edited compositions IS the final timeline.
    static func handlerComposition(for asset: AVAsset, effects: EditedEffects,
                                   size: CGSize) -> AVMutableVideoComposition {
        let compositor = Compositor(effects: effects, size: size)
        let composition = AVMutableVideoComposition(asset: asset) { request in
            request.finish(with: compositor.compose(request.sourceImage,
                                                    at: request.compositionTime.seconds),
                           context: nil)
        }
        composition.renderSize = size
        return composition
    }

    static func render(input: URL, output: URL, effects: EditedEffects,
                       hevc: Bool, fileType: AVFileType,
                       onProgress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RenderError.sessionFailed
        }
        let size = try await track.load(.naturalSize)
        try? FileManager.default.removeItem(at: output)
        try await FastExportEngine.render(asset: asset,
                                          videoComposition: handlerComposition(for: asset,
                                                                               effects: effects,
                                                                               size: size),
                                          audioMix: nil,
                                          to: output,
                                          fileType: fileType,
                                          hevc: hevc,
                                          onProgress: onProgress)
    }

    // MARK: - Frame composition

    private final class Compositor: @unchecked Sendable {
        private let effects: EditedEffects
        private let size: CGSize
        private let ringImage: CIImage
        private let chipImages: [String: CIImage]
        private let captionImages: [CIImage?]
        private let annotationImages: [CIImage?]
        private let commentImages: [CIImage?]
        private let zoomSampler: (Double) -> (CGPoint, Double)?

        /// Room-comment pop-ups: at most this many at once, newest lowest.
        private static let maxPopups = 3
        private static let popupFade = 0.25

        init(effects: EditedEffects, size: CGSize) {
            self.effects = effects
            self.size = size
            // Ripple ring: prerendered once, scaled per frame.
            ringImage = Self.makeRing(diameter: 220)
            var chips: [String: CIImage] = [:]
            for chip in effects.keyChips where chips[chip.text] == nil {
                chips[chip.text] = Self.makeLabel(chip.text,
                                                  font: .monospacedSystemFont(ofSize: 34, weight: .bold),
                                                  padding: CGSize(width: 26, height: 14),
                                                  corner: 12)
            }
            chipImages = chips
            captionImages = effects.captions.map {
                Self.makeLabel($0.text,
                               font: .systemFont(ofSize: max(26, size.height / 32), weight: .semibold),
                               padding: CGSize(width: 30, height: 14),
                               corner: 10,
                               maxWidth: size.width * 0.82)
            }
            annotationImages = effects.annotations.map { annotation in
                switch annotation.kind {
                case .blur:
                    return nil
                case .text:
                    return Self.makeLabel(annotation.text,
                                          font: .systemFont(ofSize: max(24, size.height / 36), weight: .semibold),
                                          padding: CGSize(width: 22, height: 12),
                                          corner: 10,
                                          background: annotation.color.nsColor.withAlphaComponent(0.95),
                                          textColor: annotation.color.textNSColor)
                case .arrow:
                    return Self.makeArrow(rect: annotation.rect, canvas: size,
                                          color: annotation.color.nsColor)
                }
            }
            commentImages = effects.roomComments.map {
                Self.makeCommentBubble(text: $0.text, canvas: size)
            }
            zoomSampler = Self.makeZoomSampler(keyframes: effects.zoomKeyframes)
        }

        func compose(_ source: CIImage, at t: Double) -> CIImage {
            var image = source

            // 1. Annotations (in un-zoomed screen space).
            for (index, annotation) in effects.annotations.enumerated()
            where t >= annotation.start && t <= annotation.end {
                let rect = pixelRect(annotation.rect)
                switch annotation.kind {
                case .blur:
                    let blurred = image
                        .clampedToExtent()
                        .applyingGaussianBlur(sigma: 24)
                        .cropped(to: rect)
                    image = blurred.composited(over: image)
                case .text, .arrow:
                    if let overlay = annotationImages[index] {
                        let position: CGPoint
                        if annotation.kind == .arrow {
                            position = .zero   // arrow image is canvas-sized
                        } else {
                            position = CGPoint(x: rect.midX - overlay.extent.width / 2,
                                               y: rect.midY - overlay.extent.height / 2)
                        }
                        image = overlay
                            .transformed(by: CGAffineTransform(translationX: position.x.rounded(),
                                                               y: position.y.rounded()))
                            .composited(over: image)
                    }
                }
            }

            // 2. Click ripples: expanding, fading rings.
            for ripple in effects.ripples {
                let age = t - ripple.t
                guard age >= 0, age < 0.5 else { continue }
                let progress = age / 0.5
                let diameter = (30 + 150 * progress) * (size.height / 1080)
                let alpha = (1 - progress) * 0.75
                let scale = diameter / ringImage.extent.width
                let cx = ripple.x * size.width
                let cy = (1 - ripple.y) * size.height
                let ring = ringImage
                    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    .transformed(by: CGAffineTransform(translationX: cx - diameter / 2,
                                                       y: cy - diameter / 2))
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
                    ])
                image = ring.composited(over: image)
            }

            // 3. Auto-zoom camera (everything above zooms together).
            if let (center, scale) = zoomSampler(t), scale > 1.001 {
                let visibleW = size.width / scale
                let visibleH = size.height / scale
                var cx = center.x * size.width
                var cy = (1 - center.y) * size.height
                cx = min(max(cx, visibleW / 2), size.width - visibleW / 2)
                cy = min(max(cy, visibleH / 2), size.height - visibleH / 2)
                let originX = cx - visibleW / 2
                let originY = cy - visibleH / 2
                image = image
                    .transformed(by: CGAffineTransform(translationX: -originX, y: -originY))
                    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    .cropped(to: CGRect(origin: .zero, size: size))
            }

            // 4. Screen-fixed overlays: captions above, key chips below them.
            // `occupied` = how high from the bottom they reach right now.
            var occupied: CGFloat = 0
            for (index, caption) in effects.captions.enumerated()
            where t >= caption.start && t <= caption.end {
                if let label = captionImages[index] {
                    let x = (size.width - label.extent.width) / 2
                    let y = size.height * 0.06
                    occupied = max(occupied, y + label.extent.height)
                    image = label
                        .transformed(by: CGAffineTransform(translationX: x.rounded(), y: y.rounded()))
                        .composited(over: image)
                }
            }
            var chipX: CGFloat?
            for chip in effects.keyChips.reversed() {
                let age = t - chip.t
                guard age >= 0, age < 1.2 else { continue }
                guard let label = chipImages[chip.text] else { continue }
                let alpha = age > 0.9 ? (1.2 - age) / 0.3 : 1
                let x = chipX ?? (size.width - label.extent.width) / 2
                let y = size.height * 0.015
                occupied = max(occupied, y + label.extent.height)
                let faded = label.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
                ])
                image = faded
                    .transformed(by: CGAffineTransform(translationX: x.rounded(), y: y.rounded()))
                    .composited(over: image)
                // Only the most recent chip shows; older ones would stack.
                chipX = nil
                break
            }
            _ = chipX

            // 5. Room comments at the bottom centre, like captions: the
            // newest lowest, earlier ones stacked above it — clear of any
            // caption or key chip showing right now.
            let live = effects.roomComments.indices
                .filter { t >= effects.roomComments[$0].start && t < effects.roomComments[$0].end }
                .suffix(Self.maxPopups)
            let gap = (size.height * 0.012).rounded()
            var bottom = max(size.height * 0.08, occupied > 0 ? occupied + gap : 0).rounded()
            for index in live.reversed() {
                guard let bubble = commentImages[index] else { continue }
                let popup = effects.roomComments[index]
                let fadeIn = min(1, (t - popup.start) / Self.popupFade)
                let fadeOut = min(1, (popup.end - t) / Self.popupFade)
                let alpha = max(0, min(fadeIn, fadeOut))
                let x = ((size.width - bubble.extent.width) / 2).rounded()
                image = bubble
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
                    ])
                    .transformed(by: CGAffineTransform(translationX: x, y: bottom))
                    .composited(over: image)
                bottom += bubble.extent.height + gap
            }

            return image.cropped(to: CGRect(origin: .zero, size: size))
        }

        private func pixelRect(_ raw: CGRect) -> CGRect {
            // Normalized rects use a top-left origin; CI uses bottom-left.
            // Arrows keep a directional (possibly negative) size — box
            // effects standardize it away first.
            let normalized = raw.standardized
            return CGRect(x: normalized.origin.x * size.width,
                          y: (1 - normalized.origin.y - normalized.height) * size.height,
                          width: normalized.width * size.width,
                          height: normalized.height * size.height)
        }

        // MARK: prerendered artwork

        private static func makeRing(diameter: CGFloat) -> CIImage {
            let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
                let path = NSBezierPath(ovalIn: rect.insetBy(dx: diameter * 0.06, dy: diameter * 0.06))
                path.lineWidth = diameter * 0.07
                NSColor(calibratedRed: 1, green: 0.82, blue: 0.2, alpha: 1).setStroke()
                path.stroke()
                let inner = NSBezierPath(ovalIn: rect.insetBy(dx: diameter * 0.42, dy: diameter * 0.42))
                NSColor(calibratedRed: 1, green: 0.82, blue: 0.2, alpha: 0.5).setFill()
                inner.fill()
                return true
            }
            return ciImage(from: image) ?? CIImage.empty()
        }

        private static func makeLabel(_ text: String, font: NSFont, padding: CGSize,
                                      corner: CGFloat, maxWidth: CGFloat = 10_000,
                                      background: NSColor = NSColor.black.withAlphaComponent(0.72),
                                      textColor: NSColor = .white) -> CIImage? {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: paragraph,
            ]
            let bounded = (text as NSString).boundingRect(
                with: NSSize(width: maxWidth - padding.width * 2, height: 400),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes)
            let textSize = CGSize(width: ceil(bounded.width), height: ceil(bounded.height))
            let full = NSSize(width: textSize.width + padding.width * 2,
                              height: textSize.height + padding.height * 2)
            let image = NSImage(size: full, flipped: false) { rect in
                let bubble = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
                background.setFill()
                bubble.fill()
                (text as NSString).draw(
                    in: NSRect(x: padding.width, y: padding.height,
                               width: textSize.width, height: textSize.height),
                    withAttributes: attributes)
                return true
            }
            return ciImage(from: image)
        }

        /// Comment bubble: the comment (no name), centred like a caption,
        /// sized to the frame so it reads the same at 720p and 4K.
        private static func makeCommentBubble(text: String, canvas: CGSize) -> CIImage? {
            let unit = canvas.height / 720
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.alignment = .center
            let content = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 19 * unit, weight: .medium),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph,
            ])
            let padding = CGSize(width: 14 * unit, height: 9 * unit)
            let maxTextWidth = canvas.width * 0.70 - padding.width * 2
            let bounded = content.boundingRect(
                with: NSSize(width: maxTextWidth, height: 8 * 19 * unit),
                options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
            let textSize = CGSize(width: ceil(bounded.width), height: ceil(bounded.height))
            let full = NSSize(width: textSize.width + padding.width * 2,
                              height: textSize.height + padding.height * 2)
            let image = NSImage(size: full, flipped: false) { rect in
                let corner = 8 * unit
                NSColor.black.withAlphaComponent(0.75).setFill()
                NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).fill()
                content.draw(in: NSRect(x: padding.width, y: padding.height,
                                        width: textSize.width, height: textSize.height))
                return true
            }
            return ciImage(from: image)
        }

        /// Arrow drawn across the annotation rect (origin corner → opposite),
        /// rendered on a full-canvas transparent image so placement is exact.
        private static func makeArrow(rect normalized: CGRect, canvas: CGSize,
                                      color arrowColor: NSColor) -> CIImage? {
            let start = CGPoint(x: normalized.origin.x * canvas.width,
                                y: (1 - normalized.origin.y) * canvas.height)
            // Raw signed size (CGRect.width/.height are absolute): an
            // up/left arrow must export up/left too.
            let end = CGPoint(x: (normalized.origin.x + normalized.size.width) * canvas.width,
                              y: (1 - (normalized.origin.y + normalized.size.height)) * canvas.height)
            let image = NSImage(size: canvas, flipped: false) { _ in
                let color = arrowColor.withAlphaComponent(0.95)
                color.setStroke()
                color.setFill()
                let path = NSBezierPath()
                path.lineWidth = max(5, canvas.height / 160)
                path.lineCapStyle = .round
                path.move(to: start)
                path.line(to: end)
                path.stroke()
                // Arrow head at the end point.
                let angle = atan2(end.y - start.y, end.x - start.x)
                let headLength = max(18, canvas.height / 45)
                let head = NSBezierPath()
                head.move(to: end)
                head.line(to: CGPoint(x: end.x - headLength * cos(angle - 0.45),
                                      y: end.y - headLength * sin(angle - 0.45)))
                head.line(to: CGPoint(x: end.x - headLength * cos(angle + 0.45),
                                      y: end.y - headLength * sin(angle + 0.45)))
                head.close()
                head.fill()
                return true
            }
            return ciImage(from: image)
        }

        private static func ciImage(from image: NSImage) -> CIImage? {
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let cg = bitmap.cgImage else { return nil }
            return CIImage(cgImage: cg)
        }

        /// Smoothstep interpolation across zoom keyframes → (center, scale).
        private static func makeZoomSampler(
            keyframes: [EditedEffects.ZoomKeyframe]) -> (Double) -> (CGPoint, Double)? {
            let sorted = keyframes.sorted { $0.t < $1.t }
            guard !sorted.isEmpty else { return { _ in nil } }
            return { t in
                guard let first = sorted.first, let last = sorted.last else { return nil }
                if t <= first.t { return (first.center, first.scale) }
                if t >= last.t { return (last.center, last.scale) }
                for index in 1..<sorted.count where t <= sorted[index].t {
                    let a = sorted[index - 1]
                    let b = sorted[index]
                    let span = b.t - a.t
                    let raw = span > 0.0001 ? (t - a.t) / span : 1
                    let eased = raw * raw * (3 - 2 * raw)   // smoothstep
                    let center = CGPoint(
                        x: a.center.x + (b.center.x - a.center.x) * eased,
                        y: a.center.y + (b.center.y - a.center.y) * eased)
                    let scale = a.scale + (b.scale - a.scale) * eased
                    return (center, scale)
                }
                return (last.center, last.scale)
            }
        }
    }
}
