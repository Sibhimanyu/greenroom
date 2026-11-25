//
//  SolidSheet.swift
//  Greenroom
//
//  The solid backdrop of a window the class sees (WindowFrost lays it over the frost). AppKit only, so
//  the test target compiles it.
//
import AppKit

/// The solid backdrop. A dynamic colour (windowBackgroundColor) resolved into a
/// CGColor is frozen at that moment, so the sheet re-resolves it whenever its
/// appearance changes; otherwise a light/dark switch left white text on a white
/// sheet (or dark on dark).
final class SolidSheet: NSView {
    let color: NSColor
    init(frame: NSRect, color: NSColor) {
        self.color = color
        super.init(frame: frame)
        wantsLayer = true
        resolve()
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolve()
    }
    /// The colour as it looks under this view's current appearance.
    func resolve() {
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        layer?.backgroundColor = resolved
    }
}
