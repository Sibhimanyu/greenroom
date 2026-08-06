//
//  MaskImageGenerator.swift
//  Greenroom
//
//  Renders and caches a white-shape-on-transparent PNG for each non-square
//  WebcamShape, for OBS's built-in "Image Mask/Blend" filter to use as an
//  alpha mask (filterKind "mask_filter_v2", type "mask_alpha_filter.effect" -
//  confirmed by reading OBS's own bundled .effect shader files rather than
//  guessing, the same way the input/filter *kinds* elsewhere in this app are
//  resolved by asking OBS directly instead of hardcoding version-specific
//  strings).
//
import AppKit

enum MaskImageGenerator {

    private static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Greenroom", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `nil` for `.square` - that shape needs no mask at all, just the
    /// existing rectangular bounding-box crop already applied to the bubble.
    static func maskImageURL(for shape: WebcamShape, size: Int = 512) -> URL? {
        // Square needs no mask (the bounding-box crop is the shape), and
        // Cutout deliberately has none - the chroma key does the shaping
        // there. Callers treat nil as "remove any existing mask filter".
        guard shape != .square, shape != .cutout else { return nil }

        let url = directory.appendingPathComponent("mask_\(shape.rawValue)_\(size).png")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        guard let pngData = renderMaskPNG(shape: shape, size: size) else { return nil }
        try? pngData.write(to: url)
        return url
    }

    private static func renderMaskPNG(shape: WebcamShape, size: Int) -> Data? {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        let inset: CGFloat = 2
        let rect = NSRect(x: inset, y: inset, width: CGFloat(size) - inset * 2, height: CGFloat(size) - inset * 2)
        let path: NSBezierPath
        switch shape {
        case .square, .cutout: // neither reaches here (see maskImageURL)
            path = NSBezierPath(rect: rect)
        case .circle:
            path = NSBezierPath(ovalIn: rect)
        case .roundedRectangle:
            let radius = rect.width * 0.18
            path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        }
        NSColor.white.setFill()
        path.fill()
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
