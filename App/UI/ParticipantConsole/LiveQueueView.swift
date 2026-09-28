//
//  LiveQueueView.swift
//  Greenroom
//
//  The exception panel: who needs the teacher, and what to do about them.
//
//  Phase 2 of docs/participant-window-redesign-plan.md. Not a chat and not an
//  activity feed - a short, strictly prioritised list of things requiring an
//  action, with the action next to the thing.
//
//  Fixed width, always. The rail it replaces re-ran a column-width decision
//  whenever Cues's contents changed, so a link arriving moved the whole
//  panel; this one cannot, because nothing here is allowed to ask for a
//  different width. Where the sections go is arithmetic in LiveQueueLayout,
//  checked by the bench without a meeting.
//
//  Views are a fixed pool, written in place, never rebuilt. The rail learned
//  that on a one-second poll: tearing views down races the accessibility tree
//  and drops clicks that land mid-teardown.
//
import AppKit

final class LiveQueueView: NSView {

    /// What the panel can ask the window to do. All of them already exist on
    /// the coordinator; the queue only calls them.
    struct Actions {
        var admitAll: () -> Void = {}
        var viewAll: () -> Void = {}
        var nextHand: () -> Void = {}
        var lowerAll: () -> Void = {}
    }

    var actions = Actions()

    private let eyebrow = NSTextField(labelWithString: "")
    private let rows: [NSTextField] = (0..<6).map { _ in NSTextField(labelWithString: "") }
    private lazy var primary = QueueButton { [weak self] in self?.firePrimary() }
    private lazy var secondary = QueueButton { [weak self] in self?.fireSecondary() }
    private let cuesEyebrow = NSTextField(labelWithString: "CUES")
    private let cuesDot = NSView()
    private let rule = NSView()
    /// The box Cues's cards live in. Always there while Cues is on - see
    /// ParticipantConsoleState.showsCuesContainer for why.
    private let container = CuesContainerView()
    private let emptyLine = NSTextField(labelWithString: "Links you mention will show up here.")

    /// Cues draws its own cards; the queue only gives it a place to stand.
    let assist: CuesRailBlock

    private var sections: [LiveQueueLayout.Section] = []

    init(assist: CuesRailBlock) {
        self.assist = assist
        super.init(frame: .zero)
        wantsLayer = true

        eyebrow.font = .systemFont(ofSize: 13, weight: .semibold)
        eyebrow.textColor = .labelColor
        eyebrow.lineBreakMode = .byTruncatingTail
        addSubview(eyebrow)

        for row in rows {
            row.font = .systemFont(ofSize: 13)
            row.textColor = .secondaryLabelColor
            row.lineBreakMode = .byTruncatingTail
            row.isHidden = true
            addSubview(row)
        }

        // Only the urgent action is filled; the second is quiet. DESIGN.md:
        // give filled treatment to urgent actions only.
        primary.filled = true
        addSubview(primary)
        addSubview(secondary)

        // DESIGN.md eyebrow: mono, uppercase, 10pt, tertiary. It carries the
        // block's own status ("CUES   listening", "CUES   3 links") because the
        // block's heading is switched off inside the container - one heading
        // per box, and this is the one outside it.
        cuesEyebrow.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        cuesEyebrow.textColor = .tertiaryLabelColor
        cuesEyebrow.lineBreakMode = .byTruncatingTail
        cuesEyebrow.isHidden = true
        addSubview(cuesEyebrow)

        cuesDot.wantsLayer = true
        cuesDot.layer?.cornerRadius = 3
        cuesDot.layer?.backgroundColor = CuesRailBlock.netColor.cgColor
        cuesDot.isHidden = true
        addSubview(cuesDot)

        rule.wantsLayer = true
        rule.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        rule.isHidden = true
        addSubview(rule)

        container.isHidden = true
        addSubview(container)

        // One quiet line, centred in the box. DESIGN.md (2026-09-18): an empty
        // pane is centred, because a line pinned to the top of a tall empty
        // box reads as a panel that failed to load. It says what will happen
        // rather than that nothing has, which is the more useful half.
        emptyLine.font = .systemFont(ofSize: 12)
        emptyLine.textColor = .secondaryLabelColor
        emptyLine.alignment = .center
        emptyLine.lineBreakMode = .byTruncatingTail
        emptyLine.isHidden = true
        container.addSubview(emptyLine)

        // Inside the box, so a card the block insists on showing when the box
        // is shorter than one (its max(best, 1) rule) is clipped at the box's
        // edge instead of drawing across the hairline.
        assist.embedded = true
        assist.onStatus = { [weak self] text, resolving in
            self?.cuesEyebrow.stringValue = text.isEmpty ? "CUES" : text
            self?.cuesDot.isHidden = !resolving
        }
        container.addSubview(assist)
    }

    required init?(coder: NSCoder) { nil }

    private func firePrimary() {
        guard let section = sections.first, section.kind != .cues else { return }
        if section.kind == .waiting {
            actions.admitAll()
            showPending(primary, "Admitting\u{2026}", for: section)
        } else {
            actions.nextHand()
        }
    }

    private func fireSecondary() {
        guard let section = sections.first, section.kind != .cues else { return }
        if section.kind == .waiting {
            actions.viewAll()
        } else {
            actions.lowerAll()
            showPending(secondary, "Lowering\u{2026}", for: section)
        }
    }

    /// What was on screen when a button that waits on Zoom was pressed.
    ///
    /// Admit goes to Zoom at once, but the name only leaves the queue when
    /// Zoom reports the student in, a second or two later - and for that
    /// second the button looked as if nothing had happened, so a teacher
    /// pressed it again, or stopped trusting it. It now says what it is doing
    /// the moment it is pressed, and holds that until the queue changes.
    private var pending: (button: QueueButton, label: String, section: LiveQueueLayout.Section, until: Date)?

    private func showPending(_ button: QueueButton, _ label: String, for section: LiveQueueLayout.Section) {
        pending = (button, label, section, Date().addingTimeInterval(6))
        button.title = label
        button.isEnabled = false
        button.needsDisplay = true
    }

    /// The panel's content height for a state, and nothing drawn yet. Zero
    /// means the window should hide the panel rather than draw an empty box.
    ///
    /// With Cues on, this asks for a full stack of cards whatever is held -
    /// even none. The window gives the queue min(wanted, room left), so asking
    /// for the most Cues can ever show is how the container gets all the room
    /// the controls above leave, and a link arriving never changes the ask.
    /// That constancy is the point: the rail used to re-measure on every card
    /// and the panel moved each time one landed.
    func height(for state: ParticipantConsoleState, width: CGFloat) -> CGFloat {
        LiveQueueLayout.contentHeight(
            LiveQueueLayout.sections(
                for: state,
                cuesBody: CuesRailBlock.stackHeight(cards: CuesRailBlock.maxCards)))
    }

    /// The least the container's inside is ever drawn at: one card.
    ///
    /// Shorter than that and the box could not hold the card the block always
    /// shows, and the empty line would sit in a sliver. When the queue is given
    /// less, the view grows past its viewport and the queue scrolls - DESIGN.md,
    /// panels scroll rather than shrink.
    private static var minCuesBody: CGFloat { CuesRailBlock.stackHeight(cards: 1) }
    /// The floor with no cards to hold: one line of text. A card-sized empty
    /// box under a waiting student made a queue that fit its space scroll,
    /// for a sentence.
    private static let minEmptyBody: CGFloat = 28

    /// Writes the panel for a state and lays it out. Returns the height used.
    @discardableResult
    func apply(_ state: ParticipantConsoleState, width: CGFloat) -> CGFloat {
        let inner = width - LiveQueueLayout.pad * 2
        // Fitted to the height this view actually has, which the window sets
        // before apply runs - the VIEWPORT height, not what the queue wanted.
        // Measured live with five links held, laying out to the want put every
        // card below the window edge. The container takes whatever is left
        // under the sections above it, and the block fits whole cards into
        // that and counts the rest, which is the behaviour it was built for.
        let floor = state.cuesCards > 0 ? Self.minCuesBody : Self.minEmptyBody
        let body = max(floor, LiveQueueLayout.cuesRoom(for: state, height: bounds.height))
        sections = LiveQueueLayout.sections(for: state, cuesBody: body)
        let total = LiveQueueLayout.contentHeight(sections)
        isHidden = sections.isEmpty
        guard !sections.isEmpty else { return 0 }
        // Only when the one-card floor above outruns the room: grow, so the
        // scroller has something to scroll, rather than lay content out above
        // the view's top edge where the clip view cuts it off.
        if total > bounds.height { setFrameSize(NSSize(width: frame.width, height: total)) }

        let attention = sections.first(where: { $0.kind != .cues })
        eyebrow.isHidden = attention == nil
        primary.isHidden = attention == nil
        secondary.isHidden = attention == nil
        for row in rows { row.isHidden = true }

        // From the TOP of the view, not from the top of its content.
        //
        // These differ whenever the view is taller than what it holds, which is
        // the normal case: the queue's document view is sized to the scroller's
        // viewport so a short queue does not leave a scrollable void. Laying out
        // from `total` in a view of height H put the content at the BOTTOM of
        // the queue area - AppKit's origin is bottom-left - so one waiting
        // student appeared floating at the foot of the column, detached from
        // the controls it belongs under.
        var y = bounds.height - LiveQueueLayout.pad
        let x = LiveQueueLayout.pad

        if let attention {
            eyebrow.stringValue = attention.eyebrow
            y -= LiveQueueLayout.eyebrowHeight
            eyebrow.frame = NSRect(x: x, y: y, width: inner, height: LiveQueueLayout.eyebrowHeight)
            y -= LiveQueueLayout.eyebrowGap

            for (index, text) in attention.rows.prefix(rows.count).enumerated() {
                let row = rows[index]
                row.stringValue = text
                row.isHidden = false
                y -= LiveQueueLayout.rowHeight
                row.frame = NSRect(x: x, y: y, width: inner, height: LiveQueueLayout.rowHeight)
            }

            y -= LiveQueueLayout.actionGap + LiveQueueLayout.actionHeight
            let buttonWidth = (inner - 8) / 2
            primary.title = attention.actions.first ?? ""
            secondary.title = attention.actions.count > 1 ? attention.actions[1] : ""
            primary.isEnabled = true
            secondary.isEnabled = true
            // Six seconds is the give-up: Zoom has answered by then or it is
            // not going to, and a button stuck on "Admitting..." is a worse
            // lie than one that goes back to "Admit".
            if let held = pending, held.section == attention, Date() < held.until {
                held.button.title = held.label
                held.button.isEnabled = false
            } else {
                pending = nil
            }
            primary.frame = NSRect(x: x, y: y, width: buttonWidth,
                                   height: LiveQueueLayout.actionHeight)
            secondary.frame = NSRect(x: x + buttonWidth + 8, y: y, width: buttonWidth,
                                     height: LiveQueueLayout.actionHeight)
        }

        let hasCues = sections.contains { $0.kind == .cues }
        cuesEyebrow.isHidden = !hasCues
        container.isHidden = !hasCues
        rule.isHidden = !(hasCues && attention != nil)
        if hasCues {
            if attention != nil {
                y -= LiveQueueLayout.sectionGap
                rule.frame = NSRect(x: x, y: y + LiveQueueLayout.sectionGap / 2,
                                    width: inner, height: 1)
            }
            y -= LiveQueueLayout.eyebrowHeight
            cuesEyebrow.frame = NSRect(x: x, y: y, width: inner - 12,
                                       height: LiveQueueLayout.eyebrowHeight)
            cuesDot.frame = NSRect(x: x + inner - 8, y: y + 5, width: 6, height: 6)
            y -= LiveQueueLayout.eyebrowGap

            // The same sum as LiveQueueLayout.cuesHeight, minus the eyebrow
            // just placed: the box is padding, body, padding.
            let pad = LiveQueueLayout.containerPad
            let box = pad * 2 + body
            y -= box
            container.frame = NSRect(x: x, y: y, width: inner, height: box)
            let cardsWidth = inner - pad * 2
            let used = assist.place(x: pad, width: cardsWidth, top: box - pad, available: body)
            emptyLine.isHidden = used > 0
            // Off, the box still stands and says why it is empty.
            if !state.showsCuesContainer { cuesEyebrow.stringValue = "CUES   off" }
            emptyLine.stringValue = state.showsCuesContainer
                ? "Links you mention will show up here."
                : "Cues is off. Turn it on in Settings \u{2192} Cues for links here."
            if used == 0 {
                let line: CGFloat = 16
                emptyLine.frame = NSRect(x: pad, y: ((box - line) / 2).rounded(),
                                         width: cardsWidth, height: line)
            }
        } else {
            assist.frame = .zero
        }
        return total
    }
}

/// The Cues container: a bounded, always-there place for cards.
///
/// Drawn rather than layer-coloured so the system colours re-resolve when the
/// appearance changes; a cgColor taken once stays light in dark mode. The fill
/// is the control background, a well a step away from the window, and the
/// cards' own translucent surface sits on it the way it sits on the window.
private final class CuesContainerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = LiveQueueLayout.containerRadius
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let r = LiveQueueLayout.containerRadius
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: r - 0.5, yRadius: r - 0.5)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A queue action. Filled when it is the urgent one, quiet when it is not.
private final class QueueButton: NSButton {
    var filled = false { didSet { needsDisplay = true } }
    private let body: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }

    init(_ action: @escaping () -> Void) {
        self.body = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(fire)
        isBordered = false
        font = .systemFont(ofSize: 12, weight: .medium)
        wantsLayer = true
        layer?.cornerRadius = 8
    }

    required init?(coder: NSCoder) { nil }
    @objc private func fire() { body() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        if filled {
            let base = NSColor.controlAccentColor
            (isHighlighted ? base.blended(withFraction: 0.2, of: .black) ?? base
                           : hovering ? base.blended(withFraction: 0.1, of: .white) ?? base
                           : base).setFill()
            path.fill()
        } else {
            if isHighlighted || hovering {
                NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.20 : 0.12).setFill()
                path.fill()
            }
            NSColor.separatorColor.setStroke()
            path.stroke()
        }
        let ink: NSColor = filled ? .white : .labelColor
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let text = NSAttributedString(string: title, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: isEnabled ? ink : ink.withAlphaComponent(0.4),
            .paragraphStyle: style
        ])
        let size = text.size()
        text.draw(in: NSRect(x: 0, y: ((bounds.height - size.height) / 2).rounded(),
                             width: bounds.width, height: size.height))
    }
}
