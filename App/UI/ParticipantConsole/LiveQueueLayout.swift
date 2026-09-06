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
//  The rail's did - Prompter arriving re-ran a column-width decision and moved
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
    /// The rule above the Assist section, which is a different KIND of thing
    /// from the two above it: those are people, this is a suggestion.
    static let ruleGap: CGFloat = 16

    /// One block in the queue, top to bottom.
    struct Section: Equatable {
        enum Kind: Equatable { case waiting, hands, assist }
        var kind: Kind
        var eyebrow: String
        var rows: [String]
        /// Button titles, left to right. Empty for assist, which carries its
        /// own card controls.
        var actions: [String]
        var height: CGFloat
    }

    /// What the queue draws for a given state, in order.
    ///
    /// Empty when nothing needs the teacher and Prompter has nothing to say:
    /// the plan is explicit that an empty queue shows no filler. A section that
    /// exists only to say "nothing here" is not filling the space, it is
    /// moving the hole.
    static func sections(for state: ParticipantConsoleState,
                         assistHeight: CGFloat) -> [Section] {
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

        // Assist sits below whatever is above it and never displaces it. When
        // something urgent holds the top it still gets a slot, because a link
        // the teacher was about to use should not vanish because a hand went
        // up - it just stops being first.
        if state.prompterCards > 0, assistHeight > 0 {
            out.append(Section(kind: .assist, eyebrow: "ASSIST", rows: [], actions: [],
                               height: eyebrowHeight + eyebrowGap + assistHeight))
        }
        return out
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
