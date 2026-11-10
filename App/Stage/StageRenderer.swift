//
//  StageRenderer.swift
//  Greenroom
//
//  The drawing. One function, `compose`, turns "what the scene says" plus
//  "the latest picture from each input" into one Core Image picture, and the
//  live compositor and the debug still render both go through it, so a still
//  proves what the live path draws.
//
//  Geometry is GreenroomScene's, number for number. It works in top-left
//  coordinates like OBS's scene-item transforms and converts to Core Image's
//  bottom-left only at the last step (`ci(_:)`).
//
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreVideo
import Foundation
import Metal

/// One camera's latest picture. `cutout` is the same frame with the
/// background removed (CutoutPublisher), present only while it was asked to.
struct StageCameraInput {
    var raw: CIImage
    var cutout: CIImage?
}

struct StageScene {
    var layout = StageLayout()
    /// A whole display fills its box; a window or app is fitted with a margin.
    var contentIsWholeDisplay = true
    var removal: BackgroundRemoval = .automatic
    var liveSlot = 0
    /// A crossfade in progress: the camera going out, and 0...1 progress.
    var fade: (outgoing: Int, progress: Double)?
}

final class StageRenderer {
    let canvas: CGSize
    let context: CIContext
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private var masks: [String: CIImage] = [:]
    private lazy var chromaKey: CIFilter? = Self.makeChromaKeyCube()

    init(canvas: CGSize) {
        self.canvas = canvas
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            // Blend in sRGB as OBS does, not in linear light: edges and
            // fades then match what the class has always seen, and it
            // skips two colour conversions per layer.
            .workingColorSpace: sRGB,
            .outputColorSpace: sRGB,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            context = CIContext(options: options)
        }
    }

    func render(_ image: CIImage, to buffer: CVPixelBuffer) {
        context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: canvas), colorSpace: sRGB)
    }

    // MARK: Compose

    /// `--ink` #101828, the colour GreenroomScene's backdrop uses (:1427).
    private var backdrop: CIImage {
        CIImage(color: CIColor(red: 16.0 / 255, green: 24.0 / 255, blue: 40.0 / 255,
                               colorSpace: sRGB)!)
            .cropped(to: CGRect(origin: .zero, size: canvas))
    }

    func compose(scene: StageScene, screen: CIImage?, cameras: [Int: StageCameraInput]) -> CIImage {
        let layout = scene.layout
        var out = backdrop                                   // layer 0 (enforceLayerOrder :952)

        // Content: above the backdrop, below every camera.
        if layout.showsContent, let screen {
            let presenter = layout.showsCamera && layout.shape.isPresenterStyle
            let box: CGRect
            if presenter {
                // layoutPresenter :1717
                let w = canvas.width * 0.78, h = canvas.height * 0.78
                box = CGRect(x: canvas.width - canvas.width * 0.025 - w,
                             y: (canvas.height - h) / 2, width: w, height: h)
            } else {
                // placeContentFullFrame :1414; a window gets a margin.
                let m = scene.contentIsWholeDisplay ? 0 : canvas.height * 0.045
                box = CGRect(x: m, y: m, width: canvas.width - 2 * m, height: canvas.height - 2 * m)
            }
            let placed = place(screen, inside: box)
            var contentImage = placed.image
            if presenter {
                // Panel mask: radius 2.5% of the drawn width (MaskImageGenerator :73).
                let rect = placed.rect
                let r = rect.width * 0.025
                contentImage = masked(contentImage, rect: rect, path: { r0 in
                    CGPath(roundedRect: r0, cornerWidth: r, cornerHeight: r, transform: nil)
                }, key: { "panel-\(Int(rect.width))x\(Int(rect.height))" })
            }
            out = contentImage.composited(over: out)
        }

        // Cameras: non-live first, live last, on top (enforceLayerOrder :962).
        if layout.showsCamera {
            var order: [(slot: Int, opacity: Double)] = []
            if let fade = scene.fade, fade.outgoing != scene.liveSlot {
                let rising = Self.fadeCurve(fade.progress)
                let incomingThere = cameras[scene.liveSlot] != nil
                // Outgoing falls as 1 - r^2 (switchCamera :712); if the
                // incoming camera has nothing yet, keep the outgoing whole.
                order.append((fade.outgoing, incomingThere ? 1 - rising * rising : 1))
                order.append((scene.liveSlot, rising))
            } else {
                order.append((scene.liveSlot, 1))
            }
            for entry in order {
                guard let input = cameras[entry.slot], let pixels = pixels(of: input, scene: scene),
                      var layer = cameraLayer(pixels, layout: layout) else { continue }
                if entry.opacity < 0.999 { layer = layer.withOpacity(max(0, entry.opacity)) }
                out = layer.composited(over: out)
            }
        }
        return out.cropped(to: CGRect(origin: .zero, size: canvas))
    }

    /// Smoothstep (GreenroomScene.fadeCurve :763).
    static func fadeCurve(_ t: Double) -> Double { let t = min(1, max(0, t)); return t * t * (3 - 2 * t) }

    /// The pixels a camera contributes under the current look, or nil when
    /// the look needs a cutout that has not arrived (one frame at most; an
    /// unremoved frame would flash the room).
    private func pixels(of input: StageCameraInput, scene: StageScene) -> CIImage? {
        guard scene.layout.shape.usesChromaKey else { return input.raw }
        switch scene.removal {
        case .automatic: return input.cutout
        case .greenScreen: return keyed(input.raw)
        }
    }

    // MARK: Cameras

    /// Places one camera per the layout. Returns a canvas-sized-or-smaller
    /// image already in canvas coordinates.
    private func cameraLayer(_ source: CIImage, layout: StageLayout) -> CIImage? {
        let image = normalized(source)
        guard image.extent.width > 1, image.extent.height > 1 else { return nil }
        let aspect = image.extent.width / image.extent.height
        let W = canvas.width, H = canvas.height

        // Nothing shared: full frame, aspect-fit, centred (layoutCameraFullFrame :1524).
        guard layout.showsContent else {
            return place(image, inside: CGRect(x: 0, y: 0, width: W, height: H)).image
        }

        switch layout.cameraShape {
        case .presenterLarge:
            // layoutPresenter :1748
            let h = H * 1.12, w = h * aspect
            return stretch(image, to: CGRect(x: W * 0.24 - w / 2, y: -H * 0.02, width: w, height: h))
        case .cutout:
            // layoutCutout :1496: flush with the bottom, own height and inset.
            let h = H * layout.cutoutHeightFraction, w = h * aspect
            return stretch(image, to: CGRect(x: W - W * layout.cutoutRightInset - w, y: H - h,
                                             width: w, height: h))
        case .square, .circle, .roundedRectangle:
            let shape = layout.cameraShape
            var src = image
            if shape.cropsToSquare {                          // ensureSquareCrop :1211
                let side = min(src.extent.width, src.extent.height)
                src = src.cropped(to: CGRect(x: (src.extent.width - side) / 2,
                                             y: (src.extent.height - side) / 2,
                                             width: side, height: side))
                src = normalized(src)
            }
            // positionBubble :1684: the box has the picture's own aspect.
            let boxW = (W * layout.widthFraction).rounded()
            let boxH = (boxW * src.extent.height / src.extent.width).rounded()
            let rect = CGRect(x: (W - W * layout.rightInset - boxW).rounded(),
                              y: (H - H * layout.bottomInset - boxH).rounded(),
                              width: boxW, height: boxH)
            let placed = stretch(src, to: rect)
            switch shape {
            case .circle:
                // MaskImageGenerator :89-97 (inset 2px of 512).
                return masked(placed, rect: rect) { r in
                    let inset = r.width / 512 * 2
                    return CGPath(ellipseIn: r.insetBy(dx: inset, dy: inset), transform: nil)
                } key: { "circle-\(Int(rect.width))x\(Int(rect.height))" }
            case .roundedRectangle:
                return masked(placed, rect: rect) { r in
                    let inset = r.width / 512 * 2
                    let box = r.insetBy(dx: inset, dy: inset)
                    let radius = min(box.width, box.height) * 0.18
                    return CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)
                } key: { "rounded-\(Int(rect.width))x\(Int(rect.height))" }
            default:
                return placed
            }
        }
    }

    // MARK: Geometry helpers

    /// Top-left rect to Core Image's bottom-left.
    private func ci(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: canvas.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func normalized(_ image: CIImage) -> CIImage {
        let e = image.extent
        return e.origin == .zero ? image : image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
    }

    private func scaled(_ image: CIImage, by s: CGFloat) -> CIImage {
        guard abs(s - 1) > 0.001 else { return image }
        if s < 1 {
            // Lanczos keeps text legible when a display is shrunk to the canvas.
            let f = CIFilter.lanczosScaleTransform()
            f.inputImage = image; f.scale = Float(s); f.aspectRatio = 1
            if let out = f.outputImage { return out }
        }
        return image.transformed(by: CGAffineTransform(scaleX: s, y: s))
    }

    /// Aspect-fit into `box` (top-left coordinates), centred: OBS's
    /// SCALE_INNER with alignment 0.
    private func place(_ source: CIImage, inside box: CGRect) -> (image: CIImage, rect: CGRect) {
        let image = normalized(source)
        let w = image.extent.width, h = image.extent.height
        let s = min(box.width / w, box.height / h)
        let drawn = CGRect(x: box.midX - w * s / 2, y: box.midY - h * s / 2, width: w * s, height: h * s)
        let target = ci(drawn)
        let out = normalized(scaled(image, by: s))
            .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
            .cropped(to: target)
        return (out, drawn)
    }

    /// Fills `rect` (top-left coordinates) with the picture, uniformly: every
    /// caller hands in a rect with the picture's own aspect (OBS_BOUNDS_STRETCH
    /// with the aspect already matched).
    private func stretch(_ source: CIImage, to rect: CGRect) -> CIImage {
        let image = normalized(source)
        let s = rect.width / image.extent.width
        let target = ci(rect)
        return normalized(scaled(image, by: s))
            .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
            .cropped(to: target)
    }

    // MARK: Masks

    /// Cuts `image` to a shape drawn at the exact pixel size of `rect`
    /// (top-left coordinates), so edges are anti-aliased once and never
    /// stretched, which is what a mask image scaled over a source does.
    private func masked(_ image: CIImage, rect: CGRect, path: (CGRect) -> CGPath,
                        key: () -> String) -> CIImage {
        let k = key()
        let mask: CIImage
        if let cached = masks[k] { mask = cached } else {
            let w = max(1, Int(rect.width.rounded())), h = max(1, Int(rect.height.rounded()))
            guard let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
            cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            cg.addPath(path(CGRect(x: 0, y: 0, width: w, height: h)))
            cg.fillPath()
            guard let bitmap = cg.makeImage() else { return image }
            mask = CIImage(cgImage: bitmap)
            if masks.count > 24 { masks.removeAll() }
            masks[k] = mask
        }
        let target = ci(rect)
        let placed = mask.transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
        return image.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: placed])
    }

    // MARK: Green screen

    private func keyed(_ image: CIImage) -> CIImage {
        guard let filter = chromaKey else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage ?? image
    }

    /// OBS's chroma key v2, with the settings GreenroomScene writes
    /// (setChromaKey :1119: green, similarity 400, smoothness 80, spill 100),
    /// as a colour cube: distance in CbCr from key green, smoothed, with the
    /// spill pulled towards grey. The formulas are the effect file's.
    private static func makeChromaKeyCube() -> CIFilter? {
        let n = 64
        let similarity: Float = 0.4, smoothness: Float = 0.08, spill: Float = 0.1
        func cbcr(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float) {
            (-0.100644 * r - 0.338572 * g + 0.439216 * b + 0.501961,
             0.439216 * r - 0.398942 * g - 0.040274 * b + 0.501961)
        }
        let key = cbcr(0, 1, 0)
        var data = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let rf = Float(r) / Float(n - 1), gf = Float(g) / Float(n - 1), bf = Float(b) / Float(n - 1)
            let c = cbcr(rf, gf, bf)
            let dist = ((c.0 - key.0) * (c.0 - key.0) + (c.1 - key.1) * (c.1 - key.1)).squareRoot()
            let base = dist - similarity
            let alpha = powf(min(1, max(0, base / smoothness)), 1.5)
            let spillAmount = powf(min(1, max(0, base / spill)), 1.5)
            let grey = rf * 0.2126 + gf * 0.7152 + bf * 0.0722
            let nr = grey + (rf - grey) * spillAmount
            let ng = grey + (gf - grey) * spillAmount
            let nb = grey + (bf - grey) * spillAmount
            // CIColorCube wants premultiplied output.
            data[i] = nr * alpha; data[i + 1] = ng * alpha; data[i + 2] = nb * alpha; data[i + 3] = alpha
            i += 4
        } } }
        let filter = CIFilter(name: "CIColorCube")
        filter?.setValue(n, forKey: "inputCubeDimension")
        filter?.setValue(data.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: "inputCubeData")
        return filter
    }
}

private extension CIImage {
    /// Opacity of a finished layer, as OBS's fade filter does after the key,
    /// crop and mask.
    func withOpacity(_ a: Double) -> CIImage {
        applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)])
    }
}
