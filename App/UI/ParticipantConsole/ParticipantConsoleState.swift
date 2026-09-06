//
//  ParticipantConsoleState.swift
//  Greenroom
//
//  What the participant window is showing, worked out once.
//
//  Phase 1 of docs/participant-window-redesign-plan.md. The plan's diagnosis is
//  that session facts, the waiting list, the hand queue, Prompter's cards and
//  the selected participant all live in one scrolling rail and each recompute
//  their own idea of what matters. The consequence was visible: Prompter
//  arriving changed the rail's size and pushed other information around, so the
//  layout moved for reasons the teacher could not see.
//
//  This type is the single answer to "what needs the teacher right now". It is
//  a value, derived from the roster, the session and the surfaces, and it holds
//  no views. Nothing here draws; the point is that the drawing code stops
//  deciding.
//
//  Deliberately NOT a rewrite of any meeting control. Every Zoom call and every
//  confirmation stays exactly where it is - this is presentation only, which is
//  what makes Phase 1 safe to land before the layout changes underneath it.
//
import Foundation

struct ParticipantConsoleState: Equatable {

    struct Person: Equatable, Hashable {
        let id: UInt32
        let name: String
    }

    /// The one thing at the top of the Live Queue.
    ///
    /// Strictly ordered, because only one thing can be the most urgent: people
    /// at the door, then hands in the air, then nothing. A raised hand waits;
    /// a person at the door cannot see or hear the class yet.
    enum Attention: Equatable {
        /// People in the waiting room, and how many there are in total.
        case waiting([Person], total: Int)
        /// Raised hands in the order they went up, and the total.
        case hands([Person], total: Int)
        /// Nothing needs the teacher. The queue may show Assist, or nothing.
        case clear
    }

    /// How many names either section shows before it starts counting.
    static let namesShown = 5

    var isLive = false
    var meetingNumber = ""
    var isRecording = false
    var students = 0
    var waiting: [Person] = []
    /// Already in raise order; the caller owns the ordering because it owns the
    /// timestamps.
    var hands: [Person] = []
    var selected: UInt32?
    var prompterCards = 0
    var prompterListening = false

    /// The top of the Live Queue.
    ///
    /// Before the class is live this is always `.clear`: the readiness panel on
    /// the class side is already carrying that wait, and two accounts of one
    /// wait is one too many.
    var attention: Attention {
        guard isLive else { return .clear }
        if !waiting.isEmpty {
            return .waiting(Array(waiting.prefix(Self.namesShown)), total: waiting.count)
        }
        if !hands.isEmpty {
            return .hands(Array(hands.prefix(Self.namesShown)), total: hands.count)
        }
        return .clear
    }

    /// True when Prompter may take queue space.
    ///
    /// The plan's rule, in one place: Assist never displaces a person at the
    /// door or a raised hand. It gets the room only when nothing more urgent
    /// wants it.
    var showsAssist: Bool {
        guard isLive, prompterCards > 0 else { return false }
        return attention == .clear
    }

    /// True when the standing session facts are worth the space.
    ///
    /// They are the filler rung: useful before class and in a quiet stretch,
    /// and the first thing to yield. A quiet stretch is exactly when it stops
    /// being quiet, so live links push them out.
    var showsSessionFacts: Bool {
        isLive && attention == .clear && prompterCards == 0
    }
}
