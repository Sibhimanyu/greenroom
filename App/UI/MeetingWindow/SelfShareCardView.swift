//
//  SelfShareCardView.swift
//  Greenroom
//
//  The card shown in place of the stage while you share your own screen.
//
import AppKit
import SwiftUI
import Combine

/// Where the picture would be while you are sharing a screen through Zoom: it
/// says so, and says the camera picture carries on. Zoom shows the sharer no
/// view of their own share in custom UI, so without it the stage looks idle.
@MainActor
final class SelfShareCardView: NSView {
    static let size = NSSize(width: 360, height: 132)
    private let title = NSTextField(labelWithString: "You are sharing your screen")
    private let detail = NSTextField(wrappingLabelWithString: "Everyone sees your shared display. Your camera picture keeps going underneath.")
    private lazy var stop: ClosureButton = {
        let button = ClosureButton { [weak self] in self?.onStop() }
        button.title = "Stop sharing"
        button.bezelStyle = .rounded
        button.contentTintColor = .systemRed
        return button
    }()
    private let onStop: () -> Void

    init(onStop: @escaping () -> Void) {
        self.onStop = onStop
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        layer?.cornerRadius = 14          // DESIGN.md radius-lg: a card
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        for view in [title, detail, stop] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityLabel("You are sharing your screen")
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let pad: CGFloat = 20
        title.frame = NSRect(x: pad, y: bounds.height - 44, width: bounds.width - pad * 2, height: 24)
        detail.frame = NSRect(x: pad, y: 52, width: bounds.width - pad * 2, height: 40)
        stop.sizeToFit()
        stop.frame = NSRect(x: (bounds.width - stop.frame.width - 16) / 2, y: 14,
                            width: stop.frame.width + 16, height: 28)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
