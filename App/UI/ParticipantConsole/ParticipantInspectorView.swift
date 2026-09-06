//
//  ParticipantInspectorView.swift
//  Greenroom
//
//  One student, and what you can do about them.
//
//  Phase 3 of docs/participant-window-redesign-plan.md. This replaces a strip
//  pinned along the bottom of the window that was a third competing region:
//  always in the layout, empty most of the time, and holding controls for a
//  person who may not be selected. The plan's rule is that a participant
//  control appears only in the context of the chosen person, so this is a
//  drawer over the grid's right edge, and it does not exist when nothing is
//  selected.
//
//  It takes the buttons rather than building them. Every per-participant
//  action already exists with its own confirmation and its own wording - mute
//  is a command, unmute is a request, and that distinction was learned the
//  hard way - so the inspector arranges them and nothing more.
//
import AppKit

final class ParticipantInspectorView: NSView {

    /// The plan's range is 280-320pt. 300 holds "Ask to start video" on one
    /// line at 12pt, which is the longest label here.
    static let width: CGFloat = 300
    private static let pad: CGFloat = 16
    private static let rowHeight: CGFloat = 30
    private static let rowGap: CGFloat = 6

    private let name = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private lazy var closeButton = ClosureButton { [weak self] in self?.onClose?() }
    private var controls: [NSView] = []

    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.98).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.cornerRadius = 14        // DESIGN.md radius-lg: this is a panel

        name.font = .systemFont(ofSize: 17, weight: .semibold)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        addSubview(name)

        // One line of plain words, not a row of coloured dots. The plan asks
        // for a state that does not depend on colour alone.
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        addSubview(status)

        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Close"
        closeButton.setAccessibilityLabel("Close inspector")
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { nil }

    /// Writes the panel for one person. `controls` are the buttons the window
    /// already built, in the order they should appear.
    func apply(name personName: String, status statusText: String, controls next: [NSView]) {
        name.stringValue = personName
        status.stringValue = statusText
        status.isHidden = statusText.isEmpty
        guard controls != next else { return }
        controls.forEach { $0.removeFromSuperview() }
        controls = next
        for control in controls { addSubview(control) }
        needsLayout = true
    }

    /// How tall the panel needs to be for the controls it holds.
    func height() -> CGFloat {
        let head: CGFloat = 24 + (status.stringValue.isEmpty ? 0 : 20) + 12
        let rows = CGFloat(controls.count) * (Self.rowHeight + Self.rowGap)
        return Self.pad * 2 + head + max(0, rows - Self.rowGap)
    }

    override func layout() {
        super.layout()
        let pad = Self.pad
        let inner = bounds.width - pad * 2
        var y = bounds.height - pad - 24
        closeButton.frame = NSRect(x: bounds.width - pad - 20, y: y + 2, width: 20, height: 20)
        name.frame = NSRect(x: pad, y: y, width: inner - 28, height: 24)
        if !status.stringValue.isEmpty {
            y -= 20
            status.frame = NSRect(x: pad, y: y, width: inner, height: 18)
        }
        y -= 12
        for control in controls {
            y -= Self.rowHeight
            control.frame = NSRect(x: pad, y: y, width: inner, height: Self.rowHeight)
            y -= Self.rowGap
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private func == (a: [NSView], b: [NSView]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0 === $1 }
}

private func != (a: [NSView], b: [NSView]) -> Bool { !(a == b) }
