//
//  CueCardView.swift
//  Greenroom
//
//  One suggestion as a row: picture, kind, title, where it came from, and the
//  three things you can do with it. AppKit, because it lives in two AppKit
//  surfaces (the participants panel's rail and a menu-bar popover), and
//  updated in place because the rail learned long ago that rebuilding views on
//  a poll drops clicks.
//
//  What this used to look like, and why it changed. Three text rows and a row
//  of bezelled buttons were packed into 64pt on 4pt of padding, and the
//  subtitle shared its line with the buttons - so on a 528pt column it was cut
//  to less than half the width it had room for. Three cards meant nine framed
//  buttons stacked down the rail, all shouting equally. And the card had no
//  hover state at all, so the one thing a teacher is meant to reach for mid
//  lesson did not react to the pointer.
//
//  The fix is mostly subtraction, per DESIGN.md ("decoration level: minimal",
//  and start from the assumption that everything is noise). The buttons lose
//  their bezels and their labels and become quiet glyphs on the right; the
//  text rows take the width that frees and get real leading; the whole card
//  becomes the Open target, because Open is what the card is FOR and a
//  mindless click should not have to find a 60pt button. Hover lifts the
//  surface 150ms (DESIGN.md motion) so the thing reads as clickable before it
//  is clicked.
//
import AppKit

final class CueCardView: NSView {

    /// Unchanged at 64pt on purpose. The extra air comes from deleting the
    /// button row, not from taking height off the self view, which is the
    /// only block in the rail big enough to pay for it.
    static let height: CGFloat = 64
    private static let imageSide: CGFloat = 48
    private static let pad: CGFloat = 8
    private static let glyph: CGFloat = 22

    private let image = NSImageView()
    private let eyebrow = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private lazy var openButton = ClosureButton { [weak self] in self?.fire(self?.onOpen) }
    private lazy var sendButton = ClosureButton { [weak self] in self?.fire(self?.onSend) }
    private lazy var dismissButton = ClosureButton { [weak self] in self?.fire(self?.onDismiss) }

    private var hovering = false
    private var pressOrigin: NSPoint?

    private(set) var card: CueCard?
    var onOpen: ((CueCard) -> Void)?
    var onSend: ((CueCard) -> Void)?
    var onDismiss: ((CueCard) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10 // DESIGN.md radius-md
        layer?.borderWidth = 1
        applySurface()

        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.cornerRadius = 6 // DESIGN.md radius-sm
        image.layer?.masksToBounds = true
        image.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.22).cgColor
        image.contentTintColor = .secondaryLabelColor
        addSubview(image)

        // Machine facts in mono, prose in the system face (DESIGN.md). The
        // tracking is the brand's typographic signature; the colour stays a
        // system semantic one because the panel follows macOS appearance and
        // a hardcoded brand green would be unreadable in the dark one.
        eyebrow.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        eyebrow.textColor = .tertiaryLabelColor
        eyebrow.lineBreakMode = .byTruncatingTail
        addSubview(eyebrow)

        title.font = .systemFont(ofSize: 13.5, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        addSubview(title)

        subtitle.font = .systemFont(ofSize: 11.5)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.maximumNumberOfLines = 1
        addSubview(subtitle)

        // Borderless glyphs, not bezelled buttons with labels. Nine framed
        // controls down a rail read as a toolbar; nine glyphs read as three
        // cards that happen to have actions.
        for (button, symbol, tip, label) in [
            (openButton, "arrow.up.right", "Open in the main-pane browser", "Open"),
            (sendButton, "paperplane", "Send the link to the class chat", "Send"),
            (dismissButton, "xmark", "Dismiss this suggestion", "Dismiss")
        ] {
            button.isBordered = false
            button.bezelStyle = .accessoryBarAction
            button.imagePosition = .imageOnly
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = tip
            button.setAccessibilityLabel(label)
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { nil }

    private func fire(_ action: ((CueCard) -> Void)?) {
        guard let card else { return }
        action?(card)
    }

    // MARK: Surface

    /// The card's own background and hairline, for the current hover state.
    ///
    /// Two steps, both from system semantic colours so the panel keeps
    /// tracking macOS appearance. The resting surface is barely there; the
    /// hover step is the whole difference between a list and something you can
    /// pick up.
    private func applySurface() {
        let fill = hovering ? 0.20 : 0.10
        let line = hovering ? 0.55 : 0.22
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(fill).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(line).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    private func setHovering(_ next: Bool) {
        guard hovering != next, !isHidden else { return }
        hovering = next
        // 150ms, the fast end of DESIGN.md's hover range.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: next ? .easeOut : .easeIn)
            context.allowsImplicitAnimation = true
            applySurface()
            for button in [openButton, sendButton, dismissButton] {
                button.contentTintColor = next ? .labelColor : .secondaryLabelColor
            }
        }
    }

    // MARK: The card itself opens

    /// Open is what a card is for, so the card is the target.
    ///
    /// Reaching for a 60pt button mid-lesson is a decision; clicking the thing
    /// you are already looking at is not. The glyph on the right stays, so the
    /// affordance is visible rather than hidden behind the pointer - hover
    /// tells you it is live, it does not tell you it exists.
    ///
    /// Tracked from mouseDown to mouseUp with a small tolerance so a drag on
    /// the rail's scroll view is a scroll and not an accidental tab.
    override func mouseDown(with event: NSEvent) {
        pressOrigin = event.locationInWindow
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressOrigin = nil }
        guard let origin = pressOrigin else { return }
        let moved = hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y)
        guard moved < 4 else { return }
        fire(onOpen)
    }

    /// Rewrites the row for a card. Returns without touching anything when the
    /// same card is already shown, so the poll does not repaint a stable row.
    func apply(_ next: CueCard, canSend: Bool) {
        let changed = card?.id != next.id || card?.thumbnail !== next.thumbnail
        card = next
        sendButton.isEnabled = canSend
        sendButton.alphaValue = canSend ? 1 : 0.35
        sendButton.toolTip = canSend ? "Send the link to the class chat" : "Send needs the meeting chat to be connected"
        guard changed else { return }
        // Kind first, source second, separated rather than run together: they
        // answer different questions ("what is this" and "who says so").
        // Tracked .08em, which DESIGN.md calls the closest thing the brand has
        // to a typographic signature. NSTextField has no tracking of its own,
        // so the eyebrow is the one label here that is set as attributed text.
        eyebrow.attributedStringValue = NSAttributedString(
            string: "\(next.kind.eyebrow)  \u{00B7}  \(next.source.label.uppercased())",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .kern: 0.8
            ])
        title.stringValue = next.title
        subtitle.stringValue = next.subtitle
        toolTip = next.url.absoluteString
        image.image = next.thumbnail ?? Self.placeholder(for: next.kind)
        image.contentTintColor = next.thumbnail == nil ? .secondaryLabelColor : nil
        setAccessibilityLabel("\(next.kind.eyebrow): \(next.title). \(next.subtitle). From \(next.source.label).")
        needsLayout = true
    }

    private static func placeholder(for kind: Mention.Kind) -> NSImage? {
        let symbol: String
        switch kind {
        case .book: symbol = "book.closed"
        case .video: symbol = "play.rectangle"
        case .topic: symbol = "text.book.closed"
        case .person: symbol = "person"
        case .place: symbol = "mappin.and.ellipse"
        case .thing: symbol = "cube"
        case .word: symbol = "character.book.closed"
        case .quote: symbol = "quote.opening"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: kind.eyebrow)
        return image?.withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
    }

    override func layout() {
        super.layout()
        let pad = Self.pad
        let side = Self.imageSide
        image.frame = NSRect(x: pad, y: (bounds.height - side) / 2, width: side, height: side)

        // Three glyphs on the right, vertically centred as one group.
        let glyph = Self.glyph
        let gap: CGFloat = 2
        let column = glyph * 3 + gap * 2
        var x = bounds.width - pad - column
        let glyphY = (bounds.height - glyph) / 2
        for button in [openButton, sendButton, dismissButton] {
            button.frame = NSRect(x: x, y: glyphY, width: glyph, height: glyph)
            x += glyph + gap
        }

        // The text column now runs the whole way to the glyphs, because
        // nothing sits under it any more.
        let textX = pad + side + 12
        let textWidth = max(0, bounds.width - textX - pad - column - 8)
        let rows: CGFloat = 12 + 17 + 14
        var y = bounds.height - (bounds.height - rows) / 2 - 12
        eyebrow.frame = NSRect(x: textX, y: y, width: textWidth, height: 12)
        y -= 17
        title.frame = NSRect(x: textX, y: y, width: textWidth, height: 17)
        y -= 14
        subtitle.frame = NSRect(x: textX, y: y, width: textWidth, height: 14)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
