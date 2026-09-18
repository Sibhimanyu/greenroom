# Design System - Greenroom

Source of truth for every visual decision on both surfaces: the GitHub Pages
site (`docs/`) and the macOS app (`App/UI/`). Created by codifying what already
ships, not by inventing a new look.

## Product Context

- **What this is:** A macOS app that sets up a whole screen-shared class in one
  click: virtual camera, Zoom meeting, and tiled windows.
- **Who it's for:** Teachers running a daily class over Zoom. Built for the
  morning reading class at Zoho Schools.
- **Space:** macOS utilities / teaching tools. Free and open source.
- **Project type:** Two surfaces. A marketing site plus a technical
  transparency page (`docs/`), and a native SwiftUI app (`App/`).

## Aesthetic Direction

- **Direction:** Technical Clarity. Industrial/utilitarian crossed with
  editorial. Diagrams carry the argument and prose acts as captions.
- **Decoration level:** Minimal. No gradients, no texture, no ornament. The
  visual interest comes from diagrams and semantic colour.
- **Mood:** Precise and verifiable. The product asks for camera, microphone and
  system-wide window control, so every surface has to read as trustworthy
  rather than promotional.
- **Diagram grammar (load-bearing, keep consistent):**
  - Solid stroke = a process. Dashed stroke = data at rest or configuration.
  - Green arrow = stays on the machine. Amber arrow = crosses to the internet.
  - Thick stroke = a continuous stream. Thin stroke = a one-shot message.

## Typography

Two voices, on purpose. Prose is the human speaking, mono is the machine.

- **Display / Body / UI:** System stack.
  `-apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, Helvetica, Arial, sans-serif`
  Rationale: this is a Mac utility. SF on the site makes the site feel native to
  the platform the product ships on. This is a deliberate platform choice, not a
  default. Do not swap it for a webfont without revisiting that reasoning.
- **Mono (machine facts):** `ui-monospace, "SF Mono", Menlo, monospace`
  Use for: endpoints, file paths, API names, entitlements, ports, shortcuts,
  version strings. Anything the reader could paste into a terminal or verify.
  Never use mono for ordinary prose.
- **Section eyebrows:** mono, uppercase, letter-spacing `.08em`, 10-13.5px, in
  `--brand-green`. Format `01 · The whole system`. This is the closest thing the
  brand has to a typographic signature.
- **Scale (canonical; `docs/index.html` still uses a larger h2 and needs
  aligning):**

  | Role | Size | Weight | Tracking | Line height |
  |------|------|--------|----------|-------------|
  | h1 | `clamp(30px, 4.6vw, 46px)` | 800 | -0.025em | 1.1 |
  | h2 | `clamp(24px, 3.2vw, 32px)` | 800 | -0.02em | 1.15 |
  | h3 | 15.5-17px | 700 | 0 | 1.3 |
  | lede | 17.5px | 400 | 0 | 1.6 |
  | body | 16px | 400 | 0 | 1.6 |
  | caption | 14.5px | 400 | 0 | 1.5 |
  | micro | 12.5-13.5px | 500-700 | 0 | 1.4 |

## Color

**Approach:** Restrained and semantic. Colour is never decorative here. It
encodes where data goes, which is the entire argument of the transparency page.

### Brand greens (two roles, both anchored in `logo-mark.png`)

The logo uses a deep green plus a lime highlight. That pair is the system.
Before this document there were four unrelated greens across site and app.

| Token | Hex | Contrast on white | Role |
|-------|-----|-------------------|------|
| `--brand-deep` | `#00401C` | 12.00 | Logo structural green. Darkest step, link hover, high-emphasis marks. |
| `--brand-green` | `#2F6118` | 7.38 | Primary interactive: links, buttons, kickers, eyebrows, diagram "local" strokes. |
| `--accent-lime` | `#78C000` | 2.25 | Logo highlight. Fills, tints, shapes, macOS `AccentColor`. **Never text.** |

**Hard rule:** `--accent-lime` fails AA at every text size (2.25). It is a fill
colour only. Any green text or green icon-with-label uses `--brand-green`.

Retired: `#3D7A22` (site) and `#5FA83C` (app `AccentColor`). Neither appeared in
the logo.

### Semantic

| Token | Hex | Contrast | Meaning and limits |
|-------|-----|----------|--------------------|
| `--net` | `#B9770E` | 3.68 | "Leaves your Mac." Graphics and text at 14px+ semibold only. |
| `--net-text` | `#96600A` | 5.28 | Same meaning, for small labels. Use this for any amber text under 14px, including SVG diagram labels. |
| `--danger` | `#B42318` | 5.94 | Reserved for the "what it never does" claims. Not for ordinary errors on the site. |

**Known issue to fix:** the SVG diagram labels in
`docs/how-it-works.html` set 9.5-11px text in `--net` (3.68). Those should move
to `--net-text`.

### Neutrals (cool grey, unchanged)

| Token | Hex | Use |
|-------|-----|-----|
| `--ink` | `#101828` | Headings, primary text |
| `--body` | `#475467` | Body copy, captions |
| `--faint` | `#98A2B3` | Labels, meta, dimension marks |
| `--line` | `#EAECF0` | Borders, rules, hairlines |
| `--bg-soft` | `#F9FAFB` | Alternating section bands |
| surface | `#FFFFFF` | Cards, diagram frames, page |

**Dark mode:** not implemented on the site and not planned. The app inherits
macOS appearance through system colours. If the site ever gains dark mode,
redesign the surfaces rather than inverting, and drop `--accent-lime`
saturation 10-15%.

## Spacing

- **Base unit:** 4px.
- **Density:** comfortable on the site, compact inside the app.
- **Scale:** `4 · 8 · 12 · 16 · 20 · 24 · 32 · 48 · 64`
- **Section rhythm:** 56px vertical padding, 64px for the hero.
- **Current drift:** gaps of 6, 7, 10, 11, 18, 22 and 26px are in use. Round to
  the nearest scale step when touching that code.

## Layout

- **Approach:** Hybrid. Grid-disciplined text columns; diagrams allowed to break
  out into their own scrollable frame.
- **Max content width:** 1120px (`.wrap`), 760px for reading columns
  (`.narrow`), 940px for tables and appendices.
- **Diagram frames:** 1px `--line` border, `border-radius: 14px`, 18-20px
  padding, `overflow-x: auto`, and a `min-width` on the SVG so it scrolls
  instead of squashing on narrow screens.
- **Border radius (canonical; 11 distinct values are currently in use):**

  | Token | Value | Use |
  |-------|-------|-----|
  | `sm` | 6px | Inline code, small tags, mono chips |
  | `md` | 10px | Buttons, inputs, small cards, diagram boxes |
  | `lg` | 14px | Panels, diagram frames, feature cards |
  | `pill` | 999px | Eyebrows, chips, status badges |

### Panel composition (app)

Applies to any app panel that pairs a piece of media with its controls. The
participant rail is the one that exists today; anything similar follows it.

- **Controls sit below the media, never beside it.** One shape at every width.
  A panel that rearranges itself past a width threshold reads as a panel that
  ran out of ideas, and the wide case is usually the one the user meets first.
- **One content column, shared by everything in the panel.** Picture, caption,
  meter and control grid align to the same left and right edges. A control grid
  that stops short of the media above it is the loudest single tell that a
  layout was not composed.
- **Cap the column at the content's natural size, then centre it.** Measure the
  cap in controls, not points: at most seven 76pt cells across, snapped down to
  a whole number of cells so the last cell in a row lands exactly on the media's
  right edge.
- **Size the column for the media, not for the controls.** The media is the
  primary content, so a cap chosen to make the button grid comfortable makes the
  media pay for that comfort. Pick the cap where the *media* stops improving,
  then check the control grid still reads at that width. Check the group sizes
  too: a cap one cell under a group's size costs a whole extra row.
- **Fit the column to height as well as width.** A column sized on width alone
  makes the media as large as the panel is wide, which pushes whatever sits
  below the controls off the bottom on a short window. Take the widest column
  whose *whole* stack fits the panel height. When nothing fits, take the size
  that overflows least — not the narrowest, since narrower means more wrapped
  rows and a taller control column.
- **Surplus width becomes symmetric margin, not stretched content.** Centring is
  what makes leftover space read as margin instead of as content that failed to
  fill its container.
- **Size the container from the content, not from a fraction of the screen.** A
  fraction is the right way to describe a panel only while its contents stretch
  to fill whatever they are handed. Once the content is capped, a fraction just
  buys margin, and the number goes stale the moment the content changes. Derive
  the panel's ceiling from its widest content plus margin; keep the fraction, if
  at all, only to shrink the panel when something else needs the room.
- **Panels scroll rather than shrink.** When the stack does not fit, scroll it.
  Do not claw height back by clamping the media to a fraction of the panel
  height: that back-solves a media width that no longer matches the controls.
- **In a control grid only two vertical gaps are decisions:** the break above a
  section eyebrow (20px) and the breath below it before its first row (8px).
  Every other gap is the cell grid itself (4px). A gap that is none of those
  three is a bug, not a choice, however deliberate it looks on screen.
- **Measure and place in one pass.** A panel that reports its own height to a
  scroll view must run the identical arithmetic for both. Two copies drift, and
  the failure is quiet in the worst way: if both copies share a bug the heights
  agree, so nothing looks broken to the scroll view while the panel on screen
  falls apart.

Reference: `App/UI/ParticipantGridWindow.swift`, `railColumn(available:)` and
`layoutRail()`.

## Motion

- **Approach:** Minimal-functional. Motion clarifies state; it never decorates.
- **Duration:** 150-250ms for hover and state changes. 250ms for layout moves
  (`snappy(0.25)` in SwiftUI).
- **Easing:** ease-out entering, ease-in leaving, ease-in-out for movement.
- **Allowed:** button hover lift (`translateY(-1px)`), arrow nudge on link
  hover, chat scroll-to-latest, shape-preview crossfade, the readiness bar
  easing to a new width (250ms, ease-out) and the platform spinner on the one
  active step.
- **Not allowed:** scroll-driven animation, parallax, entrance choreography.

### Waiting states

- **Name the step, never just spin.** A bare spinner says "wait" and nothing
  more, so a start stuck on OBS looks exactly like one about to finish. The
  wait costs the same either way; spend it saying what is happening and roughly
  how much is left. A determinate list of named steps plus a progress bar is
  the pattern; the platform spinner marks the single active step.
- **Fill in progressively.** Where the pieces come up at different times, show
  each one the moment it is real rather than holding everything back for a
  single reveal. Greenroom's virtual camera is live seconds before the meeting
  connects, so the self view appears seconds before the roster does.
- **A control that is not ready says so.** Dim and disable it rather than
  hiding it: the teacher can see what is coming, and nothing looks live while
  silently doing nothing.
- **A failure belongs on the surface the user was already watching**, named
  against the step it happened on — not in a log on another display.
- **Pick the carrier by what the display can spare, and only ever one.** A
  surface that owns a whole screen can hold the full waiting state. A surface
  sharing one screen with the workspace cannot: it is either off, or it is an
  ordinary window about to be buried by the layout pass it is reporting on.
  There, use a small floating card instead — above the layout, too small to
  fight it, gone when it has nothing left to say. Never show both; two accounts
  of one wait is one too many.
- **Centre a transient progress card, do not tuck it in a corner.** A corner
  looks like the polite choice and is not: the workspace tiles a side column
  flush to the bottom and, by default, the right edge, so bottom-right lands on
  it. Centre favours no tiled pane over another, and nothing on that display is
  usable during those seconds anyway.
- **A progress surface may assert itself; a control surface may not.**

### Affordances

- **An interaction belongs to the setting, not to one way of drawing it.** Where
  a control has two representations — a schematic and a live preview, an empty
  state and a loaded one — the affordance goes on a layer both wear. Build it
  into one of them and it disappears when the other takes over, usually the
  richer one, because the richer one wins by default.
- **If a caption says "drag this", something on screen must be draggable in
  every state that caption is visible.** An instruction that outlives its
  control is worse than no instruction: the user concludes the app is broken,
  and they are right.
- **Never nest an interactive layer inside content that refreshes on a timer.**
  A live preview that republishes its image rebuilds everything under it, taking
  the `@State` and any in-flight gesture with it. At Greenroom's 150ms preview
  poll that capped a drag at about seven frames, so it read as a control that
  did nothing at all. Put the interaction alongside the picture as a sibling,
  where its identity survives the refresh, and give it the picture's rect rather
  than living inside it.
- **Focus goes under the controls, not around them.** `.focusable()` takes focus
  on click, and on a container that is the same click a drag needs. Put it on a
  layer beneath: clicking bare canvas arms the keyboard, clicking the control
  works it, and the gesture sets focus itself so keys are live straight after.
- **Attach a gesture before `.position`, not after.** `.position` wraps a view
  in a container that fills its parent, so a gesture added afterwards responds
  across the whole canvas rather than on the thing being dragged. Pair it with
  an explicit `contentShape` so the hit area is the control, no more and no
  less. Ordering
  a control panel to the front on a timer is a tug-of-war with the person using
  the Mac. A small, non-interactive card that leaves on its own is not, and
  staying above a tiling pass is the whole reason it exists.

## macOS App Mapping

The app is the other half of this system. Keep it aligned.

- **Accent:** `App/Assets.xcassets/AccentColor.colorset` holds the single source
  for the app tint. Set it to `--accent-lime` `#78C000` and reference it only
  through `Brand.green` (`App/GreenroomApp.swift`).
- **Never hardcode brand colour in Swift.** Two constants currently duplicate a
  raw RGB value: `ContentView.brandGreen` and `SettingsView.personGreen`. The
  first should use `Brand.green`. The second is a different thing wearing the
  same number: it represents a chroma-key green screen, so name and keep it
  separately as `chromaGreen`, not as brand.
- **Semantic colour applies here too:** anything that reaches the network reads
  amber, anything local reads green. This is the risk we deliberately took, so
  honour it in status text and indicators.
- **System colours for chrome:** keep `Color(nsColor: .controlBackgroundColor)`
  and friends for surfaces so the app tracks macOS appearance.
- **Type:** system font throughout. Mono (`.system(.body, design: .monospaced)`)
  for the same machine-fact content as the site.

## Open drift to fix

Ranked by user-visible impact. None of these block anything today.

1. App accent `#5FA83C` is retired in favour of the logo pair. Update the
   colorset and `ContentView.brandGreen`. **Partly done 2026-09-18:** `Brand`
   now carries `text` (`--brand-green` #2F6118, dynamic - the lime in dark
   mode, where it passes) and `fill` (`--accent-lime` #78C000), and Screenroom
   uses them. The colorset itself is still `#5FA83C`; changing it re-tints
   every control in the app and wants its own pass. (Site side done 2026-09-03: every
   page's `--green` is `#2F6118`, `--green-hover` is `#00401C`, and the
   how-it-works diagram strokes no longer hardcode `#3D7A22`.)
2. Amber diagram labels under 14px move from `--net` to `--net-text` (they
   currently fail AA body contrast).
3. `docs/index.html` h2 scale differs from `docs/how-it-works.html`. Adopt the
   canonical scale above.
4. Border radii collapse to the four tokens.
5. Off-scale gaps round to the 4px scale.
6. `docs/index.html` brand logo links to `href="#"`. Point it at `index.html`.

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-08-18 | Codified the shipped system instead of proposing a new one | Two live pages and a shipped app already share a coherent language. A rebrand would orphan all three with no budget to redo them. |
| 2026-08-18 | Brand greens become a two-role pair from the logo | Four unrelated greens existed across site, app and logo. The logo already pairs a deep green with a lime highlight, and splitting by role also fixes link contrast. |
| 2026-08-18 | `--accent-lime` barred from text | Measured 2.25 contrast on white, failing AA at every size. Safe as a fill and as the macOS tint. |
| 2026-08-18 | Added `--net-text` `#96600A` | The existing amber measures 3.68 and is used for 9.5-11px diagram labels. This is the nearest value that passes AA body text. |
| 2026-08-18 | Kept the system font stack | This is a Mac utility, so SF on the site reads as platform-native rather than as a skipped typography decision. Revisit only if the product moves beyond macOS. |
| 2026-08-23 | The participant panel opens on the first frame of a start, showing named steps | The reference display was blank from Start until the meeting connected — several seconds of OBS, virtual camera, meeting creation and SDK auth. Every step already wrote a line to `statusLines`, but that log is collapsed by default in a window on another display, so the work was visible to the app and not to the person waiting. Named steps rather than a spinner because a start that hangs should hang visibly, on a step you can point at. |
| 2026-08-23 | A panel never ends in dead space: the rail's tail carries a priority block | The bottom of the rail was 126pt of nothing. Rather than grow the picture into it, the space now shows whatever most needs the teacher — people waiting, then hands up in raise order, then the session card. Strict priority because only one thing can be most urgent, and never blank because a block that empties out has moved the hole rather than filled it. |
| 2026-08-23 | Self view sized for the media, capped at seven cells and fitted to height | Five-across was chosen for the button grid, so the picture paid for the buttons' comfort, and 60pt margins bought nothing once the column was capped. Seven cells with 24pt margins nearly doubles the picture area for an 88pt wider rail, and it clears Zoom's six-button group in one row where five forced a wrap. Height now bounds it too, so the priority block stays above the fold. |
| 2026-08-23 | Rail width derives from its content, not from a fraction of the display | Once the column was capped, the old 0.62 empty-room fraction only bought margin: a 926pt rail wrapping a 396pt column in 265pt of nothing each side, on the screen a teacher opens into before every class. The ceiling is now the widest column plus margin (540pt); the fractions survive only to shrink the rail as the class fills. |
| 2026-08-23 | Participant rail is one stacked, capped, centred column at every width | The rail had a second shape above 672pt that put the controls beside the self view. That width is the empty room, so it was the first thing a teacher saw every single class. Stacking alone was not enough: a bare stack at 1190pt drew a 669pt slab of video with the buttons wrapping fourteen across, so the stack needed a column capped in cells and centred. |
| 2026-08-18 | Promoted mono to an identity role in section eyebrows | Gives the brand a typographic signature without abandoning the platform font, and reinforces the technical-honesty posture of the transparency page. |
| 2026-08-24 | The participant view exists whether or not a second display does | With Zoom's own UI on a single screen it opened nothing at all, because the toggle conflated two questions: whether the gallery WINDOW exists (Zoom's dual-screen mode) and which DISPLAY it goes to. The window is worth having either way, so it now opens behind the workspace and stays one Mission Control away, instead of being withheld for lack of somewhere pretty to put it. |
| 2026-08-24 | Full screen on the reference display means covering the menu bar and Dock, not a Space | Both participant views already filled the display's bounds, but at `.normal` level the menu bar and Dock still drew on top, so it read as not-quite-full-screen. Raised to `.statusBar` rather than calling `toggleFullScreen`: a window in a Space cannot be re-framed, which is the exact reason the Zoom-UI placer has to eject its gallery from fullscreen every time it finds it there. |
| 2026-08-24 | A background window is pushed back only when it surfaces unfocused | The SDK raises its own windows on state changes, so one `orderBack` does not hold. Re-asserting every tick would fight a teacher who deliberately opened the roster, so the correction is limited to the case that is unambiguously not them: frontmost, but never focused. |
| 2026-08-24 | No pop-out window for the live speaker; ⌥⌘Z toggles featured layout instead | Zoom's custom-UI capability matrix is explicit — "Multiple windows: No (regions in 1 container)"; SDK-rendered video cannot leave the container's window, and the re-parenting experiment drew black in a visible, correctly sized window. A pop-out would need the raw-data pipeline, which is a separate feature, not a layout choice. |
| 2026-08-24 | The full-display participant panel runs at normal window level (supersedes the .statusBar cover) | Covering the menu bar and Dock also covered every other window on that display — the reference monitor became single-purpose, reported live. Filling the display at normal level keeps it usable; the menu bar over the top sliver is the accepted price. |
| 2026-09-03 | The transparency page names the built-in browser's traffic as its own channels, not as "the main app's" | Greenroom Browser moves page loads into Greenroom's process, and the search-suggestion switch sends keystrokes to Google. Both are new facts about what leaves the Mac; the page's whole argument is that the list is complete, so they get their own cards, the system map gets a fourth amber link, and the hero says which two things leave without being asked. |
| 2026-09-04 | The main window grows only downward from an anchored top edge; the status log is hidden by default behind one toggle, Manual controls a pull-down | Two disclosures resized the window, and AppKit keeps the bottom-left corner on a content-size change, so every expansion sent the window climbing the screen while the rows above reflowed. Now the frame is set with the top edge held: the controls stay under the cursor and only the bottom edge travels, animated. The log stays closed by default (the teacher's call: it is diagnostic detail) but its line count sits on the toggle so "something happened" is visible without opening it. Three manual buttons used a few times a term become a menu that opens over the content instead of pushing it. |
| 2026-09-04 | Settings tabs share one grammar: grouped form, title + one-line subtitle left, control right | Layout used the grouped form while the other tabs used the column form with paragraph captions, so the tabs zigzagged and read as walls of text. A switch earns one sentence; the paragraphs live on the Guide and Privacy pages. |
| 2026-09-04 | The class transcript is saved into the class folder, and every "never written" claim was rewritten to match | Asked for directly: the teacher wants the record of what was said, beside the recording. The old promise ("the text stays in memory", "never written") appeared in the privacy page, the pipeline diagram, the capability table, the settings copy and two log lines, so all of them changed in the same commit rather than leaving the docs asserting something untrue. The claim that survives, and is still true, is the one that matters: the audio and the transcript never leave the Mac. Written per sentence as it lands, so a crash keeps what was said, and a switch turns it off. |
| 2026-09-04 | Cues ships with word patterns, not the model, and the model is a labelled opt-in | Both were scored against a recorded 45-minute class. Word patterns: 16 lookups, 90% recall, 56% precision. Apple's on-device model: 100% recall but 264 lookups and ~254 wrong cards at 3% precision, and no filter fixed it - confidence is uniformly 1.0 for right and wrong alike, and every phrase-shape filter tried moved precision by 2-3 points. A wrong card is an interruption on the reference display mid-lesson, so the precise detector is the default and the model is a switch that says plainly it finds more and interrupts more. |
| 2026-09-04 | A named product's own homepage is a card, fetched by guessing the domain and checking the title | The recording showed the teacher searching a product and opening its site within seconds; no free API returns an official website (Google Custom Search shuts down 2027, Brave dropped its free tier, DuckDuckGo only echoes Wikipedia). Guessing the domain from the name and verifying it is the honest version: it visits the product's own page, the same one the teacher would, never a search engine, and reads only as far as the title. A parked domain fails the title check. |
| 2026-09-04 | "No AI" becomes "No cloud AI" across the transparency page | Cues runs Apple's speech and language models on the Mac, so the old chip and the "orchestrator (no AI)" label would have been false the day it shipped. The claim that survives, and is drawn, is where the models run and what crosses: the microphone stream into Greenroom is a thick green line because it never leaves; the lookups are a thin amber line because a few words do. Off by default, and the page says so at every mention. |
| 2026-09-04 | Cues's cards are a rail block under the needs block, and a menu-bar popover otherwise | The reference display is the teacher-only surface the panel already owns, and the rail's discipline (fixed pool, in-place updates, one measuring/placing walk) is exactly what a poll-driven card list needs. With no panel, an AppKit status item and popover because a SwiftUI menu-bar extra with a window style activates the app, and a card must never pull Greenroom in front of the page being read. Exactly one waveform in the menu bar at a time: on GR while the rail is the surface, on its own item otherwise. |
| 2026-09-18 | Screenroom takes its picture from a local camera, not from the meeting | The Meeting SDK renders into one container and its video cannot leave that container's window (see 2026-08-24), so an evaluator's view of a remote student can only be built inside the participants panel and can only be tested by running a real class with a real second person in it. A local camera opens with no session, no OBS and no credentials, so the note box — which the plan calls the binding constraint — can actually be worked on. It is also the in-room case, which is half the product. |
| 2026-09-18 | A Screenroom note is stamped from its first keystroke, not from Return | The moment worth marking is the moment the evaluator noticed something, and that is when their hands moved. Everything after is them finding the words. A long note is exactly the kind worth writing, so stamping on Return would push the most considered notes the furthest from the thing they describe — fifteen seconds of typing is fifteen seconds of drift on the note that mattered most. |
| 2026-09-18 | The Screenroom window borrows the Classroom Console's shape: media primary, a fixed 320pt column beside it | Two windows in one app should not disagree about what a side column is. The console settled on 320pt fixed precisely so arriving content cannot move the thing being watched, and a note list grows constantly — it is the same problem Cues cards posed to the rail. The composer sits at the foot of the notes column rather than under the picture, because a note is written into the run of notes. |
| 2026-09-18 | Screenroom' second pass reads the notes, not the video, and runs on-device | The plan costed a video pass and a notes pass; the notes pass is a few hundred words of text where the video pass is a batch job with a bill. It is also the one with the higher ceiling, because the notes hold the thing no footage analysis recovers — a human in the room deciding what mattered. On-device through the same FoundationModels framework Cues uses, so there is no key, no bill, and nothing about a student's performance leaves the Mac. |
| 2026-09-18 | When Apple Intelligence is unavailable the pass still runs, and says which engine wrote it | Apple Intelligence is off on most Macs and absent from all of them before macOS 26, so a report that failed there would make the feature conditional on a setting the teacher may not control. The counted engine claims nothing it cannot show — how many notes, across how long, where the longest silence was. An analysis written by a model and one counted from timestamps are different kinds of claim, so the file records which it was and report.md prints it. |
| 2026-09-18 | Cohort consistency is arithmetic and is kept away from the model | It is the one output whose entire purpose is to be shown to a student arguing about a grade. A model asked "were these marked consistently?" answers confidently either way and cannot show its working. Means, spreads and one correlation can. |
| 2026-09-18 | The speaker's report and the marker's report are different documents | The cohort findings are about the marker, not the student: "marks drifted downward through the session" is a fact about an afternoon, and putting it in the student's copy invites an argument about somebody else's grade. The teacher's copy carries them, because when a grade is questioned the person answering should already have looked. |
| 2026-09-18 | A remote presenter is captured from the window they appear in, not from the meeting SDK | The SDK renders into one container and the video cannot leave that container's window (2026-08-24), and a second container is ruled out by the capability matrix, so Screenroom cannot ask it for a student's video. Pointing at the window works with the participants panel, the native Zoom app, Meet in a browser and a recording being played back — and unlike anything through the SDK it can be tested with no meeting and no second person. System audio, not the microphone: a window on screen is heard through the machine playing it. |
| 2026-09-18 | Screenroom' second evaluator arrives as a file, not a connection | Notes are already files, so a second evaluator is a second notes.jsonl and merging is a union by id. A transport buys a server, a pairing flow, a mid-presentation failure mode and an answer to "what if the TA's laptop sleeps", all to save an email. It can be added under the same merge later without changing anything above it. |
| 2026-09-18 | The speaker-facing note view is opt-in per presentation and is never remembered | Live notes make it coaching; notes afterwards make it evaluation. A stored preference would mean a teacher who once coached a rehearsal is silently still coaching in an exam three weeks later, and the student would be the one to find out. Screenroom opens as an evaluation tool every launch. |
| 2026-09-18 | Greenroom's "no screen-capture code" claim was rewritten the moment it stopped being true | The transparency page's whole argument is that its list is complete, and it said in as many words that Greenroom contains no screen-capture code. Screenroom' screen engine made that false. README, guide and the page were corrected in the same commit: the code exists, the feature is held back, macOS never asks in this release, and when Screenroom ships this becomes a fourth permission. Same rule as the 2026-09-04 transcript rewrite. |
| 2026-09-18 | Screenroom exports the presentation with the notes drawn into it, and a subtitle file beside it | A document the student reads separately makes them cross-reference a scrubber against a page. Watching yourself lose the thread while the sentence appears is the same information with the work taken out. Two forms because they are good at different things: burned in is one file that plays anywhere and cannot lose its notes but costs a re-encode; a .srt is instant, lossless, toggleable and taken by YouTube, but is a second file a student may never open. A card leads its note by two seconds, because a note is stamped at its first keystroke and the moment is already under way. |
| 2026-09-18 | Screenroom hands presentations to the agent you already run, rather than adding an API key | A teacher paying for Claude Code or Codex already has a large model and a shell; Greenroom asking for a second key to reach a worse one is a tax on both of us. So there is no account, no key and no model setting: Screenroom writes a brief and runs your command in your login shell. The cost is that this is the only feature whose destination Greenroom cannot describe, which is said plainly in the window, the README, the guide and the transparency page rather than buried. Off by default. |
| 2026-09-18 | The agent is given stills and a transcript, and is told in the brief what it therefore cannot judge | No coding agent watches an .mov, so one handed a video file answers confidently about a file it never opened. Stills every twenty seconds support posture, reading off a screen and what is on the slide; they do not support gesture, pace or eye contact, and the brief says so outright. A confident sentence about something unobserved is worse than no sentence, because the teacher reads it to a student. |
| 2026-09-18 | Screenroom refuses to transcribe rather than let SFSpeechRecognizer fall back to Apple's servers | The API returns results either way and says nothing about which happened, so a missing on-device model would quietly send a recording of a named student off the Mac. supportsOnDeviceRecognition is checked first and the Mac is told why it cannot. |
| 2026-09-18 | Screenroom transcribes with whisper, not with Apple's recogniser | Apple's is built for dictation and smooths disfluencies away before returning the text, which is correct there and fatal here: ScreenroomSpeechMetrics exists to count exactly the words it removes, so a filler count taken from it measures how well Apple deleted the evidence and reads as a confident zero beside a student's name. Measured on identical audio: whisper kept every "um", "uh", "like" and "you know", each with a millisecond offset. Apple's stays as a fallback for a Mac without whisper, with the filler count switched off and a sentence saying why. |
| 2026-09-18 | speech.json records which engine transcribed it, and fillerCount returns zero when it was not verbatim | A number that cannot be trusted and does not say so is worse than no number. The guard is on the count itself rather than on each reader remembering to check, because the readers are a report, a window and a brief handed to somebody else's model. |
| 2026-09-18 | Marks is renamed Screenroom | Two reasons, neither of them taste. "Marks" already meant something else in this app — ⌥⌘1/2/5 marks the last few minutes as a clip, and the Sessions window says "Marks appear here afterwards" — so one word covered two unrelated things. And it named the smallest part of the feature: the scores are one tab, while the notes, recording, transcript, clips, report and agent pass are the rest. Screenroom is the room where a recorded performance is watched back and assessed, it is one word of the same shape as the app it lives in, and the pairing states the whole product: Greenroom is where you wait before, Screenroom is where you watch it back. |
| 2026-09-18 | Screenroom drops per-note clip cutting and multi-evaluator note import | Both were built, verified, and cut the same day. Clip-per-note predated the annotated video export and was redundant once it existed: a student watching presentation-with-notes.mp4 sees every note in place without opening twenty files. Import answered a case nobody had raised, and without a transport it amounted to "have your TA email you a file" — while being the only door to two hundred lines of agreement analysis that could otherwise never run. The shared lesson: each was a reasonable idea, implemented well, and of no use to the person the tool is for. The question that catches this is not "is this good" but "who asked". |
| 2026-09-18 | The report gets its own window, and every chart in it is one series | It was living in the 320pt notes column, where the summary wrapped to nine lines and the speech figures were four sentences carrying numbers a chart answers at a glance. One series throughout is not a limitation, it is the subject: this is one student's presentation, so a categorical palette would be colouring rows by their position in a list. One series means one hue, no legend (the heading names it), and grey for everything that is context. Nothing needs a colourblind pass because nothing asks a reader to tell two colours apart. |
| 2026-09-18 | Three things in the report are deliberately not charts | The four headline numbers are stat tiles, because a one-bar bar chart is the classic way to turn a number into a worse number. A rubric line is a ratio against a limit, so it is a meter, not a bar on a shared axis — five maxima on one axis compares things that are not comparable. The notes are marks on a time axis: they have position, not magnitude. |
| 2026-09-18 | No amber in the report, even for "worth checking" | Amber means "leaves your Mac" in this app and red is reserved for the "what it never does" claims, so neither is available as a warning colour. The consistency findings carry an icon and a label instead — which is what a status mark is supposed to do anyway, since colour alone never encodes state. |
| 2026-09-18 | Export asks where the file goes | Writing report.md into the presentation's folder is right for a file the app owns and wrong for a document about to be sent to a student: it lands somewhere they did not choose under a name they did not pick. PDF is rendered from the dashboard itself rather than laid out a second time — a second layout is a second thing to keep in step, and the point of the PDF is that it is what is on screen. |
| 2026-09-18 | Screenroom's analysis becomes one button; setup moves to Settings | It had grown six controls for one outcome — transcriber, prepare, agent on/off, which agent, its command, and a separate read-the-notes — which are six ways of asking "make me a report". None of them is a decision a teacher makes per student; they are decisions about the Mac, made once. Setup is a setting, running is a button. The transcriber stops being a choice entirely: Apple's deletes the disfluencies the speech analysis exists to count, so nobody would choose it and offering the choice only invited somebody to get it wrong. |
| 2026-09-18 | The engine ladder is walked automatically and named in the report | Agent when one is set up, Apple's on-device model when not, arithmetic when neither. Every stage is best-effort and the next still runs, so a missing CLI costs the extra detail rather than the report — and because the report prints which engine wrote each part, a degraded run is visible rather than silent. |
| 2026-09-18 | Sessions and Past Presentations become one window | Two lists of ~/Documents/Greenroom is one too many, and the split was an accident of build order rather than a distinction a teacher would draw. It also left the analysis unreachable for what Greenroom mostly records: a class has a video, a microphone track and a teacher who was in the room — everything the analysis needs — and was invisible only because the library looked for notes.jsonl. The notes are what a presentation has EXTRA, not what makes a folder worth opening. Merged INTO Sessions, which already had the player, clips, YouTube links, delete and rename; porting those into the newer window would have risked shipped features to save writing one pane. |
| 2026-09-18 | Screenroom's tabs flatten into the Sessions tab bar instead of nesting | Reported from a screenshot: an "Analysis" tab that itself held a segmented control of Analysis / Notes / Rubric put two pickers one directly under the other with the same word in both, which reads as a bug rather than as a hierarchy. Five flat tabs is one decision instead of two and the word appears once. Measured at 352pt against a pane that is never narrower than 460, and sized to its own labels rather than to a number that goes stale when a tab is renamed. |
| 2026-09-18 | The detail pane has one left edge | The tab picker was centred while everything under it was leading-aligned, so the detail had three different left edges — picker, buttons, body — and no reason for any of them. |
| 2026-09-18 | An empty pane is centred, with its action in it | "Not analysed yet" plus a grey paragraph at the top of a thousand points of nothing reads as a page that failed to load. Centred, with the button that fills it, reads as a page waiting for you. Same shape for every empty state in the pane. |
| 2026-09-18 | The rubric stops being a form and becomes an output of the analysis | Five criteria and a row of buttons asked a teacher to do data entry for a judgement the same pass was already in a position to make, having read the notes, the transcript, the stills and the counted speech. Every mark now carries its reason next to the number, because a score with nothing behind it is an assertion rather than feedback — survivable while a teacher typed both and could remember their reasoning, not survivable when something else marks and the student asks why. rubric.json records markedBy: a mark from a model reading a transcript and one from a teacher who was in the room are different claims. |
| 2026-09-18 | The marking-drift finding is removed, because it can no longer be true | It existed for premise 3 — you grade twelve students on a Friday afternoon and your standards drift where you cannot see it. An engine marking each student in a separate run has no afternoon and no fatigue, so the order-effect correlation could only ever report noise. Deleted rather than left in. The plainer comparison survives: where this student sits against the group, and whether any single line is out of step. |
| 2026-09-18 | A step that cannot report progress gets a spinner, not a bar at zero | Reported from a screenshot: the agent stage held a determinate bar at 0% for two minutes, because an agent reports nothing until it answers. A bar that does not move is not a progress bar, it is a picture of a hang, and that is how it was read. Determinate where something can fill it, indeterminate where nothing can — and three things true either way: which step of how many, elapsed time, and the last complete line the tool printed. |
| 2026-09-18 | A running pass shows the tool's stderr, never its stdout | The waiting state was streaming the agent's stdout, which is the ANSWER — so the report's own sentences appeared a character at a time, truncated mid-word, presented as if they were progress. Progress goes to stderr in both whisper and the agent CLIs. The display also keeps whole lines rather than the last N characters, for the same reason. |
| 2026-09-18 | Stop kills the child process as well as cancelling the task | A cancelled Swift Task leaves the CLI running — whisper burning a core, an agent still spending tokens on an answer nobody will read — because a child process knows nothing about Swift concurrency. Verified: a cancelled Task leaves it alive, terminate() ends it, and the stderr reader finishes rather than hanging when it does. |
| 2026-09-18 | The agent step says what the agent is doing, read from its event stream | Everything before it takes seconds and it takes minutes, so a spinner and a step counter were barely better than the stuck bar they replaced. Both CLIs stream structured events on request; the window now shows "Reading transcript.txt", "Looking for frames/*.jpg", "Thinking… (turn 3)". The answer arrives inside the same stream, so stdout is read rather than displayed — which was the original problem. |
| 2026-09-18 | Notes can be added while watching the recording back | A class recorded through Start has none at all, and a presentation usually ends with fewer than intended, because typing while somebody is speaking is the hardest part of the job. A note added afterwards is stamped at the PLAYER's position rather than at the first keystroke: the live window corrects for the evaluator being behind the moment, but here the recording was scrubbed to the moment deliberately, so the playhead is already the answer. |
| 2026-09-03 | The timeline page uses one series and a step line, with releases as markers | The only honest quantity available for every release is the size of the code; a step line says "this is what shipped, until the next one shipped" rather than implying growth between releases. Single series, so brand green carries it and no legend is needed; three direct labels tell the story, the table carries the rest. The build that never launched is a hollow amber marker, never red: danger is reserved for the "what it never does" claims. |
