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
    /// - Parameter aspect: width/height of the frame the mask will be stretched
    ///   over. OBS's Image Mask/Blend stretches the image across the whole
    ///   source, so a square mask on a 16:9 frame turns a circle into an
    ///   ellipse and skews a rounded rectangle's corners. `screenPanelMaskURL`
    ///   below already rendered at the target aspect for exactly this reason;
    ///   the webcam's mask did not, which is how the "Circle" bubble came to be
    ///   an oval in the real composite while the settings schematic drew a
    ///   perfect circle.
    ///
    ///   Pass 1 when the source is cropped square before the mask (the circle
    ///   path), and the camera's own aspect when it is not.
    static func maskImageURL(for shape: WebcamShape, aspect: Double = 1, size: Int = 512) -> URL? {
        // Square needs no mask (the bounding-box crop is the shape), and
        // the chroma-keyed modes deliberately have none - the key does the
        // shaping there. Callers treat nil as "remove any existing mask
        // filter".
        guard shape == .circle || shape == .roundedRectangle else { return nil }

        let safeAspect = aspect.isFinite && aspect > 0 ? aspect : 1
        let width = size
        let height = max(1, Int((Double(size) / safeAspect).rounded()))
        let tag = String(format: "%.3f", safeAspect)

        let url = directory.appendingPathComponent("mask_\(shape.rawValue)_\(width)x\(height)_\(tag).png")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        guard let pngData = renderMaskPNG(shape: shape, width: width, height: height) else { return nil }
        try? pngData.write(to: url)
        return url
    }

    /// Rounded-rectangle mask for the Presenter mode's inset screen panel,
    /// rendered at the CANVAS's aspect ratio - the mask image gets
    /// stretched over the whole source, so a square mask would distort the
    /// corner radii on a widescreen panel. Radius is gentle (2.5% of
    /// width), matching the system Presenter Overlay's panel look.
    static func screenPanelMaskURL(canvasWidth: Int, canvasHeight: Int) -> URL? {
        guard canvasWidth > 0, canvasHeight > 0 else { return nil }
        let width = 1024
        let height = max(1, Int((Double(width) * Double(canvasHeight) / Double(canvasWidth)).rounded()))

        let url = directory.appendingPathComponent("mask_screen_panel_\(width)x\(height).png")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        let radius = rect.width * 0.025
        NSColor.white.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return nil }
        try? pngData.write(to: url)
        return url
    }

    private static func renderMaskPNG(shape: WebcamShape, width: Int, height: Int) -> Data? {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        let inset: CGFloat = 2
        let rect = NSRect(x: inset, y: inset,
                          width: CGFloat(width) - inset * 2, height: CGFloat(height) - inset * 2)
        let path: NSBezierPath
        switch shape {
        case .square, .cutout, .presenterLarge: // none reach here (see maskImageURL)
            path = NSBezierPath(rect: rect)
        case .circle:
            path = NSBezierPath(ovalIn: rect)
        case .roundedRectangle:
            // Off the SHORTER side, so the radius reads the same on a wide
            // frame as on a square one rather than growing with the width.
            let radius = min(rect.width, rect.height) * 0.18
            path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        }
        NSColor.white.setFill()
        path.fill()
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
