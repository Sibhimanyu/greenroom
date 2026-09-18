# Marks: evaluated presentations

Status: **idea, not started.** No code, no decision on approach. This records
an office-hours session on 2026-09-17 so the thinking survives; it is a
starting point for a conversation, not an agreed plan.

## What it is

A speaker presents. A second person watches and types timestamped notes while
it happens. Afterwards an AI pass reads the material and adds its own
feedback. Both streams compile into one report for the speaker, with the
recording cut to each note.

Two people, not one. That is the whole difference from Yoodli and everything
like it, which put a speaker alone in front of a mirror.

## Why it is worth building here

Greenroom already has most of the spine, built and debugged against real
classes:

| Piece | Where it already lives |
|---|---|
| Live mic capture | `App/Cues/MicStream.swift` |
| On-device transcription | `App/Cues/Transcriber.swift`, `RollingTranscript.swift` |
| Session recording and clipping | `App/Recording/SessionClips.swift`, `SessionClipExporter.swift` |
| Post-session summary | `App/Recording/SessionSummary.swift` |
| A live surface a teacher watches mid-class | `App/UI/ParticipantConsole/` |
| Class roster | the meeting SDK's participant list |

Swap "here is a link about the book you mentioned" for "you have said
'basically' nine times in four minutes" and the plumbing barely changes.

## Decisions taken

- **The evaluator is a teacher, the speaker is a student.** Not a Toastmasters
  peer, not a paid coach, not a competition panel. Chosen because it is the
  author's own problem and there is a real class to test in.
- **Both settings.** The student may be remote in a meeting or in the room.
  The note box, rubric, AI pass and report do not care where the pixels come
  from, so the capture source is an abstraction from day one even though only
  one source gets implemented first.
- **A sub-brand inside Greenroom, not a second app.** See Positioning.
- **The name is Marks.** See Naming.

## Premises

Agreed in session. If one of these is wrong the design changes.

1. **The live human note is the part AI cannot replace.** "The room went quiet
   here." "She recovered well after the laptop died." "First time he has made
   eye contact all term." None of it is recoverable from footage. If the note
   box is awkward the product is worthless however good the AI is.
2. **The evaluator is the daily user; the speaker is the beneficiary.** The
   teacher opens this every time, the student once per presentation. If it does
   not fit the teacher's hands the student never gets a report at all.
3. **The AI's job is consistency, not judgement.** The obvious pitch is "AI
   finds filler words", which is table stakes. The valuable version: you grade
   twelve students on a Friday afternoon and your standards drift. Student 3
   was marked harder than student 9 on the same rubric line and you cannot see
   it from inside. An AI pass across the cohort can. That is something a human
   evaluator genuinely cannot do for themselves, and it is defensible when a
   grade is questioned.
4. **Typing while evaluating is the binding constraint.** The teacher is
   watching a person, forming a judgement and typing at once. Every keystroke
   spent on navigation, formatting or picking a category is attention stolen
   from the student in front of them. The note box has to cost almost nothing.
5. **Reuse Greenroom's session spine, do not rebuild it.** See the table above.
6. **Distribution needs an answer before code, not after.** Greenroom ships
   signed zips through Sparkle and GitHub Releases via `scripts/release.sh`
   with an appcast at `docs/appcast.xml`. A second binary would need its own
   EdDSA key, appcast and release script. This is the strongest single
   argument for the sub-brand decision below.

## Positioning

**A named surface inside Greenroom, exactly as Cues is.** One app, one
download, one Sparkle key, one appcast, one site.

Cues is the precedent and it is already proven in this repo: its own settings
tab, its own bench script, its own doc page, its own menu-bar surface, and no
separate binary.

Two apps is not twice the work for one person, it is closer to three times:
two signing identities, two notarisation dances, two release scripts, two
sites, two support burdens. The DMG step already fails on the author's Mac;
doubling that surface buys nothing a sub-brand does not give.

An unnamed feature is the other failure. Nobody can ask for one, link to one
or find one. Cues is useful to talk about precisely because it has a name.

**The trigger for splitting it into its own app:** a user who has no reason to
run Greenroom — a teacher doing in-person presentations only, a debate coach,
a speaking club. Until then, splitting early costs real time and buys a
hypothetical. Splitting later is cheap *because* the name already carries
equity by then.

## Naming

**Marks.**

> Greenroom. Cues while you are on. Marks when you are off.

The repo is already committed to theatre vocabulary: a greenroom is where
performers wait, and Prompter was deliberately renamed to Cues. "Hit your
marks" and "take your cues" are both directing instructions, so the two words
are the same kind of thing, the same shape, from the same world. Side by side
in Settings they look designed together. A teacher also reads "Marks" and
knows what it is in under a second.

Considered and rejected:

| Name | Why not |
|---|---|
| **Notes** | In theatre, "giving notes" *is* this product, so it is the most exact word available. But it is generic, collides with Apple Notes, is unsearchable, and adds mush to an app that already has Chat and Browser |
| **Dailies** | Film term for reviewing the day's footage. Exact fit and it rhymes with a daily class, but needs explaining to a teacher and reads as "daily standup" to anyone technical |
| **Callback** | Theatre's second audition, plus calling the recording back. Memorable, but a loaded programming word and it does not say "feedback" to a teacher |
| **House** | Front of house is where the evaluator sits. Too oblique alone |
| **Blueroom** | The original suggestion. Its only content is "the other Greenroom": it says nothing about what the thing does, the colour is arbitrary where green meant green screen, and it implies a peer product, setting up an expectation of a second app nobody wants to maintain |

The known objection to Marks: the teacher types prose notes, not only scores,
so the name undersells the note box. Judged acceptable, on the grounds that
Cues contains a transcriber, a link resolver and a detector without any of
those being "cues". The brand names the output, not the mechanism. If the
human note should lead instead, **Notes** is the fallback and genericness is
the price.

## Approaches: NOT DECIDED

This is the open question. Three were costed; the session ended before a
choice. All three end in the same place and differ in what gets built first
and what you are stuck with after.

### A. The session folder is the contract

The note box writes `notes.jsonl` into the class folder beside
`transcript.txt`. A separate small app opens a class folder and shows the
timeline, rubric, AI pass and report. The filesystem is the whole API; no code
coupling.

- Effort: M (human ~2 weeks / CC ~3-4 sessions). Risk: low.
- For: ships first, and a real student gets a real report soonest. A directory
  is a seam a Greenroom refactor cannot break. Does not block B later.
- Against: the format drifts unless a versioned schema and a fixture enforce
  it. Two things to sign and release.

### B. Shared SessionKit packages

Extract the spine into local SwiftPM packages — `SessionKit` (metadata,
clips, exporter, summary) and `TranscriptKit` (`MicStream`, `Transcriber`,
`RollingTranscript`) — and build on top. The `Bench/` target is proof the
pattern works in this XcodeGen setup.

- Effort: L (human ~3-4 weeks / CC ~1 week). Risk: medium.
- For: pays down real debt (`CoordinatorController.swift` is 3,630 lines,
  `ParticipantGridWindow.swift` 3,496). One implementation of transcription,
  not two drifting copies. Handles the in-room source cleanly, since capture
  becomes a protocol rather than an assumption.
- Against: refactoring a working app mid-term, with nothing demonstrable for
  three weeks.

### C. Evaluation mode, and the AI reads your notes

No second app. The participant panel becomes the evaluator console: presenting
student full-frame, rubric in the rail, note box where the Live Queue sits.
And the lateral part: **the AI's first pass is not the video, it is your
notes.**

- Effort: M (human ~1.5-2 weeks / CC ~2-3 sessions). Risk: low-medium.
- For: text-only AI is fast, cheap and local; a cohort pass over twelve
  students' notes is a small prompt, not a batch video job. It is the sharpest
  expression of premise 3. One release pipeline, so premise 6 is answered for
  free.
- Against: contradicts the original stated design, which was that the video
  goes for AI review. Greenroom gets heavier. "Grading tool" and "meeting
  tool" in one binary is a positioning problem if the grading half ever needs
  to stand alone.
- **The 10x extension:** the evaluator need not be one person. Greenroom
  already has a chat bridge and a meeting. A TA, a second teacher or the
  student's own peers could type notes from their own machines into one
  session, with the AI as a consistency check *across evaluators*.

**Recommendation on the table when the session ended: A**, on the grounds that
the best version of anything is the one that exists, and that the folder seam
is reversible — you can put B's packages behind it once you know what the
reviewer actually needs. **Take C's notes-first AI idea into whichever is
chosen; it is the cheapest good idea in the set and it is independent of the
others.**

## Open questions

- Which approach. Nothing else can start until this is answered.
- Does the speaker see notes live, or only after? Live makes it coaching;
  after makes it evaluation. Not discussed.
- What the rubric actually is: fixed, per-assignment, or per-teacher.
- Whether marks export to a gradebook, and in what format.
- Whether this shares `transcript.txt` with Cues, which matters because that
  file is currently written only by the Cues pipeline and Cues is held out of
  the release (see `App/Cues/CuesAvailability.swift`). An evaluation feature
  that needs a transcript inherits that dependency.

## Not researched

No web search and no cross-model review were run; both were declined in
session. Before building, check prior art for timeline-annotation and rubric
libraries, and confirm the name "Marks" is not taken in this space.
