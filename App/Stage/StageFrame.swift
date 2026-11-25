//
//  StageFrame.swift
//  Greenroom
//
//  Where the shared content sits on the compositor's output, as one pure function the renderer
//  (`StageRenderer.compose`) and the Layouts tab's Preview: Everyone both call. Top-left origin.
//
import CoreGraphics

enum StageFrame {
    enum ShareKind: Equatable { case wholeScreen, window, whiteboard, justMe }

    /// The compositor's output (1920x1080).
    static let output = CGSize(width: 1920, height: 1080)

    /// Where a shared source of `sourceAspect` (width over height) is drawn; nil when nothing is shared
    /// (Just me: the camera is the picture).
    /// - Whole screen and Whiteboard: aspect-fitted in the whole output (margin 0).
    /// - Window or app: the window alone, in the output less a 4.5% (of height) margin.
    /// - Presenter (with any share): a panel 78% of the output, 2.5% of the width from the right, centred.
    static func contentRect(shareKind: ShareKind, sourceAspect: CGFloat, presenter: Bool,
                            output: CGSize = StageFrame.output) -> CGRect? {
        guard shareKind != .justMe else { return nil }
        let box: CGRect
        if presenter {
            let w = output.width * 0.78, h = output.height * 0.78
            box = CGRect(x: output.width - output.width * 0.025 - w, y: (output.height - h) / 2, width: w, height: h)
        } else {
            let m = shareKind == .window ? output.height * 0.045 : 0
            box = CGRect(x: m, y: m, width: output.width - 2 * m, height: output.height - 2 * m)
        }
        return fit(aspect: sourceAspect, in: box)
    }

    /// The largest rect of `aspect` that fits `box`, centred in it.
    static func fit(aspect: CGFloat, in box: CGRect) -> CGRect {
        let a = max(aspect, 0.01)
        let s = min(box.width / a, box.height)         // the height of the fitted rect
        let w = s * a
        return CGRect(x: box.midX - w / 2, y: box.midY - s / 2, width: w, height: s)
    }

    /// Where the camera is drawn over shared content: Presenter's big fixed placement, else
    /// `PresenceGeometry.cameraRect` bounded by the drawn content so it never leaves it (the whole
    /// output while no content has arrived). With nothing shared the camera fills the output (`fit`).
    /// `aspect` is the picture's width over height after the shape's crop (1 for the circle).
    static func cameraRect(box: PresenceBox, shape: WebcamShape, aspect: Double, content: CGRect?,
                           output: CGSize = StageFrame.output) -> CGRect {
        if shape == .presenterLarge {
            let h = output.height * 1.12, w = h * aspect
            return CGRect(x: output.width * 0.24 - w / 2, y: -output.height * 0.02, width: w, height: h)
        }
        return PresenceGeometry.cameraRect(for: box, aspect: aspect, canvas: output, bounds: content)
    }
}
