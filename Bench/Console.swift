//
//  Console.swift
//  PrompterBench
//
//  The participant window's priority ladder, checked directly.
//
//  Phase 1 of docs/participant-window-redesign-plan.md moved "what needs the
//  teacher right now" out of the drawing code and into a value. This is the
//  reason that was worth doing: the ladder had never been testable, and it has
//  been quietly wrong before - the session facts once stood down for Prompter
//  in a way that also changed the rail's WIDTH, so a link arriving moved the
//  whole panel.
//
//  Every case here is a rule the plan states in prose. If a future layout
//  change breaks one, it fails here in a second rather than in a class.
//
import Foundation

private func person(_ id: UInt32, _ name: String) -> ParticipantConsoleState.Person {
    .init(id: id, name: name)
}

func runConsoleBench() -> Bool {
    print("  live queue priority")
    var ok = true

    func check(_ label: String, _ passed: Bool) {
        ok = ok && passed
        print("    \(passed ? "ok   " : "FAIL ") \(label)")
    }

    // Before the class is live the readiness panel carries the wait. Two
    // accounts of one wait is one too many.
    var before = ParticipantConsoleState()
    before.isLive = false
    before.waiting = [person(1, "Priya")]
    check("not live: queue stays clear even with someone waiting",
          before.attention == .clear && !before.showsSessionFacts && !before.showsAssist)

    // A person at the door outranks a raised hand: a hand waits, someone
    // outside cannot see or hear the class yet.
    var both = ParticipantConsoleState()
    both.isLive = true
    both.waiting = [person(1, "Priya")]
    both.hands = [person(2, "Arun"), person(3, "Meera")]
    check("waiting outranks hands", both.attention == .waiting([person(1, "Priya")], total: 1))

    // Hands keep the order they went up in; the model does not re-sort.
    var hands = ParticipantConsoleState()
    hands.isLive = true
    hands.hands = [person(2, "Arun"), person(3, "Meera"), person(4, "Sanjay")]
    check("hands keep raise order",
          hands.attention == .hands([person(2, "Arun"), person(3, "Meera"), person(4, "Sanjay")],
                                    total: 3))

    // Long queues show five and count the rest.
    var many = ParticipantConsoleState()
    many.isLive = true
    many.waiting = (1...7).map { person(UInt32($0), "Student \($0)") }
    if case .waiting(let shown, let total) = many.attention {
        check("seven waiting: five named, total 7", shown.count == 5 && total == 7)
    } else {
        check("seven waiting: five named, total 7", false)
    }

    // Assist never displaces a person at the door.
    var busy = ParticipantConsoleState()
    busy.isLive = true
    busy.waiting = [person(1, "Priya")]
    busy.prompterCards = 5
    check("assist yields to the waiting room", !busy.showsAssist)

    var handsAndCards = ParticipantConsoleState()
    handsAndCards.isLive = true
    handsAndCards.hands = [person(2, "Arun")]
    handsAndCards.prompterCards = 3
    check("assist yields to a raised hand", !handsAndCards.showsAssist)

    // With nothing urgent, Assist takes the room and the standing facts yield.
    var quiet = ParticipantConsoleState()
    quiet.isLive = true
    quiet.prompterCards = 2
    check("assist shows when nothing is urgent", quiet.showsAssist)
    check("session facts yield to live links", !quiet.showsSessionFacts)

    // And with nothing at all, the facts are what fills the space.
    var idle = ParticipantConsoleState()
    idle.isLive = true
    check("session facts show in a quiet stretch", idle.showsSessionFacts && !idle.showsAssist)

    print("")
    return ok
}
