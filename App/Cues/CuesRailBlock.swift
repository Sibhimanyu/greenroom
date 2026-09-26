//
//  CuesRailBlock.swift
//  Greenroom
//
//  Cues's block on the participants panel: an eyebrow that says it is
//  listening, and up to five cards. Sits under the needs block in the rail's
//  content column and follows the rail's rules - a fixed pool of views updated
//  in place, one walk that measures or places, never rebuilt on the poll.
//
import AppKit

final class CuesRailBlock: NSView {

    static let maxCards = 5
    /// Below this many cards the window stops cycling them, because there is
    /// nothing to cycle. Not a promise of space: the rail gives Cues what
    /// is left after the picture and the controls, and says "+N older" when
    /// that is fewer slots than there are cards.
    static let minCards = 3
    private static let eyebrowHeight: CGFloat = 16
    private static let groupGap: CGFloat = 20  // matches the rail's railGroupGap
    private static let eyebrowGap: CGFloat = 8 // matches railEyebrowGap
    /// Eight, not six. DESIGN.md's spacing scale is 4px steps and lists 6 as
    /// drift to round off when the code is touched; the cards are also easier
    /// to tell apart with the extra air now that they carry a hairline.
    private static let cardGap: CGFloat = 8
    /// The "+N more" line drawn when the rail is too short for every card.
    private static let overflowGap: CGFloat = 6
    private static let overflowHeight: CGFloat = 14

    private let eyebrow = NSTextField(labelWithString: "")
    private let overflow = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let cards: [CueCardView] = (0..<CuesRailBlock.maxCards).map { _ in CueCardView(frame: .zero) }
    private var state = CuesSurfaceState.empty
    private var pulse: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        eyebrow.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        eyebrow.textColor = .tertiaryLabelColor
        eyebrow.lineBreakMode = .byTruncatingTail
        addSubview(eyebrow)

        overflow.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        overflow.textColor = .tertiaryLabelColor
        overflow.isHidden = true
        addSubview(overflow)

        // Amber while a request is in flight: DESIGN.md draws anything that
        // leaves the Mac in amber, and a lookup is exactly that.
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = NSColor(red: 0.725, green: 0.467, blue: 0.055, alpha: 1).cgColor // --net #B9770E
        dot.isHidden = true
        addSubview(dot)

        for card in cards {
            card.isHidden = true
            addSubview(card)
        }
    }

    required init?(coder: NSCoder) { nil }

    /// True when Cues has anything to say on this rail.
    var isActive: Bool { state.listening || !state.cards.isEmpty }

    /// How many links are held, for the console's presentation model.
    var cardCount: Int { state.cards.count }

    /// True when there are links on screen, as opposed to a listening eyebrow.
    /// The rail asks, because a live link outranks the standing session facts
    /// for the room the two of them are competing over.
    var hasCards: Bool { !state.cards.isEmpty }

    /// Rewrites in place. Returns true when the block's height changed, so the
    /// rail knows to re-lay its column.
    @discardableResult
    func apply(_ next: CuesSurfaceState) -> Bool {
        let before = visibleCount
        state = next
        let shown = Array(next.cards.prefix(Self.maxCards))
        for (index, view) in cards.enumerated() {
            if index < shown.count {
                view.isHidden = false
                view.onOpen = next.open
                view.onSend = next.send
                view.onDismiss = next.dismiss
                view.apply(shown[index], canSend: next.canSend)
            } else {
                view.isHidden = true
            }
        }
        eyebrow.stringValue = eyebrowText
        eyebrow.isHidden = !isActive
        dot.isHidden = !(isActive && next.resolving)
        return before != visibleCount || eyebrow.isHidden == isActive
    }

    /// Read from the state, not from the views. The views are hidden a second
    /// time by `walk` when the rail is too short for every card, and if that
    /// fitting decision fed back in here a resize would read as a state change.
    private var visibleCount: Int { min(state.cards.count, Self.maxCards) }

    private var eyebrowText: String {
        if !state.listening && state.cards.isEmpty { return "" }
        if state.paused { return "CUES   paused" }
        if state.cards.isEmpty { return "CUES   listening" }
        return "CUES   \(state.cards.count) link\(state.cards.count == 1 ? "" : "s")"
    }

    /// How tall the block will be, without placing it. Zero when inactive.
    ///
    /// `available` is the room the rail has left under everything else. The
    /// block never asks for more than that, which is the whole point: five
    /// cards on a short rail used to be drawn regardless and the last two fell
    /// off the bottom edge of the panel, where a live link is no use at all.
    func height(forWidth width: CGFloat, available: CGFloat) -> CGFloat {
        walk(x: 0, width: width, top: 0, available: available, place: false)
    }

    /// Places the block with its top edge at `top`, returns the height used.
    @discardableResult
    func place(x: CGFloat, width: CGFloat, top: CGFloat, available: CGFloat) -> CGFloat {
        walk(x: x, width: width, top: top, available: available, place: true)
    }

    /// How many of `wanted` cards fit in `budget`, counting the "+N more" line
    /// when some are left over.
    ///
    /// Not a division, because dropping the last card also drops the overflow
    /// line - so n = wanted can fit where n = wanted - 1 does not. Walking the
    /// range and keeping the largest that fits is the only answer that is right
    /// at that boundary.
    private static func cardsFitting(wanted: Int, budget: CGFloat) -> Int {
        guard wanted > 0 else { return 0 }
        var best = 0
        for n in 1...wanted {
            var need = eyebrowGap + CGFloat(n) * CueCardView.height
                + CGFloat(n - 1) * cardGap
            if n < wanted { need += overflowGap + overflowHeight }
            if need <= budget { best = n }
        }
        // Never a bare "CUES 4 links" with nothing under it: an eyebrow
        // advertising links the teacher cannot see is worse than one card they
        // have to scroll a little to finish.
        return max(best, 1)
    }

    /// One walk, measuring or placing - the rail's rule, for the rail's reason.
    private func walk(x: CGFloat, width: CGFloat, top: CGFloat,
                      available: CGFloat, place: Bool) -> CGFloat {
        guard isActive else {
            if place {
                frame = .zero
                overflow.isHidden = true
            }
            return 0
        }
        let wanted = min(state.cards.count, Self.maxCards)
        let head = Self.groupGap + Self.eyebrowHeight
        let shown = Self.cardsFitting(wanted: wanted, budget: available - head)
        let hidden = max(0, state.cards.count - shown)

        var used = head
        if shown > 0 {
            used += Self.eyebrowGap + CGFloat(shown) * CueCardView.height
                + CGFloat(shown - 1) * Self.cardGap
        }
        if hidden > 0 { used += Self.overflowGap + Self.overflowHeight }
        guard place else { return used }

        frame = NSRect(x: x, y: top - used, width: width, height: used)
        var y = used - Self.groupGap - Self.eyebrowHeight
        eyebrow.frame = NSRect(x: 0, y: y, width: width - 12, height: Self.eyebrowHeight)
        dot.frame = NSRect(x: width - 8, y: y + 5, width: 6, height: 6)
        y -= Self.eyebrowGap
        for (index, view) in cards.enumerated() {
            guard index < shown else {
                view.isHidden = true
                continue
            }
            view.isHidden = false
            y -= CueCardView.height
            view.frame = NSRect(x: 0, y: y, width: width, height: CueCardView.height)
            y -= Self.cardGap
        }
        overflow.isHidden = hidden == 0
        if hidden > 0 {
            // Cards are newest first, so what the rail drops is the oldest -
            // the right end to lose. The line says so rather than promising a
            // scroll that would not reach them.
            overflow.stringValue = "+\(hidden) older"
            y -= Self.overflowGap + Self.overflowHeight - Self.cardGap
            overflow.frame = NSRect(x: 0, y: y, width: width, height: Self.overflowHeight)
        }
        return used
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
