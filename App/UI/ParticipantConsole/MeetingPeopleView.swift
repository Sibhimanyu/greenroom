//
//  MeetingPeopleView.swift
//  Greenroom
//
//  The People panel's roster: the waiting room first (Admit, Deny, Admit all),
//  then raised hands in the order they went up, then everyone else. A row opens that person's inspector; the roster itself
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

    /// One person at the door. `canDeny` is the SDK's `canExpelUser`.
    struct WaitingRow: Equatable {
        var id: UInt32
        var name: String
    }

    var onSelect: ((UInt32) -> Void)?
    var onAdmit: ((UInt32) -> Void)?
    var onDeny: ((UInt32) -> Void)?
    var onAdmitAll: (() -> Void)?
    /// Mute all and Ask all to unmute sit in a footer, for a host.
    var onMuteAll: (() -> Void)?
    var onAskAllToUnmute: (() -> Void)?

    private let scroll = NSScrollView()
    private let document = FlippedView()
    private var rowViews: [UInt32: RowView] = [:]
    private var waitingViews: [UInt32: WaitingRowView] = [:]
    private let waitingEyebrow = NSTextField(labelWithString: "")
    private lazy var admitAllButton = Self.smallButton("Admit all") { [weak self] in self?.onAdmitAll?() }
    private let footer = NSView()
    private let footerDivider = NSView()
    private lazy var muteAllButton = Self.smallButton("Mute all") { [weak self] in self?.onMuteAll?() }
    private lazy var askUnmuteButton = Self.smallButton("Ask all to unmute") { [weak self] in self?.onAskAllToUnmute?() }
    private var waiting: [WaitingRow] = []
    private var canDeny = false
    private var showsFooter = false
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
        footerDivider.wantsLayer = true
        footerDivider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        footer.addSubview(footerDivider)
        footer.addSubview(muteAllButton)
        footer.addSubview(askUnmuteButton)
        addSubview(footer)
        footer.isHidden = true
        document.addSubview(admitAllButton)
        for label in [waitingEyebrow, handsEyebrow, everyoneEyebrow] {
            // Mono, uppercase eyebrows: DESIGN.md's one typographic signature.
            label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
            label.textColor = .tertiaryLabelColor
            document.addSubview(label)
        }
    }

    required init?(coder: NSCoder) { nil }

    /// `total` counts everyone in the meeting, you included, which is the number
    /// Zoom's own Participants button shows.
    func apply(waiting: [WaitingRow] = [], canDeny: Bool = false, isHost: Bool = false,
               hands: [Row], everyone: [Row], total: Int) {
        self.hands = hands
        self.everyone = everyone
        self.waiting = waiting
        self.canDeny = canDeny
        self.showsFooter = isHost
        waitingEyebrow.stringValue = "WAITING \u{00B7} \(waiting.count)"
        let waitingLive = Set(waiting.map(\.id))
        for (id, view) in waitingViews where !waitingLive.contains(id) {
            view.removeFromSuperview()
            waitingViews.removeValue(forKey: id)
        }
        for person in waiting {
            let view = waitingViews[person.id] ?? {
                let made = WaitingRowView()
                made.onAdmit = { [weak self] id in self?.onAdmit?(id) }
                made.onDeny = { [weak self] id in self?.onDeny?(id) }
                document.addSubview(made)
                waitingViews[person.id] = made
                return made
            }()
            view.apply(person, canDeny: canDeny)
        }
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
        let footerHeight: CGFloat = showsFooter ? 44 : 0
        footer.isHidden = !showsFooter
        footer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: footerHeight)
        footerDivider.frame = NSRect(x: 0, y: footerHeight - 1, width: bounds.width, height: 1)
        var x: CGFloat = 12
        for button in [muteAllButton, askUnmuteButton] {
            button.sizeToFit()
            button.frame = NSRect(x: x, y: 10, width: button.frame.width + 8, height: 24)
            x += button.frame.width + 8
        }
        scroll.frame = NSRect(x: 0, y: footerHeight, width: bounds.width, height: max(0, bounds.height - footerHeight))
        let width = bounds.width
        var y: CGFloat = 4
        func place(_ label: NSTextField, show: Bool) {
            label.isHidden = !show
            guard show else { return }
            label.frame = NSRect(x: 16, y: y + 8, width: width - 32, height: 14)
            y += Self.eyebrowHeight
        }
        place(waitingEyebrow, show: !waiting.isEmpty)
        admitAllButton.isHidden = waiting.isEmpty
        if !waiting.isEmpty {
            admitAllButton.sizeToFit()
            admitAllButton.frame = NSRect(x: width - 16 - admitAllButton.frame.width - 8, y: 4 + 3,
                                          width: admitAllButton.frame.width + 8, height: 22)
        }
        for person in waiting {
            waitingViews[person.id]?.frame = NSRect(x: 8, y: y, width: width - 16, height: Self.rowHeight)
            y += Self.rowHeight
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
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(y + 8, scroll.bounds.height))
    }

    /// A small bordered action that answers the first click, as the panel is
    /// rarely key.
    fileprivate static func smallButton(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(action)
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        return button
    }

    // MARK: Rows

    /// Someone at the door: their name, Deny and Admit.
    private final class WaitingRowView: NSView {
        var onAdmit: ((UInt32) -> Void)?
        var onDeny: ((UInt32) -> Void)?
        private var id: UInt32 = 0
        private let name = NSTextField(labelWithString: "")
        private lazy var admit = MeetingPeopleView.smallButton("Admit") { [weak self] in
            guard let self else { return }
            self.onAdmit?(self.id)
        }
        private lazy var deny = MeetingPeopleView.smallButton("Deny") { [weak self] in
            guard let self else { return }
            self.onDeny?(self.id)
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerRadius = 10          // DESIGN.md radius-md
            name.font = .systemFont(ofSize: 13, weight: .medium)
            name.textColor = .labelColor
            name.lineBreakMode = .byTruncatingTail
            // Admit is the one expected answer, so it is the default button.
            admit.keyEquivalent = ""
            deny.contentTintColor = .systemRed
            for view in [name, admit, deny] as [NSView] { addSubview(view) }
        }

        required init?(coder: NSCoder) { nil }

        func apply(_ person: WaitingRow, canDeny: Bool) {
            id = person.id
            name.stringValue = person.name
            deny.isHidden = !canDeny
            admit.setAccessibilityLabel("Admit \(person.name)")
            deny.setAccessibilityLabel("Deny \(person.name)")
            needsLayout = true
        }

        override func layout() {
            super.layout()
            admit.sizeToFit()
            admit.frame = NSRect(x: bounds.width - 8 - admit.frame.width - 8, y: (bounds.height - 24) / 2,
                                 width: admit.frame.width + 8, height: 24)
            var right = admit.frame.minX - 6
            if !deny.isHidden {
                deny.sizeToFit()
                deny.frame = NSRect(x: right - deny.frame.width - 8, y: (bounds.height - 24) / 2,
                                    width: deny.frame.width + 8, height: 24)
                right = deny.frame.minX - 8
            }
            name.frame = NSRect(x: 12, y: (bounds.height - 18) / 2, width: max(0, right - 12), height: 18)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

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
