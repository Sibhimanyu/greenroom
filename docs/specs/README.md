# Specs

Durable, committed specs for Greenroom work. Scratch plans in `.context/` are
gitignored and get lost; once a plan is agreed, its spec lives here.

Every piece of work follows Matt Pocock's engineering skills: the words come
from the domain model, tests come first (TDD), and code review checks the
change against its spec. A spec is what makes the last two possible.

## How a spec is written

- **One file per feature or per batch of fixes.** Name it after the feature
  (`layouts-builder.md`) or the date and source (`2026-11-25-owner-bug-list.md`).
- **Numbered requirements.** R1, R2, R3 and so on. A number is never reused or
  renumbered, even if the requirement is dropped (mark it dropped and say why).
- **Acceptance criteria as testable statements.** Each requirement lists what
  must be true, written so a test or a person can say yes or no to it. Write
  "Given X, when Y, then Z" or a plain "Z is true", never "should feel".
- **Cite them.** A test that proves a criterion names it in a comment
  (`// Spec: layouts-builder R4.2`). The code-review "Spec" axis checks each
  changed behaviour against the R numbers it touches, and TDD starts from the
  criteria: write the failing test for R4.2, then the code.
- **Phases link to requirements.** A phase (P1, P2...) lists the R numbers it
  delivers, its status and its commit.
- **Words from the glossary.** Use the terms in [GLOSSARY.md](../../GLOSSARY.md)
  exactly. Say "the meeting" or "everyone", never "class". When a term is new
  or changes, update the glossary first.
- **Decisions that are hard to reverse** go into an ADR in
  [docs/adr/](../adr/) and the spec links to it.
- **Plain words.** Short sentences, no em dashes.

## Status

Each requirement carries one status, and it is kept current in the same commit
that changes it:

| Status | Means |
| --- | --- |
| planned | Agreed, not built. |
| built | Merged with its tests green. Not yet checked in a real meeting. |
| verified live | The owner (or an agent with the owner watching) checked it in a real Zoom meeting, and the spec says when. |

A phase may also be "in progress" while an agent is building it. A
requirement is never "verified live" because a test passed: tests prove
"built". Only a live check moves it on.

## Index

| Spec | What it covers | Requirements |
| --- | --- | --- |
| [2026-11-25-owner-bug-list.md](2026-11-25-owner-bug-list.md) | The owner's bug list of 2026-11-25 and the fixes that followed it the same day | R1 to R13 |
| [layouts-builder.md](layouts-builder.md) | The merged Layouts tab: layouts own the camera piece and what's shared, one rule for who sees what | R1 to R24 |
| [meeting-setup.md](meeting-setup.md) | One owner for the layout's camera state, camera piece and share: saved before a meeting, for this meeting during one | R1 to R6 |
| [camera-look.md](camera-look.md) | One owner for the camera look (background, picture, removal, mirror): same keys, one value, one rule for what reaches the Stage | R1 to R5 |
| [shape-preview.md](shape-preview.md) | One owner for the live shape preview: who looks, when the picture runs and stops, what is published | R1 to R9 |
| [shelved.md](shelved.md) | Features the owner has parked (code kept, not shipped): Record the Mac's own sound, with how to test it | S1 to S4 |

## Related

- [GLOSSARY.md](../../GLOSSARY.md): the domain words.
- [docs/adr/](../adr/): decisions and why. Start with
  [0001: Layouts own the camera piece and what's shared](../adr/0001-layouts-own-camera-and-share.md).
- [AGENTS.md](../../AGENTS.md) and `codemap/*.md`: where the code lives.
