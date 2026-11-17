//
//  WindowFrost.swift
//  Greenroom
//
//  The window background that says who sees a window. A window only you see is
//  frosted: its BACKGROUND is see-through (a behind-window visual effect), while
//  text, controls, images and video stay fully opaque on top. A window the class
//  sees is solid, and carries the amber edge (ShareBorderOverlay). Never the
//  window's alphaValue, never faded content. With Reduce Transparency on, the
//  system draws the frost solid by itself; the edge still carries the signal.
//  The decision is WindowBackdrop (ShareVisibilityRules.swift, tested).
//
import AppKit

@MainActor
enum WindowFrost {
    /// One frost for every window only you see, so they all read alike
    /// (owner, 2026-11-16: "a uniform transparency"). The meeting windows are
    /// dark appearance, so the same material draws dark there.
    static let material: NSVisualEffectView.Material = .underWindowBackground

    private static let frostID = NSUserInterfaceItemIdentifier("greenroom.window.frost")
    private static let solidID = NSUserInterfaceItemIdentifier("greenroom.window.solid")

    /// Puts the frost under the window's content, and a solid sheet of `solid`
    /// above it that is invisible until `show(.solid)`. The window's own
    /// background goes clear, so the content views must not paint a full
    /// background of their own.
    static func install(in window: NSWindow, material: NSVisualEffectView.Material = WindowFrost.material, solid: NSColor,
                        backdrop: WindowBackdrop = .frosted) {
        guard let frame = window.contentView?.superview,
              frame.subviews.first(where: { $0.identifier == frostID }) == nil else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        // The title bar is part of the frosted background, not a band on top.
        window.titlebarAppearsTransparent = true
        let frost = NSVisualEffectView(frame: frame.bounds)
        frost.identifier = frostID
        frost.material = material
        frost.blendingMode = .behindWindow
        frost.state = .active
        frost.autoresizingMask = [.width, .height]
        let sheet = NSView(frame: frame.bounds)
        sheet.identifier = solidID
        sheet.wantsLayer = true
        sheet.layer?.backgroundColor = solid.cgColor
        sheet.layer?.opacity = backdrop == .solid ? 1 : 0
        sheet.autoresizingMask = [.width, .height]
        frame.addSubview(frost, positioned: .below, relativeTo: window.contentView)
        frame.addSubview(sheet, positioned: .below, relativeTo: window.contentView)
    }

    /// Frosted while only you see the window, solid while the class does.
    static func show(_ backdrop: WindowBackdrop, in window: NSWindow) {
        guard let sheet = window.contentView?.superview?.subviews.first(where: { $0.identifier == solidID }),
              let layer = sheet.layer else { return }
        let target: Float = backdrop == .solid ? 1 : 0
        guard layer.opacity != target else { return }
        let duration = WindowBackdrop.transitionDuration(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let from = layer.presentation()?.opacity ?? layer.opacity
        layer.opacity = target
        guard duration > 0 else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = target
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "frostSolid")
    }
}

import SwiftUI

/// Attach to a SwiftUI window's root view: the window's background becomes the
/// frost, the SwiftUI content stays opaque on it. The main window is never in
/// the class's picture.
struct FrostedWindow: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    final class Anchor: NSView {
        var material: NSVisualEffectView.Material = .underWindowBackground
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            MainActor.assumeIsolated {
                WindowFrost.install(in: window, material: material, solid: .windowBackgroundColor)
            }
        }
    }

    func makeNSView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.material = material
        return anchor
    }

    func updateNSView(_ anchor: Anchor, context: Context) {}
}
