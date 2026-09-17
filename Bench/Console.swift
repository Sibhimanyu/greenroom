//
//  Console.swift
//  CuesBench
//
//  The participant window's priority ladder, checked directly.
//
//  Phase 1 of docs/participant-window-redesign-plan.md moved "what needs the
//  teacher right now" out of the drawing code and into a value. This is the
//  reason that was worth doing: the ladder had never been testable, and it has
//  been quietly wrong before - the session facts once stood down for Cues
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
    busy.cuesCards = 5
    check("assist yields to the waiting room", !busy.showsAssist)

    var handsAndCards = ParticipantConsoleState()
    handsAndCards.isLive = true
    handsAndCards.hands = [person(2, "Arun")]
    handsAndCards.cuesCards = 3
    check("assist yields to a raised hand", !handsAndCards.showsAssist)

    // With nothing urgent, Assist takes the room and the standing facts yield.
    var quiet = ParticipantConsoleState()
    quiet.isLive = true
    quiet.cuesCards = 2
    check("assist shows when nothing is urgent", quiet.showsAssist)
    check("session facts yield to live links", !quiet.showsSessionFacts)

    // And with nothing at all, the facts are what fills the space.
    var idle = ParticipantConsoleState()
    idle.isLive = true
    check("session facts show in a quiet stretch", idle.showsSessionFacts && !idle.showsAssist)

    print("")
    print("  detector guards, against real class transcripts")

    // Both from classes the teacher actually ran, both of which produced
    // false alarms that shipped to the panel.
    let realCases: [(String, Bool, String)] = [
        ("Feeting season, Jao Maa", false,
         "6 Sep: exactly 50% English, passed a >= 0.5 test, gave 2 false alarms"),
        ("Eppudu, Orukuntu, Indha, veyyil, Kayam.", false,
         "5 Sep: 0% English, gave 2 false alarms"),
        ("There is this tool called figma.", true,
         "must still reach the model when the patterns are silent"),
        ("Many of you still have not joined book fusion.", true,
         "the case the model exists for")
    ]
    for (text, shouldPass, why) in realCases {
        let got = HeuristicDetector.englishRatio(text) > 0.5
        let pass = got == shouldPass
        ok = ok && pass
        print("    \(pass ? "ok   " : "FAIL ") mined=\(got ? "yes" : "no ")  \(why)")
    }

    print("")
    print("  live queue layout")

    func layout(_ label: String, _ passed: Bool) {
        ok = ok && passed
        print("    \(passed ? "ok   " : "FAIL ") \(label)")
    }

    // Nothing to act on and nothing to suggest: no panel at all. The plan is
    // explicit that an empty queue shows no filler.
    var empty = ParticipantConsoleState()
    empty.isLive = true
    let noSections = LiveQueueLayout.sections(for: empty, assistHeight: 0)
    layout("quiet class: no sections, no panel",
           noSections.isEmpty && LiveQueueLayout.contentHeight(noSections) == 0)

    // One person waiting reads "Admit", several read "Admit all". With one
    // person the plural is a lie.
    var one = ParticipantConsoleState()
    one.isLive = true
    one.waiting = [person(1, "Priya")]
    layout("one waiting: the button says Admit",
           LiveQueueLayout.sections(for: one, assistHeight: 0).first?.actions.first == "Admit")

    var three = ParticipantConsoleState()
    three.isLive = true
    three.waiting = [person(1, "Priya"), person(2, "Arun"), person(3, "Meera")]
    layout("three waiting: the button says Admit all",
           LiveQueueLayout.sections(for: three, assistHeight: 0).first?.actions.first == "Admit all")

    // The rule the plan cares about most: Assist never takes the top, and its
    // arrival never changes what is above it.
    var handsThenCards = ParticipantConsoleState()
    handsThenCards.isLive = true
    handsThenCards.hands = [person(2, "Arun")]
    let before2 = LiveQueueLayout.sections(for: handsThenCards, assistHeight: 0)
    handsThenCards.cuesCards = 3
    let after = LiveQueueLayout.sections(for: handsThenCards, assistHeight: 140)
    layout("a card arriving does not move the hands section",
           before2.first == after.first)
    layout("assist lands below, never on top",
           after.count == 2 && after.last?.kind == .assist)

    // Singular and plural read correctly, because a queue that says "1 hands
    // up" is a queue nobody trusts.
    var oneHand = ParticipantConsoleState()
    oneHand.isLive = true
    oneHand.hands = [person(2, "Arun")]
    layout("one hand reads \"1 hand up\"",
           LiveQueueLayout.sections(for: oneHand, assistHeight: 0).first?.eyebrow == "1 hand up")

    // Long queues name five and count the rest, in both sections.
    var many2 = ParticipantConsoleState()
    many2.isLive = true
    many2.hands = (1...8).map { person(UInt32($0), "Student \($0)") }
    let manyRows = LiveQueueLayout.sections(for: many2, assistHeight: 0).first?.rows ?? []
    layout("eight hands: five named plus a count",
           manyRows.count == 6 && manyRows.last == "+3 more")

    print("")
    return ok
}
