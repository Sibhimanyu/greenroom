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

1. App accent `#5FA83C` and site green `#3D7A22` are both retired in favour of
   the logo pair. Update the colorset, `ContentView.brandGreen`, and the site's
   `--green` tokens.
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
