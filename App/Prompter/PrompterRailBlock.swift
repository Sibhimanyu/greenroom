//
//  PrompterRailBlock.swift
//  Greenroom
//
//  Prompter's block on the participants panel: an eyebrow that says it is
//  listening, and up to five cards. Sits under the needs block in the rail's
//  content column and follows the rail's rules - a fixed pool of views updated
//  in place, one walk that measures or places, never rebuilt on the poll.
//
import AppKit

final class PrompterRailBlock: NSView {

    static let maxCards = 5
    private static let eyebrowHeight: CGFloat = 16
    private static let groupGap: CGFloat = 20  // matches the rail's railGroupGap
    private static let eyebrowGap: CGFloat = 8 // matches railEyebrowGap
    private static let cardGap: CGFloat = 6

    private let eyebrow = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let cards: [PrompterCardView] = (0..<PrompterRailBlock.maxCards).map { _ in PrompterCardView(frame: .zero) }
    private var state = PrompterSurfaceState.empty
    private var pulse: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        eyebrow.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        eyebrow.textColor = .tertiaryLabelColor
        eyebrow.lineBreakMode = .byTruncatingTail
        addSubview(eyebrow)

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

    /// True when Prompter has anything to say on this rail.
    var isActive: Bool { state.listening || !state.cards.isEmpty }

    /// Rewrites in place. Returns true when the block's height changed, so the
    /// rail knows to re-lay its column.
    @discardableResult
    func apply(_ next: PrompterSurfaceState) -> Bool {
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

    private var visibleCount: Int { cards.filter { !$0.isHidden }.count }

    private var eyebrowText: String {
        if !state.listening && state.cards.isEmpty { return "" }
        if state.paused { return "PROMPTER   paused" }
        if state.cards.isEmpty { return "PROMPTER   listening" }
        return "PROMPTER   \(state.cards.count) link\(state.cards.count == 1 ? "" : "s")"
    }

    /// How tall the block will be, without placing it. Zero when inactive.
    func height(forWidth width: CGFloat) -> CGFloat {
        walk(x: 0, width: width, top: 0, place: false)
    }

    /// Places the block with its top edge at `top`, returns the height used.
    @discardableResult
    func place(x: CGFloat, width: CGFloat, top: CGFloat) -> CGFloat {
        walk(x: x, width: width, top: top, place: true)
    }

    /// One walk, measuring or placing - the rail's rule, for the rail's reason.
    private func walk(x: CGFloat, width: CGFloat, top: CGFloat, place: Bool) -> CGFloat {
        guard isActive else {
            if place { frame = .zero }
            return 0
        }
        let count = min(state.cards.count, Self.maxCards)
        var used = Self.groupGap + Self.eyebrowHeight
        if count > 0 { used += Self.eyebrowGap + CGFloat(count) * PrompterCardView.height + CGFloat(count - 1) * Self.cardGap }
        guard place else { return used }

        frame = NSRect(x: x, y: top - used, width: width, height: used)
        var y = used - Self.groupGap - Self.eyebrowHeight
        eyebrow.frame = NSRect(x: 0, y: y, width: width - 12, height: Self.eyebrowHeight)
        dot.frame = NSRect(x: width - 8, y: y + 5, width: 6, height: 6)
        y -= Self.eyebrowGap
        for view in cards where !view.isHidden {
            y -= PrompterCardView.height
            view.frame = NSRect(x: 0, y: y, width: width, height: PrompterCardView.height)
            y -= Self.cardGap
        }
        return used
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
