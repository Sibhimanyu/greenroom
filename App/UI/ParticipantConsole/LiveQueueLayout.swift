//
//  LiveQueueLayout.swift
//  Greenroom
//
//  Where the Live Queue's sections go, as arithmetic.
//
//  Phase 2 of docs/participant-window-redesign-plan.md. Split out from the view
//  so it can be checked without a meeting: every layout decision this window has
//  got wrong in the last week was wrong in arithmetic that only ran on screen,
//  and the only ones caught early were the ones a bench could run.
//
//  The rule the plan cares about most is that this panel's WIDTH never changes.
//  The rail's did - Cues arriving re-ran a column-width decision and moved
//  the whole layout - and that instability is the reason the queue is fixed.
//  Nothing here returns a width; the caller owns it and it is a constant.
//
import Foundation

enum LiveQueueLayout {

    /// Fixed. The plan's range is 300-340pt; 320 sits in the middle and holds
    /// a name plus two buttons without wrapping at 13pt.
    static let width: CGFloat = 320

    static let pad: CGFloat = 16
    static let eyebrowHeight: CGFloat = 16
    static let eyebrowGap: CGFloat = 10
    static let rowHeight: CGFloat = 22
    static let actionHeight: CGFloat = 28
    static let actionGap: CGFloat = 10
    /// Between one section and the next.
    static let sectionGap: CGFloat = 24
    /// The rule above the Cues section, which is a different KIND of thing
    /// from the two above it: those are people, this is a suggestion.
    static let ruleGap: CGFloat = 16
    /// Between the Cues container's hairline and the cards inside it. Eight,
    /// the card's own inner padding, so a card sits in the box the way its
    /// picture sits in the card.
    static let containerPad: CGFloat = 8
    /// DESIGN.md radius-lg. The container is a panel holding cards, and the
    /// cards are already radius-md; the same radius on both would read as one
    /// card drawn twice.
    static let containerRadius: CGFloat = 14

    /// One block in the queue, top to bottom.
    struct Section: Equatable {
        enum Kind: Equatable { case waiting, hands, cues }
        var kind: Kind
        var eyebrow: String
        var rows: [String]
        /// Button titles, left to right. Empty for Cues, whose cards carry
        /// their own controls.
        var actions: [String]
        var height: CGFloat
    }

    /// What the queue draws for a given state, in order.
    ///
    /// Empty when nothing needs the teacher and Cues is off: the plan is
    /// explicit that an empty queue shows no filler. A section that exists
    /// only to say "nothing here" is not filling the space, it is moving the
    /// hole. Cues on with no links yet is NOT that case - its container is
    /// where the next link will land, so it is shown before it is needed.
    ///
    /// `cuesBody` is the height of what goes INSIDE the Cues container: the
    /// cards, or the room they get. The caller works it out, because only the
    /// AppKit side knows how tall a card is; this side adds the eyebrow and
    /// the container's padding, and nothing else, so the two cannot disagree.
    static func sections(for state: ParticipantConsoleState,
                         cuesBody: CGFloat) -> [Section] {
        var out: [Section] = []

        switch state.attention {
        case .waiting(let people, let total):
            var rows = people.map(\.name)
            if total > people.count { rows.append("+\(total - people.count) more") }
            // "Admit all" only when there is more than one person to admit;
            // with one person the plural is a lie and the extra choice is a
            // decision the teacher should not have to make.
            let actions = total > 1 ? ["Admit all", "View all"] : ["Admit", "View all"]
            out.append(Section(kind: .waiting,
                               eyebrow: "\(total) waiting to join",
                               rows: rows, actions: actions,
                               height: blockHeight(rows: rows.count, actions: true)))
        case .hands(let people, let total):
            var rows = people.enumerated().map { "\($0.offset + 1).  \($0.element.name)" }
            if total > people.count { rows.append("+\(total - people.count) more") }
            out.append(Section(kind: .hands,
                               eyebrow: total == 1 ? "1 hand up" : "\(total) hands up",
                               rows: rows, actions: ["Next", "Lower all"],
                               height: blockHeight(rows: rows.count, actions: true)))
        case .clear:
            break
        }

        // Cues sits below whatever is above it and never displaces it. When
        // something urgent holds the top it still gets a slot, because a link
        // the teacher was about to use should not vanish because a hand went
        // up - it just stops being first.
        //
        // Always there, Cues on or off, so the middle of the rail is a
        // bounded box at every moment of the class rather than a hole that
        // fills: the panel reads as composed before anything arrives, and
        // nothing arriving changes its shape.
        out.append(Section(kind: .cues, eyebrow: "CUES", rows: [], actions: [],
                           height: cuesHeight(body: cuesBody)))
        return out
    }

    /// Eyebrow, then the container: its padding top and bottom around `body`.
    static func cuesHeight(body: CGFloat) -> CGFloat {
        eyebrowHeight + eyebrowGap + containerPad * 2 + max(0, body)
    }

    /// The body height that makes the Cues container reach the bottom of a
    /// queue `height` tall, after the sections above it have taken theirs.
    ///
    /// The inverse of `contentHeight` for the Cues section, and derived from
    /// the same sections rather than restated: pad + above + cuesHeight(room)
    /// + pad is `height` exactly, whenever room is not clamped at zero. That
    /// identity is what the bench checks, because a container that stops 3pt
    /// short of the edge, or runs 3pt under it, is the kind of wrong nobody
    /// sees until it is on a projector.
    static func cuesRoom(for state: ParticipantConsoleState, height: CGFloat) -> CGFloat {
        let above = sections(for: state, cuesBody: 0)
            .filter { $0.kind != .cues }
            .reduce(0) { $0 + $1.height + sectionGap }
        return max(0, height - pad * 2 - above - cuesHeight(body: 0))
    }

    /// Eyebrow, rows, and one row of buttons.
    static func blockHeight(rows: Int, actions: Bool) -> CGFloat {
        var height = eyebrowHeight + eyebrowGap + CGFloat(rows) * rowHeight
        if actions { height += actionGap + actionHeight }
        return height
    }

    /// Total content height for a set of sections, including the gaps between
    /// them and the panel's own padding. Zero for an empty queue, so the caller
    /// can hide the panel rather than draw an empty box.
    static func contentHeight(_ sections: [Section]) -> CGFloat {
        guard !sections.isEmpty else { return 0 }
        let blocks = sections.reduce(0) { $0 + $1.height }
        let gaps = CGFloat(sections.count - 1) * sectionGap
        return pad * 2 + blocks + gaps
    }
}
