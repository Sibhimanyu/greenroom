# Participant window redesign: Classroom Console

## Goal

Replace the current dense, permanently visible control rail with a participant
window that supports a teacher's real live-class loop:

1. Watch the class.
2. Notice exceptions that need attention.
3. Act on one student or the whole room.

The participant grid is the primary surface. Controls and secondary state must
not compete with it for space or attention.

## Product decision

Use a **Classroom Console** layout:

```text
┌────────────────────────────────────────────────────────────────────────────┐
│ Class name · 42:18     ● Recording locally    18 students  2 hands  1 wait │
│                                              [Mute all] [Chat] [More •••]   │
├───────────────────────────────────────────────────┬────────────────────────┤
│                                                   │ LIVE QUEUE             │
│                                                   │                        │
│             PARTICIPANT GRID                      │ 1 waiting to join      │
│             (primary surface)                     │ Priya                  │
│                                                   │ [Admit] [View all]     │
│                                                   │ ────────────────────── │
│                                                   │ 2 hands up             │
│                                                   │ 1. Arun  2. Meera      │
│                                      ┌─────────┐  │ [Next] [Lower all]     │
│                                      │ You PIP │  │ ────────────────────── │
│                                      └─────────┘  │ Assist / Cues       │
│                                                   │ only when it has cards  │
└───────────────────────────────────────────────────┴────────────────────────┘
```

The Live Queue is not chat and not a general activity feed. It is a short,
strictly prioritized list of exceptions requiring teacher action:

1. People waiting to join.
2. Raised hands, in the order the hands were raised.
3. Cues suggestions, only when no more urgent state needs the space.

When there is nothing actionable, the right side collapses to a slim status
strip or shows only the Assist section if Cues has a card.

## Problems in the current layout

- The permanent self-video / control rail takes substantial width from the
  participant grid even though self-preview is occasionally useful rather than
  continuously primary.
- Global commands, session facts, hand/waiting state, and Cues cards share
  one long scrolling column. Important state can be below the fold.
- Controls have too much equal visual weight: routine controls, session setup,
  meeting administration, and destructive actions all live in the same grid.
- A selected participant gets a separate context strip, creating another
  competing visual region instead of a coherent temporary inspector.
- Cues changes rail sizing and displaces other information, making the
  layout feel unstable as cards arrive.

## Information architecture

### 1. Session header — always visible

Height: 48–56 pt.

Contents, left to right:

- Class name and elapsed duration.
- Local recording state.
- Compact live totals: participant count, raised-hand count, waiting count.
- Three immediate actions: `Mute all`, `Chat`, `Record`.
- `More` menu for all other global operations.

Only status that changes an immediate decision belongs in the header. Do not
repeat the same facts in another section.

### 2. Participant canvas — primary region

The participant grid receives the remaining width after the right-side Live
Queue. It remains the visual center of the window.

- Preserve existing gallery paging and featured-speaker behavior.
- Keep a small self-preview as a movable or corner-anchored picture-in-picture
  overlay. It should not control the layout width.
- Clicking a tile selects the participant and opens the inspector.
- Keep gallery navigation near the bottom of the grid, only when needed.

### 3. Live Queue — fixed-width exception panel

Width: 300–340 pt on a dedicated reference display. It must not grow and steal
grid space as content changes.

Use distinct stacked sections:

#### Waiting room

- Display only when at least one person is waiting.
- Show up to three names and `+N more`.
- Primary action: `Admit all` if more than one person is waiting; `Admit` for a
  single visible person.
- Secondary action: `View all` opens the existing participant-management menu
  or a dedicated list.

#### Raised hands

- Display only when at least one hand is raised.
- Preserve existing raise-time ordering.
- Show the first three people as an ordered queue.
- Primary action: `Next` selects/highlights the first raised hand.
- Secondary action: `Lower all`.

#### Assist (Cues)

- Display only when no waiting-room or hand state requires the same priority
  space, or give it a compact one-card slot below those sections.
- Show one newest card plus a count for additional cards.
- Actions: `Open`, `Send`, `Dismiss`, and `Show all`.
- Never cause the participant grid or Live Queue width to resize.

### 4. Participant inspector — temporary contextual drawer

Selecting a participant opens a 280–320 pt inspector over the right edge of
the participant grid (or replaces the Live Queue temporarily on narrow
screens). It closes with Escape, clicking outside, or selecting another tile.

Contents:

- Large name and concise state: muted, video off, hand raised, co-host,
  spotlighted.
- Direct actions: Mute / Ask to unmute, Stop video / Ask to start video,
  Spotlight, Remove.
- Less frequent controls in an overflow menu.

Do not keep an empty inspector visible. A participant-specific action should
appear only in the context of the chosen person.

### 5. More menu — low-frequency global actions

Move these out of the permanent surface:

- Snap windows back.
- Show/hide live speaker.
- Greenroom main window.
- Reactions.
- Meeting information / invitation.
- Security controls.
- Participant-wide meeting settings.
- End session, isolated at the bottom with destructive styling and confirmation.

`End session` must remain visually and behaviorally distinct; it is never part
of the three immediate controls.

## Responsive behavior

### Dedicated reference display / wide window

- Grid + fixed Live Queue side by side.
- Inspector overlays the grid edge, preserving the queue.
- Self-preview is a compact overlay in the lower corner of the grid.

### Laptop / narrow window

- Grid uses full width by default.
- Live Queue becomes a slide-in panel from the right, opened automatically for
  new waiting-room or raised-hand events and otherwise available from the
  header count badges.
- Inspector replaces the slide-in Live Queue; back returns to the queue.
- Self-preview is hidden by default and available through a header/menu toggle.

Do not maintain the current behavior where a narrow layout merely makes a
single vertical rail scroll more aggressively.

## Visual direction

- Dark, quiet canvas with video tiles as the visual focus.
- One strong alert treatment for waiting-room entries and raised hands; use a
  dot/badge plus position and copy, not color alone.
- Live Queue section headers are compact uppercase mono labels consistent with
  the project design language.
- Use standard prose for names and action labels.
- Give only urgent actions filled treatment. Routine actions should be quiet,
  bordered or text buttons.
- Use 150–250 ms state transitions only for queue insertion/removal, inspector
  opening, and selected-tile focus.

## Implementation plan

### Phase 1 — Extract state from the rail

1. Identify and separate state currently mixed into `RootView`:
   - header/session facts;
   - waiting list;
   - hand queue;
   - Cues cards;
   - participant selection;
   - global command state.
2. Add a lightweight presentation model, for example
   `ParticipantConsoleState`, derived from the existing roster, session,
   waiting, and `CuesSurfaceState` values.
3. Preserve current Zoom SDK calls and their confirmation behavior; this is a
   presentation reorganization, not a meeting-control rewrite.

Acceptance:

- Existing roster, hand-order, paging, and action behavior work unchanged.
- UI subviews consume the presentation model instead of each independently
  recomputing priority state.

### Phase 2 — Build the fixed session header and Live Queue

1. Replace duplicated session facts with a compact `SessionHeaderView`.
2. Create `LiveQueueView` with explicit `Waiting`, `Hands`, and `Assist`
   sections.
3. Implement priority and visibility rules exactly as documented above.
4. Reuse existing actions for admit-all, lower-all, select hand, card open/send/
   dismiss; do not duplicate SDK behavior.
5. Ensure the queue has a fixed width and internal scrolling only when its own
   content exceeds the available height.

Acceptance:

- A new waiting-room entry appears without shifting grid width.
- Hands are always shown in raise order.
- Cues content never displaces waiting-room or hand actions.
- The top-bar counts and Live Queue do not duplicate long status copy.

### Phase 3 — Replace the rail with a PIP and inspector

1. Remove the self-video/control rail from the primary split layout.
2. Add a compact self-preview overlay, reusing the existing self-video host.
3. Replace the persistent context strip with `ParticipantInspectorView`.
4. Keep the selected tile visibly focused while its inspector is open.
5. Move global controls into header actions and `More` menu.

Acceptance:

- The participant grid receives at least 70% of width on a wide display.
- Self-preview does not alter grid cell calculation.
- No individual participant control is visible without a selected participant.
- All existing controls remain reachable, but low-frequency controls are no
  longer permanently visible.

### Phase 4 — Responsive and interaction polish

1. Implement wide and narrow layout modes.
2. Add keyboard handling: Escape closes inspector/queue drawer; shortcuts keep
   their existing behavior.
3. Animate only functional state changes.
4. Verify accessibility labels, focus order, and keyboard reachability for
   header, queue, inspector, menus, and paging.

Acceptance:

- Wide and laptop layouts retain all actions without clipping or a global
  vertical scroll region.
- A waiting person, raised hand, and selected participant can each be acted on
  in one obvious path.
- The layout does not reflow or resize horizontally when Cues cards arrive.

## Files likely to change

| Area | Likely files |
| --- | --- |
| Main participant-window composition and layout | `App/UI/ParticipantGridWindow.swift` |
| Cues presentation in the Live Queue | `App/Cues/CuesRailBlock.swift`, `App/Cues/CueCardView.swift` |
| Cues state binding | `App/Cues/CoordinatorController+Cues.swift` |
| Project design guidance | `DESIGN.md` |
| New extracted AppKit views | New focused files under `App/UI/ParticipantConsole/` if the existing file becomes too large |

## Verification scenarios

Verify each manually on both a wide reference display and a laptop-sized
window:

1. Empty meeting: grid is primary; no empty Live Queue filler.
2. One participant joins: grid remains visually dominant; PIP does not resize
   the grid.
3. Several people wait: waiting section becomes the top actionable queue.
4. Several hands rise in sequence: ordering is stable and `Next` chooses the
   earliest hand.
5. Select a participant: inspector appears with correct actions and closes
   cleanly.
6. Cues receives several cards: it stays contained, does not move critical
   sections, and cards remain actionable.
7. Resize to laptop width: the queue/inspector becomes a drawer; all critical
   actions remain reachable.
8. Record, mute all, chat, more-menu actions, and end-session confirmation all
   continue to work.

## Definition of done

- A teacher can identify who needs attention within one glance.
- The participant grid is visibly the main surface.
- The next likely action for waiting students and raised hands is obvious.
- No critical state or action requires scanning a long, mixed-purpose rail.
- Existing meeting-control behavior is preserved and the new layout has been
  verified in both wide and narrow window modes.
