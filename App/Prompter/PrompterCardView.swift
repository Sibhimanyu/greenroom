//
//  PrompterCardView.swift
//  Greenroom
//
//  One suggestion as a row: picture, kind, title, where it came from, and the
//  three things you can do with it. AppKit, because it lives in two AppKit
//  surfaces (the participants panel's rail and a menu-bar popover), and
//  updated in place because the rail learned long ago that rebuilding views on
//  a poll drops clicks.
//
import AppKit

final class PrompterCardView: NSView {

    static let height: CGFloat = 64
    private static let imageSide: CGFloat = 56

    private let image = NSImageView()
    private let eyebrow = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private lazy var openButton = ClosureButton { [weak self] in self?.fire(self?.onOpen) }
    private lazy var sendButton = ClosureButton { [weak self] in self?.fire(self?.onSend) }
    private lazy var dismissButton = ClosureButton { [weak self] in self?.fire(self?.onDismiss) }

    private(set) var card: PrompterCard?
    var onOpen: ((PrompterCard) -> Void)?
    var onSend: ((PrompterCard) -> Void)?
    var onDismiss: ((PrompterCard) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10 // DESIGN.md radius-md
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor

        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.cornerRadius = 6 // DESIGN.md radius-sm
        image.layer?.masksToBounds = true
        image.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.25).cgColor
        addSubview(image)

        // Machine facts in mono, prose in the system face (DESIGN.md).
        eyebrow.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        eyebrow.textColor = .tertiaryLabelColor
        eyebrow.lineBreakMode = .byTruncatingTail
        addSubview(eyebrow)

        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        addSubview(title)

        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.maximumNumberOfLines = 1
        addSubview(subtitle)

        for (button, label, symbol, tip) in [
            (openButton, "Open", "arrow.up.right.square", "Open in the main-pane browser"),
            (sendButton, "Send", "paperplane", "Send the link to the class chat"),
            (dismissButton, "", "xmark", "Dismiss")
        ] {
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.imagePosition = label.isEmpty ? .imageOnly : .imageLeading
            button.title = label
            button.toolTip = tip
            button.setAccessibilityLabel(label.isEmpty ? tip : label)
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { nil }

    private func fire(_ action: ((PrompterCard) -> Void)?) {
        guard let card else { return }
        action?(card)
    }

    /// Rewrites the row for a card. Returns without touching anything when the
    /// same card is already shown, so the poll does not repaint a stable row.
    func apply(_ next: PrompterCard, canSend: Bool) {
        let changed = card?.id != next.id || card?.thumbnail !== next.thumbnail
        card = next
        sendButton.isEnabled = canSend
        sendButton.alphaValue = canSend ? 1 : 0.4
        sendButton.toolTip = canSend ? "Send the link to the class chat" : "Send needs the meeting chat to be connected"
        guard changed else { return }
        eyebrow.stringValue = "\(next.kind.eyebrow)   \(next.source.label.uppercased())"
        title.stringValue = next.title
        subtitle.stringValue = next.subtitle
        title.toolTip = next.url.absoluteString
        image.image = next.thumbnail ?? Self.placeholder(for: next.kind)
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
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: kind.eyebrow)
        return image?.withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 4
        let side = Self.imageSide
        image.frame = NSRect(x: pad, y: (bounds.height - side) / 2, width: side, height: side)

        let buttonHeight: CGFloat = 20
        let dismissWidth: CGFloat = 24
        let actionWidth: CGFloat = 60
        let buttonY = pad
        var right = bounds.width - pad
        dismissButton.frame = NSRect(x: right - dismissWidth, y: buttonY, width: dismissWidth, height: buttonHeight)
        right -= dismissWidth + 4
        sendButton.frame = NSRect(x: right - actionWidth, y: buttonY, width: actionWidth, height: buttonHeight)
        right -= actionWidth + 4
        openButton.frame = NSRect(x: right - actionWidth, y: buttonY, width: actionWidth, height: buttonHeight)

        let textX = pad + side + 8
        let textWidth = bounds.width - textX - pad
        eyebrow.frame = NSRect(x: textX, y: bounds.height - pad - 13, width: textWidth, height: 13)
        title.frame = NSRect(x: textX, y: bounds.height - pad - 13 - 17, width: textWidth, height: 17)
        // The subtitle shares its row with the buttons, so it stops where they
        // start.
        let subtitleWidth = max(0, right - actionWidth - 8 - textX)
        subtitle.frame = NSRect(x: textX, y: buttonY + 3, width: subtitleWidth, height: 14)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
