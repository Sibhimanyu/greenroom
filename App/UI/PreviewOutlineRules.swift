//
//  PreviewOutlineRules.swift
//
//  Where Home's preview draws the layout's outlines: the screen inside the
//  picture inside the card, for any display shape. Pure, so it is tested.
//
//  The picture is a canvas (16:9 today) fitted in the card. The shared display
//  is fitted inside the canvas, so a 16:10 Mac gets bars at the sides and an
//  ultrawide gets them above and below (StageRenderer.place). Presenter puts
//  the screen in a box at the right, 78% of the canvas.
//
import CoreGraphics

enum PreviewOutlineRules {

    /// `aspect` fitted and centred in `box`.
    static func fit(_ aspect: CGFloat, in box: CGRect) -> CGRect {
        guard aspect > 0, box.width > 0, box.height > 0 else { return .zero }
        let w = min(box.width, box.height * aspect), h = w / aspect
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

    /// The canvas in the card, and the screen in the canvas.
    static func frames(card: CGSize, canvasAspect: CGFloat?, screen: CGSize, presenter: Bool)
        -> (canvas: CGRect, screen: CGRect) {
        let screenAspect = screen.width / max(screen.height, 1)
        let canvas = fit(canvasAspect ?? screenAspect, in: CGRect(origin: .zero, size: card))
        let box = presenter
            ? CGRect(x: canvas.maxX - canvas.width * (0.025 + 0.78), y: canvas.midY - canvas.height * 0.39,
                     width: canvas.width * 0.78, height: canvas.height * 0.78)
            : canvas
        return (canvas, fit(screenAspect, in: box))
    }

    /// A window frame (AppKit coordinates, bottom-left origin) as a fraction of
    /// the display it is on, top-left origin; nil when it is not on it.
    static func fraction(of frame: CGRect, on display: CGRect) -> CGRect? {
        let f = frame.intersection(display)
        guard !f.isNull, f.width > 8, f.height > 8, display.width > 0, display.height > 0 else { return nil }
        return CGRect(x: (f.minX - display.minX) / display.width, y: (display.maxY - f.maxY) / display.height,
                      width: f.width / display.width, height: f.height / display.height)
    }

    /// A fraction placed on the screen rect.
    static func place(_ fraction: CGRect, in screen: CGRect) -> CGRect {
        CGRect(x: screen.minX + fraction.minX * screen.width, y: screen.minY + fraction.minY * screen.height,
               width: fraction.width * screen.width, height: fraction.height * screen.height)
    }
}
