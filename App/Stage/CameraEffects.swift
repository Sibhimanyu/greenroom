//
//  CameraEffects.swift
//  Greenroom
//
//  Ported from Recorditor (ZRecorditor @7210322, native/MacRecorder/Recording/CameraCapture.swift):
//  `CameraBackground`, `CameraEffects.apply`, `keepDominantRegion`,
//  `smoothedMask` and `ComponentScratch`. Changes against upstream are listed
//  in docs/recorditor-integration/camera-port-log.md.
//
//  What this is: the camera behind you blurred, or swapped for a picture.
//  CutoutPublisher already asks Vision where the person is, once per frame,
//  for Cutout and Presenter. The same answer drives these two, so there is
//  still exactly one segmentation pipeline in the app. This file only turns
//  that answer into a picture.
//
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import ImageIO
import Vision

/// What sits behind you in the bubble shapes. Cutout and Presenter have their
/// own removal (see `BackgroundRemoval`) and ignore this.
///
/// Upstream also has a `.cutout` case; Greenroom's Cutout is a webcam shape,
/// so it is not repeated here.
enum CameraBackground: String, CaseIterable, Identifiable {
    case normal = "Normal"
    case blur = "Blur"
    case image = "Image"

    var id: String { rawValue }
}

/// The five pictures Recorditor ships, plus the one the user chose.
///
/// A choice is stored as a short string so it travels in `StageConfiguration`
/// (which is Equatable) and in UserDefaults: a preset's `rawValue`, or
/// `custom-<stamp>` for the user's own file. The stamp changes every time a
/// new file is chosen, so the compositor sees a different value and reloads.
enum CameraBackgroundPreset: String, CaseIterable, Identifiable {
    case studio, sunset, ocean, forest, slate

    var id: String { rawValue }

    var label: String { rawValue.capitalized }

    /// The bundled file, `bg-1-studio.jpg` and so on (App/Stage/Backgrounds).
    var fileName: String {
        let index = (Self.allCases.firstIndex(of: self) ?? 0) + 1
        return "bg-\(index)-\(rawValue)"
    }

    var url: URL? { Bundle.main.url(forResource: fileName, withExtension: "jpg") }

    static let defaultChoice = CameraBackgroundPreset.studio.rawValue
}

/// Loads the picture behind you, once per choice. Cheap to ask for again.
enum CameraBackgroundLibrary {

    /// Where the user's own picture is kept: a copy, so it still works after
    /// the original moves or is deleted.
    static var customFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Greenroom/CameraBackground", isDirectory: true)
    }

    static func isCustom(_ key: String) -> Bool { key.hasPrefix("custom") }

    /// The copied file, whatever its extension.
    static var customFileURL: URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: customFolder, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.deletingPathExtension().lastPathComponent == "custom" }
    }

    static func url(for key: String) -> URL? {
        if isCustom(key) { return customFileURL }
        return CameraBackgroundPreset(rawValue: key)?.url
    }

    /// Copies a chosen picture in and returns the new key, or nil when it
    /// cannot be read as an image.
    static func importCustom(from source: URL) -> String? {
        guard CGImageSourceCreateWithURL(source as CFURL, nil) != nil else { return nil }
        let fm = FileManager.default
        try? fm.createDirectory(at: customFolder, withIntermediateDirectories: true)
        if let old = customFileURL { try? fm.removeItem(at: old) }
        let ext = source.pathExtension.isEmpty ? "img" : source.pathExtension.lowercased()
        let target = customFolder.appendingPathComponent("custom.\(ext)")
        do { try fm.copyItem(at: source, to: target) } catch { return nil }
        return "custom-\(Int(Date().timeIntervalSince1970))"
    }

    private static let lock = NSLock()
    private static var cache: (key: String, image: CIImage)?

    /// The picture as a Core Image picture, no wider than the stage. A
    /// 24-megapixel photo would otherwise be fitted to the camera frame on
    /// every frame.
    static func image(for key: String) -> CIImage? {
        lock.lock()
        if let cache, cache.key == key { lock.unlock(); return cache.image }
        lock.unlock()
        guard let url = url(for: key),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1920,
              ] as CFDictionary) else { return nil }
        let image = CIImage(cgImage: cg)
        lock.lock(); cache = (key, image); lock.unlock()
        return image
    }
}

/// The one effects pipeline: a camera frame plus its person mask in, the
/// picture the class sees out.
enum CameraEffects {

    /// Vision's segmentation model takes a second or two to load the first
    /// time. Doing that on the camera queue freezes the live picture, so the
    /// first time a background is asked for, load it on a utility queue.
    /// Upstream warms it on the first camera frame instead.
    static func warmUp() {
        warmLock.lock()
        let already = warmed
        warmed = true
        warmLock.unlock()
        guard !already else { return }
        DispatchQueue.global(qos: .utility).async {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 256, 256, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { return }
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .balanced
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            try? VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
        }
    }
    private static var warmed = false
    private static let warmLock = NSLock()

    /// `maskBuffer` is the refined person mask (see `MaskRefiner`). With no
    /// mask (Vision failed on this frame) the whole frame counts as
    /// background: a frame is never passed through unblurred.
    static func apply(_ cam: CIImage, maskBuffer: CVPixelBuffer?,
                      mode: CameraBackground, background: CIImage?) -> CIImage {
        guard mode != .normal else { return cam }
        let extent = cam.extent

        var mask: CIImage
        if let maskBuffer {
            mask = CIImage(cvPixelBuffer: maskBuffer)
            mask = mask.transformed(by: CGAffineTransform(
                scaleX: extent.width / mask.extent.width,
                y: extent.height / mask.extent.height))

            // Vision's mask is a soft confidence map: "maybe background"
            // pixels come through semi-transparent, ghosting text and objects
            // behind the person. An S-curve pushes uncertain pixels decisively
            // to one side while keeping a thin soft edge.
            let curve = CIFilter.toneCurve()
            curve.inputImage = mask
            curve.point0 = CGPoint(x: 0, y: 0)
            curve.point1 = CGPoint(x: 0.35, y: 0.03)
            curve.point2 = CGPoint(x: 0.5, y: 0.5)
            curve.point3 = CGPoint(x: 0.65, y: 0.97)
            curve.point4 = CGPoint(x: 1, y: 1)
            mask = (curve.outputImage ?? mask).cropped(to: mask.extent)
        } else {
            mask = CIImage(color: .black).cropped(to: extent)
        }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = cam
        blend.maskImage = mask
        switch mode {
        case .normal:
            return cam
        case .blur:
            blend.backgroundImage = blurred(cam)
        case .image:
            guard let background else { blend.backgroundImage = blurred(cam); break }
            let fill = max(extent.width / background.extent.width,
                           extent.height / background.extent.height)
            var fitted = background.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
            fitted = fitted.transformed(by: CGAffineTransform(
                translationX: extent.midX - fitted.extent.midX,
                y: extent.midY - fitted.extent.midY))
                .cropped(to: extent)
            blend.backgroundImage = fitted
        }
        return (blend.outputImage ?? cam).cropped(to: extent)
    }

    /// Upstream blurs at full size with sigma = width / 50. That is a very
    /// wide kernel at 1080p, every frame. A blur this strong has no detail to
    /// lose, so it is done at a quarter of the size and scaled back up: the
    /// same look for about a sixteenth of the pixels.
    private static func blurred(_ cam: CIImage) -> CIImage {
        let extent = cam.extent
        let down: CGFloat = 0.25
        let small = cam.transformed(by: CGAffineTransform(scaleX: down, y: down))
        let smallExtent = small.extent
        return small.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(extent.width) / 50 * Double(down))
            .cropped(to: smallExtent)
            .transformed(by: CGAffineTransform(scaleX: 1 / down, y: 1 / down))
            .cropped(to: extent)
    }
}

// MARK: - The mask, tidied

/// Keeps only the largest person region of Vision's mask, then smooths it over
/// time. One per camera; used from that camera's capture queue only.
///
/// Vision marks EVERY person (and whatever clings to them): someone walking
/// behind the subject would survive as a floating fragment. The largest
/// connected region of the mask is the main subject. Blending each frame's mask
/// with the previous one stops the edge flickering.
final class MaskRefiner {

    // Scratch storage for the connected-component pass. Raw buffers and while
    // loops, not arrays: per-pixel array access in an unoptimised (Debug)
    // build took ~140 ms a frame upstream.
    private let scratch = ComponentScratch()
    private var smoothedMaskBuffer: CVPixelBuffer?
    private var maskPool: CVPixelBufferPool?

    /// One context for every camera: building one per frame is the classic
    /// way to make a cheap thing expensive.
    private static let context = CIContext()

    /// Nil in, nil out. Modifies `raw` in place (it is Vision's own result,
    /// not used for anything else).
    func refine(_ raw: CVPixelBuffer?) -> CVPixelBuffer? {
        smoothedMask(from: keepDominantRegion(raw))
    }

    /// Forget the previous frame (the effect was turned off).
    func reset() {
        smoothedMaskBuffer = nil
    }

    /// Runs on the low-res mask, modifying it in place.
    private func keepDominantRegion(_ buffer: CVPixelBuffer?) -> CVPixelBuffer? {
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return buffer }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let threshold: UInt8 = 32
        let count = width * height
        scratch.reserve(count)
        let labels = scratch.labels
        let parent = scratch.parent
        let area = scratch.area
        labels.update(repeating: 0, count: count)

        func find(_ start: Int32) -> Int32 {
            var x = start
            while parent[Int(x)] != x {
                parent[Int(x)] = parent[Int(parent[Int(x)])]
                x = parent[Int(x)]
            }
            return x
        }

        // Two-pass labeling with union-find (4-connectivity); label 0 is
        // the background.
        var next: Int32 = 1
        var y = 0
        while y < height {
            let row = pixels + y * bytesPerRow
            let line = labels + y * width
            var x = 0
            while x < width {
                if row[x] >= threshold {
                    let left: Int32 = x > 0 ? line[x - 1] : 0
                    let up: Int32 = y > 0 ? line[x - width] : 0
                    if left == 0, up == 0 {
                        parent[Int(next)] = next
                        line[x] = next
                        next += 1
                    } else if left != 0, up != 0 {
                        let rootLeft = find(left), rootUp = find(up)
                        line[x] = rootLeft
                        if rootLeft != rootUp { parent[Int(rootUp)] = rootLeft }
                    } else {
                        line[x] = left != 0 ? left : up
                    }
                }
                x += 1
            }
            y += 1
        }
        // Area per root; the person is the biggest region.
        area.update(repeating: 0, count: Int(next))
        var i = 0
        while i < count {
            if labels[i] != 0 { area[Int(find(labels[i]))] += 1 }
            i += 1
        }
        var best: Int32 = 0
        var bestArea: Int32 = 0
        var root: Int32 = 1
        while root < next {
            if parent[Int(root)] == root, area[Int(root)] > bestArea {
                best = root
                bestArea = area[Int(root)]
            }
            root += 1
        }
        // Which labels belong to the subject (reusing `area`: 1 = keep).
        var label: Int32 = 1
        while label < next {
            area[Int(label)] = find(label) == best ? 1 : 0
            label += 1
        }
        // Erase everything that isn't connected to the main subject
        // (detached blobs AND their soft sub-threshold halos).
        y = 0
        while y < height {
            let row = pixels + y * bytesPerRow
            let line = labels + y * width
            var x = 0
            while x < width {
                if row[x] > 0 {
                    let l = line[x]
                    if l == 0 || area[Int(l)] == 0 { row[x] = 0 }
                }
                x += 1
            }
            y += 1
        }
        return buffer
    }

    /// Exponential moving average over masks: 65% previous + 35% current,
    /// rendered into a pooled buffer so the CI graph never grows.
    private func smoothedMask(from raw: CVPixelBuffer?) -> CVPixelBuffer? {
        guard let raw else {
            smoothedMaskBuffer = nil
            return nil
        }
        let width = CVPixelBufferGetWidth(raw)
        let height = CVPixelBufferGetHeight(raw)
        let rawImage = CIImage(cvPixelBuffer: raw)

        var blended = rawImage
        if let previous = smoothedMaskBuffer,
           CVPixelBufferGetWidth(previous) == width,
           CVPixelBufferGetHeight(previous) == height {
            let mix = CIFilter.dissolveTransition()
            mix.inputImage = CIImage(cvPixelBuffer: previous)
            mix.targetImage = rawImage
            mix.time = 0.35
            blended = (mix.outputImage ?? rawImage).cropped(to: rawImage.extent)
        }

        if maskPool == nil || smoothedMaskBuffer.map({ CVPixelBufferGetWidth($0) != width }) == true {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_OneComponent8,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
            maskPool = pool
        }
        guard let maskPool else { return raw }
        var rendered: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, maskPool, &rendered)
        guard let rendered else { return raw }
        Self.context.render(blended, to: rendered, bounds: rawImage.extent,
                            colorSpace: CGColorSpaceCreateDeviceGray())
        smoothedMaskBuffer = rendered
        return rendered
    }
}

/// Reusable raw buffers for the connected-component pass.
private final class ComponentScratch {
    private var capacity = 0
    private(set) var labels = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    /// Label -> parent label (union-find).
    private(set) var parent = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private(set) var area = UnsafeMutablePointer<Int32>.allocate(capacity: 1)

    /// Room for `count` pixels, and as many labels, the most a mask can hold.
    func reserve(_ count: Int) {
        guard count + 1 > capacity else { return }
        free()
        capacity = count + 1
        labels = .allocate(capacity: capacity)
        parent = .allocate(capacity: capacity)
        area = .allocate(capacity: capacity)
    }

    private func free() {
        labels.deallocate()
        parent.deallocate()
        area.deallocate()
    }

    deinit { free() }
}
