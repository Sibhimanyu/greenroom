# Screenroom: evaluated presentations

Status: **built 2026-09-18, both halves.** The office-hours
record below is unchanged from 2026-09-17 apart from this header and the
"What is built" section at the foot, which is the part that is now true rather
than proposed.

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
- **The name is Screenroom.** See Naming.

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

**Screenroom.** Renamed from Marks on 2026-09-18, after the feature was built.

> Greenroom is where you wait before. Screenroom is where you watch it back.

One word, the same shape as the app it lives in, and it names the room whose
whole purpose is this: in film post-production the screening room is where the
director, the crew and the performers sit down together to watch what was
captured and assess the performances. That is the feature, described by an
industry that has been doing it for a century.

Two things pushed Marks out, neither of them taste:

1. **"Marks" already means something else in Greenroom.** `⌥⌘1`/`2`/`5` during
   a class *marks* the last few minutes as a clip, and the Sessions window
   says "Marks appear here afterwards". Two unrelated things under one word,
   in one app.
2. **It named the smallest part.** The scores are one tab. The notes, the
   recording, the transcript, the clips, the report and the agent pass are the
   rest, and none of them are marks.

A web search of the current field — Yoodli, Poised, Orai, Huru, Speakio,
Cuebo, Vocal Image, Quantified, Second Nature, Hyperbound, Marlee, Fluently,
Noctie, Trophi, Orratio, Speaking.app, EchoPitch, Talktune, Kendo — found
nothing using Screenroom, which also closes the "confirm the name is not
taken" item this document opened with.

Also considered at the rename, from a search of theatre, film and classical
rhetoric vocabulary: **Actio** (the classical canon of delivery — voice,
gesture, presence — exactly what is being evaluated, but needs explaining
once), **Ballot** (a debate judge's decision plus written feedback; precise,
but electoral and emphasises judging over helping), **Booth** (where the one
person who sees the whole show sits; closer to Cues than to this), and
**Cutting Room** (where footage is logged and cut; matches the clip export and
nothing else).

### The original 2026-09-17 argument for Marks, kept as history

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

### Chosen: A, with a standalone camera

Decided 2026-09-18. **A**, as recommended, with two things settled that the
session had left open.

**The capture source is a local camera, not the meeting.** The Meeting SDK
renders into one container and its video cannot leave that container's window
- tried, drew black, recorded in DESIGN.md on 2026-08-24 - so building on the
meeting feed means building inside `ParticipantGridWindow.swift` and testing
only by running a real class with a real second person in it. A local camera
opens with no session, no OBS and no credentials, which is the difference
between a note box that can be worked on and one that can be demonstrated
once a morning. It also serves the in-room case the session called half the
product. The meeting feed becomes a second source later, at which point the
protocol the session asked for gets written with two real conformances in
front of it rather than one imagined one.

**Screenroom records its own file.** OBS records the composite - your shared screen
with you keyed into the corner - which is the right picture for a class and
the wrong one for evaluating a speaker. Screenroom wants the speaker, so it writes
`presentation.mov` itself and every note is an exact offset into that one
file.

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
libraries, and confirm the name "Screenroom" is not taken in this space.

---

## What is built (2026-09-18)

The first surface: a window that opens a camera on the person presenting and
takes notes timed to the recording. Held out of every release behind
`ScreenroomAvailability.isReleased`, the same way Cues is - the code ships in any
build made from main, so the gate exists before the first release that
contains it rather than after somebody finds it.

| Piece | File |
|---|---|
| The release gate, and the list of doors | `App/Screenroom/ScreenroomAvailability.swift` |
| The note, and `notes.jsonl` | `App/Screenroom/ScreenroomNote.swift` |
| Camera, microphone and `presentation.mov` | `App/Screenroom/ScreenroomRecorder.swift` |
| Presentation, folder and note-taking | `App/Screenroom/ScreenroomController.swift` |
| The window | `App/Screenroom/ScreenroomWindow.swift` |

### The folder is the contract

One presentation is one folder under `~/Documents/Greenroom`, named for the
presenter and the time, exactly as a class folder is:

```text
Priya Raman - 2026-09-18 10-44/
  presentation.mov   the speaker, camera and microphone
  notes.jsonl        one JSON object per line, one line per note
  session.json       title, so the Sessions window lists it by name
```

`notes.jsonl` is the whole API for the post-processing pass. Nothing links
against Greenroom to read it:

```json
{"atMs":74500,"id":"C7E268BE-…","markedAt":"2026-09-18T06:14:41Z","text":"Room went quiet here — he let the pause run.","v":1}
```

- `atMs` is milliseconds into `presentation.mov` - what a player seeks to and
  an exporter cuts at, and still true after the folder is moved.
- `v` is on every line, not in a header, so a line read in isolation still
  says what it is.
- Dates are ISO 8601 rather than Foundation's seconds-since-2001, because
  something written in another language is going to read this.
- Appended per note, so a crash mid-presentation keeps every note up to it,
  and a torn final line costs only itself.

### The one design decision worth knowing

**A note is stamped from its first keystroke, not from Return.** The moment
worth marking is the moment the evaluator noticed something - which is when
their hands moved. Everything after is them finding the words, and the long,
considered note is exactly the kind worth writing, so stamping on Return would
push the best notes furthest from the thing they describe.

### Not built yet

- The post-processing pass. Nothing reads `notes.jsonl` back.
- The rubric. Open question below, untouched.
- The AI pass over notes (approach C's idea, still the cheapest good one).
- The meeting feed as a second capture source.
- Whether the speaker sees notes live or only after. Still not discussed.

## The second half (2026-09-18)

The pass that turns a watched presentation into something the speaker is
handed.

| Piece | File |
|---|---|
| The rubric, and the marks | `App/Screenroom/ScreenroomRubric.swift` |
| Consistency across the cohort | `App/Screenroom/ScreenroomCohort.swift` |
| The analysis, and `analysis.json` | `App/Screenroom/ScreenroomAnalysis.swift` |
| The pass over the notes | `App/Screenroom/ScreenroomAnalyst.swift` |
| `report.md` | `App/Screenroom/ScreenroomReport.swift` |
| Finding what is on disk | `App/Screenroom/ScreenroomLibrary.swift` |
| Review: player, notes, rubric, actions | `App/Screenroom/ScreenroomReviewWindow.swift`, `ScreenroomReviewController.swift` |

### The AI reads your notes, not the video

Approach C's idea, taken into approach A as the plan recommended. A pass over
twelve students' notes is a few hundred words of text; a pass over twelve
students' video is a batch job with a bill attached. It runs on-device through
the same `FoundationModels` framework Cues uses - no key, no bill, and nothing
about a student's performance leaving the Mac.

**When the model is not there, the pass still runs.** Apple Intelligence is
off on most Macs and absent from all of them before macOS 26. A report that
failed on those machines would make the feature conditional on a setting the
teacher may not control, so there are two engines and the analysis records
which one wrote it. The counted engine claims nothing it cannot show: how many
notes, across how long, where the longest silence was, which rubric line
scored lowest. `report.md` names the engine in its last line either way.

### Consistency is arithmetic, and stays that way

Premise 3 is the reason this is worth building, and it is deliberately NOT the
model's job. Every finding in `ScreenroomCohort` is a mean, a spread or one
correlation. A model asked "were these marked consistently?" would answer
confidently either way and could not show its working, which is the wrong
property for the one output whose entire purpose is to be shown to a student
arguing about a grade.

Three findings:

- **The order effect** - the classic nobody can see from inside a Friday
  afternoon. Correlation between the order presentations were marked in and
  what they scored. Needs five presentations; flags at |r| >= 0.5.
- **Out-of-step lines** - this student's mark on one criterion against the
  group's. A unanimous group is the strongest baseline there is, so it answers
  to a plain distance; a group that disagreed with itself answers to its own
  spread.
- **Overall harshness** - this student's total against the group's.

### Two audiences, two documents

The cohort findings are about the MARKER, not the student. "Screenroom drifted
downward through the session" is a fact about an afternoon, and putting it in
the student's copy invites an argument about somebody else's grade. So
`report.md` is written for one of two audiences and the speaker's copy has
none of it. The teacher's copy does, because when a grade *is* questioned, the
person answering should already have looked.

### The rubric is per-teacher with a per-presentation snapshot

The open question, answered. A teacher marking a cohort should not retype the
rubric twelve times, so the current rubric carries in `UserDefaults`. But a
rubric edited in November must not silently re-interpret marks given in
September, so each presentation stores its own copy of the criteria it was
marked against, and nothing later rewrites them. That snapshot is also what
makes the cohort pass honest: it only compares presentations whose criteria
actually match.

### The folder, in full

```text
Priya Raman - 2026-09-18 10-44/
  presentation.mov       the speaker
  notes.jsonl            one line per note, stamped into the recording
  rubric.json            the criteria as they were, and the marks
  analysis.json          what the pass produced, and which engine produced it
  report.md              the thing the speaker is handed
  session.json           title, for the Sessions window
  Clip 10-46-12 (20s).mp4   one per note, on request
```

### Still not built

- **More than one evaluator.** A TA or the student's peers typing notes into
  one session from their own machines - approach C's 10x extension. Needs a
  transport; nothing here has one.
- **The meeting feed as a capture source.** Still local camera only.
- **Whether the speaker sees notes live.** Still not discussed; today they see
  nothing until the report.

## The three gaps, closed (2026-09-18)

### More than one evaluator - built, then removed

Built on 2026-09-18 and removed the same day, on the author's call: notes
gained an `author`, a second evaluator's `notes.jsonl` could be imported and
merged by id, and `ScreenroomAgreement` reported where two evaluators had and
had not written about the same moment.

Nobody had asked for it. It was built because the plan called it the 10x
extension, which is a reason to keep an idea and not a reason to ship a
button. Without a transport the flow was "have your TA email you a file",
which is a worse version of a conversation, and the import button was the only
door to about two hundred lines of analysis that could otherwise never run.

The pieces are in git if a real second evaluator ever turns up. `notes.jsonl`
stays at v2 rather than reverting to v1: v2 lines with an `author` in them
exist on the machines this was built on, and a reader seeing one is entitled
to believe a claim that was briefly true. The field now decodes and is
ignored, which is the property that made per-line versioning worth having.

### More than one evaluator — without a transport

The plan's 10x extension. It arrives as files, not as a network.

Notes are files (approach A), so a second evaluator is a second
`notes.jsonl`, handed over however people already hand files over, and
merging is a union by `id` — the same attachment imported twice adds nothing
the second time. A transport would have bought a server, a pairing flow, a
failure mode mid-presentation and an answer to "what happens when the TA's
laptop sleeps", all to save an email. When there is a live meeting to carry
it, a transport can be added underneath this same merge and nothing above it
changes.

`ScreenroomNote` is at **v2**: it gained an `author`. A v1 line decodes unchanged,
because the field is optional and the version is on the line rather than on
the file. Nothing was migrated and no file was rewritten.

What the merge buys is `ScreenroomAgreement`, and it is arithmetic like
`ScreenroomCohort`, not a question put to a model:

- **Moments more than one evaluator wrote about**, clustered within twenty
  seconds — wide enough that one person typing as it happens and another
  waiting to see how it resolves still count as one moment.
- **"The evaluators rarely wrote about the same moment"**, flagged for
  action. Two people watching one presentation and noticing different things
  is usually a rubric that has not been agreed, rather than a presentation
  that was ambiguous. That is a fact about the marking, which is exactly what
  premise 3 is about.
- **"Nothing X wrote lines up with anyone else"** — either they were watching
  for something nobody else was, or their clock and the recording's disagree.

### The meeting feed — refused by the SDK, reached another way

`ScreenroomCaptureEngine` is the abstraction the plan asked for on day one,
written now that there is a second conformance to shape it. Two engines:

- **Camera** — a person presenting in the room.
- **Screen** — a window or a display, via ScreenCaptureKit.

The screen engine is the answer to the remote presenter, and it is a
deliberate detour. Screenroom cannot ask the Meeting SDK for a student's video:
the SDK renders into one container, that video cannot leave the container's
window (DESIGN.md, 2026-08-24 — the re-parenting experiment drew black), and
the capability matrix rules out a second container. What Screenroom *can* do is
point at the window the student is already visible in. That works with
Greenroom's own participants panel, with the native Zoom app, with Meet in a
browser, with a recording being played back — and unlike anything routed
through the SDK it can be tested on this Mac with no meeting and no second
person.

It captures **system audio**, not the microphone, which is the opposite of
the camera engine's choice and right for each: a camera in the room hears the
room, a window on screen is heard through the machine playing it.

**This is the first thing in Greenroom to want Screen Recording permission.**
Until now that permission belonged entirely to OBS, and three places said so
— `README.md`, `docs/guide.html` and the transparency page, which literally
claimed "Greenroom contains no screen-capture code". All three were rewritten
in the same commit. They now say what is true: the code exists, Screenroom is held
back so nothing in the shipping build can reach it, macOS never asks, and
when Screenroom ships this becomes a fourth permission.

### Does the speaker see notes live — the teacher decides, per presentation

`ScreenroomSpeakerView`: one column, large type, newest at the bottom, no controls
— readable across a room, for the second display or a mirrored iPad.

**It is off unless it is asked for, every single time, and the setting is not
stored.** A persisted preference would mean a teacher who once coached a
rehearsal is silently still coaching in an exam three weeks later, and the
student would be the one to find out. Screenroom opens as an evaluation tool on
every launch; coaching is something you turn on for the next twenty minutes.
That is the plan's open question answered by refusing to answer it once for
everybody.

### Still not built

- A live transport for multi-evaluator notes. The merge is the seam it would
  go under.
- The Zoom meeting feed as a direct capture source. Blocked by the SDK, not
  by effort.

## Handing it over as video (2026-09-18)

`report.md` is the document a teacher sends. This is the other half of the
same thought: a student watching themselves present, with the note the
teacher typed appearing at the moment it was typed about. Reading "at 6:40
you lost the thread" and watching yourself lose the thread while the sentence
appears are not the same feedback, and the second needs no cross-referencing
between a document and a scrubber.

`App/Screenroom/ScreenroomVideoExport.swift`, two outputs:

- **Video with the notes written on it** - `presentation-with-notes.mp4`. One
  file, plays anywhere, cannot be separated from its notes. Costs a
  re-encode, so minutes rather than seconds, and the notes can never be
  turned off.
- **Subtitles** - `notes.srt`. Written in a second, no re-encode, nothing
  lost, every player can toggle them, YouTube takes the file directly. But it
  is a second file to keep beside the first, and a student who double-clicks
  the video may never see it.

A teacher sending one file to one student wants the first. A teacher
uploading a term of presentations wants the second.

**Timing.** A card appears two seconds BEFORE its note and stays six, cut
short when the next note is due but never under two and a half. The lead is
the same rule that runs through all of Screenroom - a note is stamped at its first
keystroke, so the thing it describes is already happening. The floor matters
more than the ceiling: two notes typed nine seconds apart are a teacher
reacting quickly, and the first flashing past in half a second would be the
one the student most needed to read.

**The look** follows DESIGN.md: one near-black card bottom-left, system font
for the words, mono for the timestamp, the logo's lime on the timestamp only,
no ornament. Sizes derive from the video's own height, so a 720p capture and
a 1080p one produce the same picture at different scales. The card is
measured to its own text, because a note can be two words or three lines and
a fixed height would clip exactly the part the teacher went to the trouble of
writing.

**Verified by rendering.** Twenty seconds of flat grey were synthesised,
annotated, and read back frame by frame: 25% of the bottom-left corner is
non-grey while a note is up and 0% in the one-second gap between cards. That
is the overlay actually reaching the pixels, not just the export reporting
success.

## Your own agent (2026-09-18)

Screenroom' own passes are deliberately small: an on-device model writing feedback
from the notes, and arithmetic over rubrics and timestamps. That is the right
floor - it works on a Mac with nothing configured and it costs nothing. It is
not a ceiling. A teacher who already runs Claude Code or Codex has a much
larger model a keystroke away, and what Screenroom has assembled is exactly the
material such a thing is good at reading.

No API keys, no accounts, no model configuration inside Greenroom. Screenroom
writes a brief and runs the CLI you already have, in your own login shell,
with your own credentials.

### First, give it something to read

A coding agent cannot watch an `.mov`. Handing one a video file and asking
about body language gets a confident answer about a file it never opened. So
"prepare" does two things, both on this Mac:

- **`ScreenroomTranscriber`** - Apple's speech recogniser over `presentation.mov`,
  pinned to on-device. `SFSpeechRecognizer` will silently fall back to
  Apple's servers when the local model is missing, which would send a
  recording of a named student off the Mac because a download had not
  happened. So it checks `supportsOnDeviceRecognition` first and **refuses
  rather than falls back**. Writes `transcript.txt` and `words.json`.
- **`ScreenroomFrames`** - one still every twenty seconds into `frames/`. Twenty
  because a ten-minute talk then gives thirty images, which a model attends
  to properly; every five seconds gives a hundred and twenty, which it skims.

### Then count what can be counted

`ScreenroomSpeechMetrics`: filler words, words per minute in half-minute windows,
pauses over two seconds, talk ratio. Same rule as `ScreenroomCohort` and
`ScreenroomAgreement` - it is arithmetic and it stays arithmetic. It also makes
the agent pass better: one handed "you said 'basically' 34 times, 4.1 a
minute" spends its attention on what that means, where one asked to count
spends it counting, and gets it wrong.

The filler list is stated openly so it can be argued with, and carries the
Indian-English ones that actually turn up in this classroom. "So" is
deliberately excluded: it opens a sentence legitimately far too often, and
flagging it produces a number a student will correctly ignore, which teaches
them to ignore the rest.

### The brief says what the agent cannot know

`BRIEF.md` is written into the folder - a file, so the teacher can read
exactly what is being asked in their student's name, and edit it. Its most
important section is the one about limits:

- It cannot watch the video; there is no video it can open.
- From stills it CAN judge posture, reading off a screen, facing the room,
  what is on the slide. It CANNOT judge gesture, movement, pace, energy or
  eye contact - twenty seconds apart is far too coarse - and is told not to
  infer them.
- It cannot hear anything. Tone, volume and nerves are not available.
- Where its reading and the teacher's notes disagree, prefer the teacher's.
  They were in the room.

### Read-only, and the output comes back through stdout

Both CLIs take a read-only sandbox and both are pinned to one in the default
commands. An agent that cannot write cannot damage a folder holding the only
copy of a student's presentation, and Screenroom saving the output itself means
there is nothing to negotiate about permissions in a non-interactive shell.

Verified against the real binaries rather than their documentation:
`codex exec` refuses outright without `--skip-git-repo-check` when the folder
is not a git repository, which a Documents folder never is. Both defaults
were run end to end before being committed.

### This is the one thing that can leave the Mac

Everything else in Screenroom runs here. This does not, and it is the only feature
in Greenroom whose destination Greenroom does not control. It is off by
default, the command is shown rather than hidden, and the transparency page,
the guide and the README all say plainly that what a cloud agent does with a
transcript and stills of a named student is between the teacher and it.

## Verbatim, or the numbers mean nothing (2026-09-18)

The first version of the transcription step used Apple's `SFSpeechRecognizer`
because it is already there and needs nothing installed. That was wrong, and
wrong in the worst available way: silently.

Apple's recogniser is built for dictation. "um, I think, uh, we should" is
noise a person did not mean to type, so it smooths disfluencies away and
punctuates what is left. Correct for dictation. Fatal here, because
`ScreenroomSpeechMetrics` exists to count exactly the words it removes. A filler
count taken from an Apple transcript is not a rough figure; it is a
measurement of how well Apple deleted the evidence, and it arrives as a
confident zero next to a student's name.

**Measured, not assumed.** The same sentence, spoken by `say` and handed to
whisper.cpp:

```text
spoken:  "Um, good morning everyone. So today I want to, uh, you know,
          talk about how tigers are, like, basically disappearing."
whisper: "Um, good morning everyone, so today I want to, uh, you know,
          talk about how tigers are, like, basically disappearing."
```

Every filler kept, each with a millisecond offset. `-ml 1 -sow` is the
documented way to get word-level timings out of whisper.cpp: maximum segment
length of one, split on word rather than on token, so each JSON segment is a
single word.

No `--prompt` priming, deliberately. Seeding whisper with a line of fillers is
the usual trick for making it keep them, and it was tried: the output was
identical with and without. A prompt that changes nothing on clean input can
only hurt on messy input, by biasing the model toward hearing fillers that
were not said. A false "um" in a student's report is worse than a missed one.

### What changed

- **whisper.cpp is the default**, found on `PATH` through a login shell, with
  its model discovered under `~/Library/Application Support/Greenroom/whisper/`
  first so a stale test model in a Homebrew share directory cannot win.
- **Apple's is kept as a fallback**, not deleted: a Mac with no whisper should
  still get a transcript and an agent pass, just not a filler count. Its
  `addsPunctuation` is now off, since punctuation is invented by a model
  reading the words back and this path's whole problem is that too much has
  already been decided about the text.
- **`speech.json` is at v2** and records `engine` and `verbatim`. When
  `verbatim` is false, `fillerCount` returns zero whatever the array holds -
  the guard is on the number everything prints, rather than on each reader
  remembering - and the report says in a sentence that fillers were not
  counted and why.
- **Audio is converted in-app**, not by shelling out to ffmpeg. ffmpeg is on
  the author's Mac and on a lot of developers' Macs, and on none of the Macs
  this is for. The external tool Screenroom does require, whisper, earns it by
  being the thing that cannot be replaced; a format conversion does not.

## Two features removed (2026-09-18)

Both on the author's call, both after being built, and both for the same
reason: they answered questions nobody had asked.

**Cut to the notes** cut one clip per note out of the recording. It was
written before the annotated video export existed, and once that shipped it
was redundant - a student watching `presentation-with-notes.mp4` sees every
note in place, in order, without opening twenty files. Clip cutting for
*classes* is untouched; that is `⌥⌘1`/`2`/`5` and a different feature.

**Import notes** is covered above.

What both had in common is worth writing down, because it is the failure mode
of building fast: each was a reasonable idea, implemented well, verified, and
of no use to the person the tool is for. The test that would have caught them
earlier is not "is this good" but "who asked".

## The report becomes a dashboard (2026-09-18)

It was living in the 320pt notes column, which is the right width for a queue
of notes and the wrong one for a document somebody is about to send a student:
the summary wrapped to nine lines, the rubric was a list of numbers, and the
speech figures were four sentences of prose carrying numbers a chart answers
in a glance.

`ScreenroomReportView` is its own window: the four headline numbers, the
summary, what worked and what to change, the rubric as meters, pace over time,
filler words, the notes on a time axis, every note, the consistency block, and
a provenance line saying which engine wrote which part. It opens itself when a
pass finishes, because that is the point of pressing the button.

### Every chart is one series

Not a limitation - the subject. This is one student's presentation, so a
categorical palette would be colouring rows by their position in a list. One
series means one hue, no legend (the heading names it), and the de-emphasis
grey for everything that is context rather than data. Nothing here needs a
colourblind-safety pass because nothing here asks a reader to tell two colours
apart.

Three things are deliberately **not** charts:

- The four headline numbers are **stat tiles**. A one-bar bar chart is the
  classic way to turn a number into a worse number.
- A rubric line is a ratio against a limit, so it is a **meter** - a filled
  track - not a bar on a shared axis. Five meters at five different maxima on
  one axis would compare things that are not comparable. The group's average
  appears as a hairline on the track: one bar against a baseline, which is
  what "how does this compare" actually asks, rather than a second series.
- The notes are **marks on a time axis**. They have position, not magnitude.

### Colour

`Brand.fill` (the logo's lime) for fills, `Brand.text` for anything green with
words in it, grey for context, and **no amber anywhere** - amber means "leaves
your Mac" in this app, and a rubric line is not network traffic. The
consistency findings carry an icon and a label rather than a warning colour,
which is what a status mark is supposed to do regardless.

`Brand` gained `text` and `fill` in this change, which starts closing the
first item on DESIGN.md's drift list: green text was using the asset-catalog
accent (`#5FA83C`, retired) at about 3.3 contrast. `Brand.text` is
`--brand-green` #2F6118 in light mode and the lime in dark mode, because the
rule is about the background rather than about the colour.

### Export asks where the file goes

Writing `report.md` into the folder is right for a file the app owns and wrong
for a document about to be sent to a student. Every export now opens a save
panel, defaulting to the presentation's folder and to a name built from the
student's own: `Priya Raman - 18 Sep 2026.pdf`.

PDF is rendered from the dashboard itself through `ImageRenderer`, not laid
out a second time - a second layout is a second thing to keep in step, and the
point of the PDF is that it is what is on screen. Pagination slices the tall
render a page at a time; verified by rendering a long view, reading the pages
back with `CGPDFDocument` and measuring the ink on each, so "three pages" is
three pages with content on them rather than one page and two blanks.

## One pipeline (2026-09-18)

The analysis had grown six controls for one outcome: whisper or Apple, a
prepare-material button, an agent on/off toggle, which agent, its command, and
then separately a "read the notes" button. Six ways of asking the same
question, which is *make me a report*.

**Setup is a setting. Running is a button.**

Press **Analyse** and the pipeline runs in one order, every time:

```text
transcribe  ->  take stills  ->  count the speech  ->  compare the marking
            ->  write the report  ->  open it
```

### What stopped being a choice

- **The transcriber.** Whisper when this Mac has it, Apple's when it does not.
  That is a fact about the Mac, not a preference: Apple's deletes the
  disfluencies the speech analysis exists to count, so nobody would choose it,
  and offering the choice only invited somebody to get it wrong. Settings
  reports which one will run, as a fact rather than a control.
- **Preparing the material.** There was never a reason to transcribe and then
  not analyse.
- **Which engine writes it.** A ladder, walked automatically: your agent when
  one is set up, Apple's on-device model when it is not, arithmetic when
  neither is available. The report names the engine, so a degraded run is
  visible rather than silent.

### Every stage is best-effort

A Mac with no whisper still gets stills. A presentation with no recording still
gets a report from the notes alone. A failed agent falls through to the
on-device pass rather than failing the run. A missing CLI should cost the extra
detail, not the report.

### The agent now returns the same shape as everything else

It used to print free-form Markdown into `agent-report.md`, which the report
could not lay out beside the on-device pass. It is now asked for one JSON
object with the same four fields the on-device model fills, so the dashboard
renders identically whichever engine ran.

The parser is deliberately tolerant. Agents wrap JSON in a code fence and say
"Here is the report:" first, however plainly they are told not to, so it takes
the outermost `{...}` it can find. When even that fails the whole output
becomes the summary - worse-looking and still readable, rather than nothing.
Verified against clean JSON, fenced-and-prefaced JSON, prose with no JSON in it
at all, and an object with numbers and a wrong-typed field in its arrays.

## One library: classes and presentations (2026-09-18)

There were two windows listing the same folders. **Sessions** had the player,
the clips, the YouTube links, rename and delete. **Past Presentations** had the
notes, the rubric and the report. Two lists of `~/Documents/Greenroom` is one
too many, and the split was an accident of the order things were built rather
than a distinction a teacher would draw.

It also left the analysis unreachable for the thing Greenroom mostly records.
A class recorded through Start has a video, a microphone track and a teacher
who was in the room - everything the analysis needs. It was invisible only
because `ScreenroomLibrary` looked for `notes.jsonl`, and a class has none.

**The notes are what a presentation has EXTRA, not what makes a folder worth
opening.** A transcript, filler counts, pace and an agent pass need a
recording. The rubric works on anything. So the library now lists any folder
holding something to analyse, and Screenroom's half moved into Sessions as a
third detail tab beside Recording and Transcript.

Merged **into** Sessions rather than the other way around: Sessions already had
the player, the clips list, the YouTube links, delete-to-trash, rename and the
disk banner, and porting all of that into a newer window would have risked
shipped features to save writing one pane.

Two consequences worth recording:

- **The Transcript tab is no longer Cues-only.** It was gated on
  `CuesAvailability` because the Cues pipeline was the only thing that wrote
  `transcript.txt`. Screenroom's Analyse writes one too, so either feature can
  now fill it, and the tab appears when either is in the build.
- **A note seeks the window's own player.** The controller takes an
  `externalSeek` closure, because Sessions has a player with a scrubber
  already on screen and a second hidden one would be the wrong picture moving.

### Finding the recording in a folder

`presentation.mov` when Screenroom recorded it; otherwise the largest playable
file that is neither a clip nor Screenroom's own annotated export. Largest
rather than first, because a class whose tape was stopped and restarted leaves
several files and the long one is the class. Verified against a folder holding
an OBS `.mkv`, a `Clip ….mp4`, a `presentation.mov` and a bigger
`presentation-with-notes.mp4` - the clip is never mistaken for the source, and
neither is the export.

## The rubric becomes an answer (2026-09-18)

It was a form: five criteria, a row of buttons, and a teacher clicking numbers
before or after watching. It is now an output of the analysis. The pass that
reads the notes, the transcript, the stills and the counted speech marks every
line and says why in one sentence.

**The reason is the important half.** A score with nothing behind it is an
assertion, not feedback. That was survivable while a teacher typed both and
could remember their own reasoning; it is not survivable when something else
does the marking and the student asks why. So every mark carries its reason
next to the number wherever the number appears, and `rubric.json` records
`markedBy` - a mark from a large model reading a transcript and one from a
teacher who was in the room are different kinds of claim.

Both engines mark. The agent is asked for a `marks` array in the same JSON it
already returns; the on-device model gets a `GeneratedMark` in its schema. The
counted fallback cannot mark and says so rather than leaving a silence:
counting cannot judge.

The parsing is defensive, because models asked for an integer answer `"3"`,
`2.0` and sometimes 9 on a scale of 5. Scores are clamped to the criterion's
own maximum - a total that beats its own denominator is the first thing a
student notices - titles match case-insensitively, and a line that is not in
the rubric is ignored rather than invented.

### What this cost: the drift finding

The plan's premise 3 was the reason `ScreenroomCohort` existed. You grade
twelve students on a Friday afternoon, your standards drift, and you cannot see
it from inside your own afternoon. That premise is **void** once the marking is
done by an engine: it marks each student in a separate run with no memory of
the others, so there is no afternoon and no fatigue and no drift to find.

The order-effect correlation has been removed rather than left in to report a
number that could only ever be noise. What survives is the plainer and still
useful question - where does this student sit against the group, and is any one
line out of step with it - which is worth knowing before the grades go out and
when a grade is questioned.

### Open: there is no way to disagree with a mark

The grade is the teacher's responsibility and currently nothing lets them
change one. Deliberate for now, since the point of the change was to remove the
form, but a teacher who thinks the engine's 3 should be a 4 has no recourse
short of editing `rubric.json` by hand.

## The waiting state was lying (2026-09-18)

Reported from two screenshots, and both problems were real.

**The bar sat at zero.** On the agent step it was a determinate bar with
nothing to fill it, because an agent reports nothing at all until it answers.
A bar that does not move is not a progress bar, it is a picture of a hang, and
that is exactly how it read.

Now: determinate where something can fill it (whisper reports how far through
the file it is; stills report done-of-total), indeterminate where nothing can
(an agent thinking, Apple's recogniser working). Plus three things that are
true either way - **which step of how many**, **how long it has been going**,
and **the last complete line the tool itself printed**.

**It was showing stdout.** The log tail was the agent's standard output, which
is the *answer*: the report's own sentences appeared a character at a time,
truncated mid-word, presented as progress. Progress goes to **stderr** in both
whisper and the agent CLIs. Swapped, in both.

It also kept the last 280 characters rather than the last few lines, which cut
words in half. Whole lines now - and the raw stream is kept apart from what is
shown, because folding them together glued each arriving chunk onto the end of
the displayed line. That one was caught by a test rather than by looking.

**There was no way out.** There is a Stop now, and it terminates the child
process as well as cancelling the task. Both, in that order: a cancelled Swift
Task leaves the CLI running - whisper burning a core, an agent still spending
tokens on an answer nobody will read - because a child process knows nothing
about Swift concurrency. Verified: a cancelled Task leaves it alive, terminate()
ends it, and the stderr reader finishes rather than hanging when it does.

Nothing is written until a run finishes, so stopping is safe. After three
minutes the pane says so, rather than offering the excuse up front.

## Two more, from screenshots (2026-09-18)

### The agent step showed nothing at all

Everything before it takes seconds; it takes minutes. A spinner and a step
counter for two minutes is not much better than a stuck bar.

The cause was a fix that went too far. Streaming the agent's **stdout** put the
report's own sentences on screen a character at a time, so it was switched to
**stderr** - and `claude -p` writes nothing to stderr, so the window went
silent for the longest step in the run.

Both CLIs will stream structured events if asked: `--output-format stream-json
--verbose` for Claude Code, `--json` for Codex. Their shapes are completely
different and both are handled by what each actually emits rather than through
a shared abstraction neither fits. What the window shows now is what the agent
is doing:

```text
Reading transcript.txt
Looking for frames/*.jpg
Thinking…  (turn 3)
```

The answer arrives inside the stream too - Claude's `result` event, Codex's
last `agent_message` - so stdout is read rather than displayed. A command that
streams nothing falls back to treating stdout as the answer, which is what
always happened.

Two bugs the tests caught rather than the eye: a glob **pattern** was being run
through `lastPathComponent`, so `frames/*.jpg` displayed as `*.jpg` and threw
away the only informative part; and a custom command printing the report as
plain JSON had its output silently dropped, because any line starting with `{`
was being treated as an event. An event is now a JSON object **with a `type`** -
anything else is the answer.

### Notes can be added while watching it back

A class recorded through Start has no notes at all, and a presentation often
ends with fewer than the evaluator meant to take, because typing while somebody
is speaking is the hardest part of the job. Watching it back is the second
pass, and the second pass needed somewhere to write.

The Notes tab has a composer at its foot, and notes can be deleted. A note
added here is stamped at the **player's position** rather than at the first
keystroke: the live window corrects for the evaluator being behind the moment,
but here the recording has been scrubbed to the moment deliberately, so the
playhead is already the answer.

The file is rewritten in time order rather than appended, because a note added
at 2:14 belongs at 2:14 and not at the end. The live path still appends, so a
crash mid-presentation cannot cost more than the note being typed.
