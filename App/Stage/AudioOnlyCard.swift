//
//  AudioOnlyCard.swift
//  Greenroom
//
//  The picture for a stretch where nothing visual is shared and there is no
//  camera picture: a clean "Audio only" card, so every recording and every
//  meeting frame has a picture. Phase 5 of the Recorditor port (upstream's
//  `appendStillFrame` wrote the same idea into its own writer; here the Stage
//  already emits a frame on its clock, so this is only the picture).
//
//  Colours are the DESIGN.md neutrals: `--ink` backdrop, white text, `--faint`
//  caption. The type is the system font.
//
import AppKit
import CoreImage

enum AudioOnlyCard {
    /// A canvas-sized, opaque card. Drawn once per canvas size by the renderer.
    static func image(size: CGSize) -> CIImage? {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }

        // `--ink` #101828 (the Stage's own backdrop), so the card is the same
        // ground the camera and the screen sit on.
        NSColor(srgbRed: 16.0 / 255, green: 24.0 / 255, blue: 40.0 / 255, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()

        let unit = size.height / 1080
        let title = NSAttributedString(string: "Audio only", attributes: [
            .font: NSFont.systemFont(ofSize: 64 * unit, weight: .semibold),
            .foregroundColor: NSColor.white,
            .kern: -0.02 * 64 * unit,
        ])
        // `--faint` #98A2B3.
        let caption = NSAttributedString(string: "No camera or screen is on.", attributes: [
            .font: NSFont.systemFont(ofSize: 26 * unit, weight: .regular),
            .foregroundColor: NSColor(srgbRed: 152.0 / 255, green: 162.0 / 255, blue: 179.0 / 255, alpha: 1),
        ])

        let glyphSide = 120 * unit
        let gap = 28 * unit
        let titleSize = title.size(), captionSize = caption.size()
        let total = glyphSide + gap + titleSize.height + 10 * unit + captionSize.height
        var y = (size.height + total) / 2   // top of the stack, bottom-left coordinates

        if let symbol = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil) {
            let configuration = NSImage.SymbolConfiguration(pointSize: glyphSide, weight: .regular)
                .applying(.init(paletteColors: [NSColor.white.withAlphaComponent(0.92)]))
            let drawn = symbol.withSymbolConfiguration(configuration) ?? symbol
            let ratio = drawn.size.width / max(drawn.size.height, 1)
            let h = glyphSide, w = h * ratio
            drawn.draw(in: NSRect(x: (size.width - w) / 2, y: y - h, width: w, height: h))
        }
        y -= glyphSide + gap
        title.draw(at: NSPoint(x: (size.width - titleSize.width) / 2, y: y - titleSize.height))
        y -= titleSize.height + 10 * unit
        caption.draw(at: NSPoint(x: (size.width - captionSize.width) / 2, y: y - captionSize.height))

        guard let cg = context.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }
}
