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
//  whenever Prompter's contents changed, so a link arriving moved the whole
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
    private let assistEyebrow = NSTextField(labelWithString: "ASSIST")
    private let rule = NSView()

    /// Prompter draws its own cards; the queue only gives it a place to stand.
    let assist: PrompterRailBlock

    private var sections: [LiveQueueLayout.Section] = []

    init(assist: PrompterRailBlock) {
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

        assistEyebrow.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        assistEyebrow.textColor = .tertiaryLabelColor
        assistEyebrow.isHidden = true
        addSubview(assistEyebrow)

        rule.wantsLayer = true
        rule.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        rule.isHidden = true
        addSubview(rule)

        addSubview(assist)
    }

    required init?(coder: NSCoder) { nil }

    private func firePrimary() {
        guard let section = sections.first else { return }
        section.kind == .waiting ? actions.admitAll() : actions.nextHand()
    }

    private func fireSecondary() {
        guard let section = sections.first else { return }
        section.kind == .waiting ? actions.viewAll() : actions.lowerAll()
    }

    /// The panel's content height for a state, and nothing drawn yet. Zero
    /// means the window should hide the panel rather than draw an empty box.
    func height(for state: ParticipantConsoleState, width: CGFloat) -> CGFloat {
        LiveQueueLayout.contentHeight(
            LiveQueueLayout.sections(for: state,
                                     assistHeight: assistHeight(state: state, width: width)))
    }

    private func assistHeight(state: ParticipantConsoleState, width: CGFloat) -> CGFloat {
        guard state.prompterCards > 0 else { return 0 }
        let inner = width - LiveQueueLayout.pad * 2
        // A generous budget: the queue scrolls if the whole panel overflows,
        // which is the one place scrolling is right - it is the least urgent
        // thing here.
        return assist.height(forWidth: inner, available: 400)
    }

    /// Writes the panel for a state and lays it out. Returns the height used.
    @discardableResult
    func apply(_ state: ParticipantConsoleState, width: CGFloat) -> CGFloat {
        let inner = width - LiveQueueLayout.pad * 2
        sections = LiveQueueLayout.sections(for: state,
                                            assistHeight: assistHeight(state: state, width: width))
        let total = LiveQueueLayout.contentHeight(sections)
        isHidden = sections.isEmpty
        guard !sections.isEmpty else { return 0 }

        let attention = sections.first(where: { $0.kind != .assist })
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
        var y = max(bounds.height, total) - LiveQueueLayout.pad
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
            primary.frame = NSRect(x: x, y: y, width: buttonWidth,
                                   height: LiveQueueLayout.actionHeight)
            secondary.frame = NSRect(x: x + buttonWidth + 8, y: y, width: buttonWidth,
                                     height: LiveQueueLayout.actionHeight)
        }

        let hasAssist = sections.contains { $0.kind == .assist }
        assistEyebrow.isHidden = !hasAssist
        rule.isHidden = !(hasAssist && attention != nil)
        if hasAssist {
            if attention != nil {
                y -= LiveQueueLayout.sectionGap
                rule.frame = NSRect(x: x, y: y + LiveQueueLayout.sectionGap / 2,
                                    width: inner, height: 1)
            }
            y -= LiveQueueLayout.eyebrowHeight
            assistEyebrow.frame = NSRect(x: x, y: y, width: inner,
                                         height: LiveQueueLayout.eyebrowHeight)
            y -= LiveQueueLayout.eyebrowGap
            assist.place(x: x, width: inner, top: y, available: 400)
        } else {
            assist.frame = .zero
        }
        return total
    }
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
