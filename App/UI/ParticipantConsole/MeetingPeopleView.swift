//
//  MeetingPeopleView.swift
//  Greenroom
//
//  The People panel's roster: raised hands first, in the order they went up,
//  then everyone else. A row opens that person's inspector; the roster itself
//  does no work, so every action keeps its one definition in the window.
//
//  Rows are a pool, rewritten in place on the one-second poll rather than torn
//  down: the same lesson the rail learned, a click that lands mid-rebuild hits
//  a row that no longer exists.
//
import AppKit

@MainActor
final class MeetingPeopleView: NSView {

    struct Row: Equatable {
        var id: UInt32
        var name: String
        var detail: String
        var handUp: Bool
        var muted: Bool
        var cameraOff: Bool
        var selected: Bool
    }

    var onSelect: ((UInt32) -> Void)?

    private let scroll = NSScrollView()
    private let document = FlippedView()
    private var rowViews: [UInt32: RowView] = [:]
    private let handsEyebrow = NSTextField(labelWithString: "")
    private let everyoneEyebrow = NSTextField(labelWithString: "")
    private var hands: [Row] = []
    private var everyone: [Row] = []

    private static let rowHeight: CGFloat = 44
    private static let eyebrowHeight: CGFloat = 28

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = document
        addSubview(scroll)
        for label in [handsEyebrow, everyoneEyebrow] {
            // Mono, uppercase eyebrows: DESIGN.md's one typographic signature.
            label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
            label.textColor = .tertiaryLabelColor
            document.addSubview(label)
        }
    }

    required init?(coder: NSCoder) { nil }

    /// `total` counts everyone in the meeting, you included, which is the number
    /// Zoom's own Participants button shows.
    func apply(hands: [Row], everyone: [Row], total: Int) {
        self.hands = hands
        self.everyone = everyone
        handsEyebrow.stringValue = "HANDS UP \u{00B7} \(hands.count)"
        everyoneEyebrow.stringValue = "IN THE MEETING \u{00B7} \(total)"

        let live = Set((hands + everyone).map(\.id))
        for (id, view) in rowViews where !live.contains(id) {
            view.removeFromSuperview()
            rowViews.removeValue(forKey: id)
        }
        for row in hands + everyone {
            let view = rowViews[row.id] ?? {
                let made = RowView()
                made.onClick = { [weak self] id in self?.onSelect?(id) }
                document.addSubview(made)
                rowViews[row.id] = made
                return made
            }()
            view.apply(row)
        }
        needsLayout = true
        layoutRows()
    }

    override func layout() {
        super.layout()
        layoutRows()
    }

    private func layoutRows() {
        scroll.frame = bounds
        let width = bounds.width
        var y: CGFloat = 4
        func place(_ label: NSTextField, show: Bool) {
            label.isHidden = !show
            guard show else { return }
            label.frame = NSRect(x: 16, y: y + 8, width: width - 32, height: 14)
            y += Self.eyebrowHeight
        }
        place(handsEyebrow, show: !hands.isEmpty)
        for row in hands {
            rowViews[row.id]?.frame = NSRect(x: 8, y: y, width: width - 16, height: Self.rowHeight)
            y += Self.rowHeight
        }
        place(everyoneEyebrow, show: true)
        for row in everyone {
            rowViews[row.id]?.frame = NSRect(x: 8, y: y, width: width - 16, height: Self.rowHeight)
            y += Self.rowHeight
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(y + 8, bounds.height))
    }

    // MARK: Rows

    /// Top-left origin, so rows stack down the way a list reads.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private final class RowView: NSView {
        var onClick: ((UInt32) -> Void)?
        private var id: UInt32 = 0
        private let name = NSTextField(labelWithString: "")
        private let detail = NSTextField(labelWithString: "")
        private let hand = NSView()
        private let mic = NSImageView()
        private let camera = NSImageView()
        private var selected = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerRadius = 10          // DESIGN.md radius-md
            name.font = .systemFont(ofSize: 13, weight: .medium)
            name.textColor = .labelColor
            name.lineBreakMode = .byTruncatingTail
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byTruncatingTail
            hand.wantsLayer = true
            // The accent marks a raised hand as a filled dot, the way the tiles
            // do. It is a fill token and never text.
            hand.layer?.backgroundColor = ParticipantGridWindowAccent.color.cgColor
            hand.layer?.cornerRadius = 4
            for (view, symbol) in [(mic, "mic.slash.fill"), (camera, "video.slash.fill")] {
                view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
                view.contentTintColor = .secondaryLabelColor
            }
            for view in [name, detail, hand, mic, camera] as [NSView] { addSubview(view) }
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
        }

        required init?(coder: NSCoder) { nil }

        func apply(_ row: Row) {
            id = row.id
            selected = row.selected
            name.stringValue = row.name
            detail.stringValue = row.detail
            detail.isHidden = row.detail.isEmpty
            hand.isHidden = !row.handUp
            mic.isHidden = !row.muted
            camera.isHidden = !row.cameraOff
            layer?.backgroundColor = selected
                ? NSColor.labelColor.withAlphaComponent(0.10).cgColor : NSColor.clear.cgColor
            setAccessibilityLabel([row.name, row.handUp ? "hand up" : nil, row.detail.isEmpty ? nil : row.detail]
                .compactMap { $0 }.joined(separator: ", "))
            needsLayout = true
        }

        override func layout() {
            super.layout()
            var right = bounds.width - 12
            for view in [camera, mic] where !view.isHidden {
                view.frame = NSRect(x: right - 16, y: (bounds.height - 16) / 2, width: 16, height: 16)
                right -= 22
            }
            if !hand.isHidden {
                hand.frame = NSRect(x: right - 8, y: (bounds.height - 8) / 2, width: 8, height: 8)
                right -= 16
            }
            let textWidth = max(0, right - 12)
            if detail.isHidden {
                name.frame = NSRect(x: 12, y: (bounds.height - 18) / 2, width: textWidth, height: 18)
            } else {
                name.frame = NSRect(x: 12, y: bounds.height / 2, width: textWidth, height: 18)
                detail.frame = NSRect(x: 12, y: bounds.height / 2 - 16, width: textWidth, height: 14)
            }
        }

        /// The panel is non-activating and rarely key; without this the first
        /// click on any row is spent making it key and does nothing.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onClick?(id) }
    }
}

/// The brand fill for chrome drawn in AppKit, read from the asset catalogue like
/// `Brand.green`, so it is never typed in twice.
enum ParticipantGridWindowAccent {
    static var color: NSColor { NSColor(named: "AccentColor") ?? .systemGreen }
}
