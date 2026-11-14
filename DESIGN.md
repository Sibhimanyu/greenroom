# Design System - Greenroom

Source of truth for every visual decision on both surfaces: the GitHub Pages
site (`docs/`) and the macOS app (`App/UI/`). Created by codifying what already
ships, not by inventing a new look.

## Product Context

- **What this is:** A macOS app that sets up a whole screen-shared class in one
  click: the screen-and-camera picture, Zoom meeting, and the windows of the
  layout you chose.
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

## Logo

The mark (chosen 2026-09-24) is one heavy G whose right side is a person: a lime
square head over a body the width of the stroke, and one arm raised into the
counter. The full rules are in
`Branding/greenroom-mark/greenroom-brand-guidelines.ai`; the masters and every
export are in `Branding/greenroom-mark/`. Start from the master, never redraw.

- **Unit:** x, the G's stroke. The head is x square, the body x wide, the arm
  0.6x. Keep x of clear space on every side.
- **Colour:** deep `#00401C` for the structure, lime `#78C000` for the head.
  Reversed: white structure, lime head. One colour: all deep or all white. On a
  lime ground use the deep-only version.
- **Name:** always written in full as "Greenroom", in the bold system face, in
  one colour: `--brand-deep` on light, white on dark. Never lime, never
  two-tone, and the mark never stands in for the name's G.
- **Lockup:** the gap to the name is x and the name's capitals are 0.55 of the
  mark's height. The site header is a 26px mark, 19px name, 6px gap.
- **App icon:** the reversed mark on a deep tile (824 on 1024, r 185), mark 520
  wide. At 16 and 32px the mark is drawn 620 wide so the head and arm stay open.
- **Minimum size:** 24px tall on screen, 8mm in print. Smaller than that, use
  the small-size app icon.
- **Files:** lockups `Branding/greenroom-logo{,-dark}.{png,svg}`, mark
  `Branding/greenroom-mark.{png,svg}`, site `docs/logo-mark.png`,
  `docs/favicon.png`, `docs/apple-touch-icon.png`, app
  `Branding/greenroom-mark/Greenroom.icns`.

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
- **Controls are drawn the way Zoom draws them:** glyph on top, one short line
  of 11px caption under it, in Zoom's own words where Zoom has one ("Mute",
  "Stop Video", "React", "Host tools"). A cell is as wide as its caption plus
  10px each side, never under 60px, and a row is centred in the column rather
  than stretched across it. A count rides on the glyph, not in the caption.
  End is the last cell of Zoom's row, filled red.
- **In a control grid only two vertical gaps are decisions:** the break between
  one product's row and the next (8px) and the cell grid itself (4px). Groups
  are told apart by being separate rows, not by eyebrows over them. A gap that
  is neither is a bug, not a choice, however deliberate it looks on screen.
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
- **Page change (Home <-> Sessions):** the one choreographed motion, owner-approved
  2026-11-12. Old page fades out 120ms ease-in, the window resizes 250ms
  ease-in-out over both pages held at their final sizes, the new page fades in
  200ms ease-out and rises 6pt. Reduce Motion or full screen: instant resize,
  150ms crossfade.
- **Not allowed:** scroll-driven animation, parallax, entrance choreography.

### Waiting states

- **Name the step, never just spin.** A bare spinner says "wait" and nothing
  more, so a start stuck on one step looks exactly like one about to finish. The
  wait costs the same either way; spend it saying what is happening and roughly
  how much is left. A determinate list of named steps plus a progress bar is
  the pattern; the platform spinner marks the single active step.
- **Fill in progressively.** Where the pieces come up at different times, show
  each one the moment it is real rather than holding everything back for a
  single reveal. Greenroom's picture is live seconds before the meeting
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
  looks like the polite choice and is not: a layout may place a piece flush to
  any edge, and a starter puts the meeting and chat in the right-hand column, so
  bottom-right lands on one. Centre favours no placed piece over another, and
  nothing on that display is usable during those seconds anyway.
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
  for the app tint, `#5FA83C`, referenced only through `Brand.green`
  (`App/GreenroomApp.swift`). Not the logo's lime: as a control tint it lit up
  every button and field (decisions log, 2026-09-24).
- **Never hardcode brand colour in Swift.** `ContentView.brandGreen` still
  duplicates a raw RGB value and should use `Brand.green`. (Settings' old
  `personGreen` is split as of 2026-11-05: the drag layer's guides use
  `Brand.green`, and the sketch's green screen is `chromaGreen`, a different
  thing that happens to share the number.)
- **Amber tokens (app):** `Brand.net` (`--net`, glyphs and strokes) and
  `Brand.netText` (`--net-text` on light, `--net` on dark) in `App/GreenroomApp.swift`.
  Use them, never a raw value; three Settings tabs briefly carried their own copies.
- **Semantic colour applies here too:** anything that reaches the network reads
  amber, anything local reads green. This is the risk we deliberately took, so
  honour it in status text and indicators.
- **System colours for chrome:** keep `Color(nsColor: .controlBackgroundColor)`
  and friends for surfaces so the app tracks macOS appearance.
- **No painted window background:** Greenroom surfaces (Home, Sessions, a
  session, the report, Settings, Chat, the Record view) paint no background of
  their own. They show the window's own backdrop, which macOS tints from the
  wallpaper, so the title bar, tab bar and content always match. Never add
  `.background(Color(nsColor: .windowBackgroundColor))` over a page: an opaque
  fill loses the tint and shows as a flat grey. Forms, lists and scroll views
  keep `.scrollContentBackground(.hidden)` so their default fill stays off.
  A system sidebar or inspector draws its own material, and that counts as
  the window's backdrop, not a painted fill. Browse tiles (Sessions) are
  borderless and sit straight on the backdrop; choice tiles use `.quinary`
  at rest, and grouped-form boxes keep `controlBackgroundColor`.
  Exceptions: the meeting window's video stage (black behind video), the
  floating pills and banners, which use Glass (next rule), not a hand-picked
  material (control pill, toasts, upload prompt, banners), the notes bar pill and the Cues rail preview (both
  keep `windowBackgroundColor` as a self-contained shape), and the
  participants panel's `underPageBackground`.
- **Messages:** every message (toast, upload prompt, the "Getting ready" card)
  appears in one floating glass panel horizontally centred at the top of the
  screen the person is working on, 12pt below the menu bar (`visibleFrame`),
  stacked downward with 8pt gaps. Cards are compact: 340pt wide, 12pt padding,
  12pt radius, 20pt icon, `.callout` semibold title, `.subheadline` detail,
  `.small` buttons; the Getting ready steps are 17pt rows with 15pt glyphs.
  Never inside a Greenroom window, so a message can never cover a control.
  Non-activating, on all Spaces, above normal windows and below system alerts;
  drops in from a few points above and fades (fade only under Reduce Motion).
  Glyphs and buttons for anything that leaves this Mac (the upload) are amber
  (`Brand.net`). Frame math: `App/UI/BannerLayout.swift`.
- **Glass:** floating controls, HUDs, banners, toasts and pills (anything that
  floats over content) use `.greenroomGlass(in:interactive:)` from
  `App/UI/Glass.swift`: real Liquid Glass (`glassEffect`) on macOS 26, a
  regular material with a hairline before that. AppKit panels use
  `GreenroomGlassAppKit.makeBacking` (`NSGlassEffectView` on 26, the HUD
  visual-effect view before) on a non-opaque, clear-background window.
  We never apply glass to content (pages, cards, lists, docked bars). System
  sidebars, inspectors and toolbars draw their own; in-content control bars
  (the Record view, transport) may use `.greenroomGlassButton(prominent:)`.
  Never hand-pick a material (`.regularMaterial`, `NSVisualEffectView`
  and friends) for a floating control. Text on glass uses semantic styles
  (`.primary`, `.secondary`), never hardcoded greys, so vibrancy works.
- **Chrome is the system's:** navigation and window actions live in the window
  toolbar: Back (⌘[ / Esc), the page title as the subtitle
  (`.navigationSubtitle`, never `.navigationTitle` until the main window is
  found by identifier), search (`.searchable`), sort and filter menus, and
  page actions. Collections with filters use `NavigationSplitView` with a
  `.sidebar` List, `Section` headers and `.badge` counts; a page's secondary
  work goes in an `.inspector`. Never hand-draw a back button, search field,
  sidebar row, segmented tab bar or window toolbar. On macOS 26 the system
  gives these glass; we add none of our own.
- **Segmented switchers:** one shared `GreenroomSegmented`
  (`App/UI/Segmented.swift`); the selected segment is Brand green with a white
  semibold label; the selection slides (a `matchedGeometryEffect` spring on every macOS
  version; no glass inside the row, it blurred the labels); Reduce Motion crossfades; never a native tinted `Picker` that
  jumps, and never a hand-built second switcher. A row of picture choices is
  not a segmented control; it follows the tile rule below.
- **Cards and tiles:** one style (`App/UI/Tiles.swift`,
  `.greenroomTile(role:radius:)`), and every clickable tile has a hover lift.
  Browse grids (Sessions) have no lasting selection, only a keyboard focus
  ring. Choice tiles (Settings, onboarding) rest on `.quinary` and show
  "chosen" with a 2pt accent ring and a checkmark, never a green wash.
- **Type:** system font throughout. Mono (`.system(.body, design: .monospaced)`)
  for the same machine-fact content as the site.

### Settings density

Keep Settings visual without making each choice another two-row card. Put a
small illustration or glyph beside its name, with a minimum 40pt click target.
Keep labels at the normal system size. Group related controls in one section;
use hover help for explanations and disclosures for advanced tools. Summary
flows should be compact enough to leave the controls visible. The Webcam
preview starts at 224pt high and can expand to 360pt for fine adjustments;
its size and placement controls stay below it and share the canvas width.
Pair compact, related settings side by side when their labels and controls fit
comfortably: angle readout beside switching controls, upload behavior beside
visibility. Device selection belongs in a native dropdown rather than a grid of
cards. Keep device names, disconnected selections and refresh actions available.

## Open drift to fix

Ranked by user-visible impact. None of these block anything today.

1. App accent `#5FA83C` is retired in favour of the logo pair. Update the
   colorset and `ContentView.brandGreen`. **Partly done 2026-09-18:** `Brand`
   now carries `text` (`--brand-green` #2F6118, dynamic - the lime in dark
   mode, where it passes) and `fill` (`--accent-lime` #78C000), and Screenroom
   uses them. The colorset itself is still `#5FA83C`; changing it re-tints
   every control in the app and wants its own pass. (Site side done 2026-09-03: every
   page's `--green` is `#2F6118`, `--green-hover` is `#00401C`, and the
   how-it-works diagram strokes no longer hardcode `#3D7A22`.) Superseded
   2026-09-24: the app accent STAYS `#5FA83C` (see the decisions log). The new
   mark's app side is the app icon, `LogoMark` (with a dark variant) and a
   one-colour name in the window header.
2. The DMG background (`Branding/dmg-background.tiff`, drawn by
   `scripts/dmg-background.py`) still sets the retired two-tone lime name.
   Redraw it for the new mark before the next DMG.
3. Amber diagram labels under 14px move from `--net` to `--net-text` (they
   currently fail AA body contrast).
4. `docs/index.html` h2 scale differs from `docs/how-it-works.html`. Adopt the
   canonical scale above.
5. Border radii collapse to the four tokens.
6. Off-scale gaps round to the 4px scale.
7. `docs/index.html` brand logo links to `href="#"`. Point it at `index.html`.

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
| 2026-08-24 | No pop-out window for the live speaker; ⌥⌘Z toggles featured layout instead | Zoom's custom-UI capability matrix is explicit — "Multiple windows: No (regions in 1 container)"; SDK-rendered video cannot leave the container's window, and the re-parenting experiment drew black in a visible, correctly sized window. A pop-out would need the raw-data pipeline, which is a separate feature, not a layout choice. **Corrected 2026-11-11:** the premise was wrong. The speaker window rendered through the same container as the panel (one element's view in a second window; commit 028a189 shows it drawing), and the black screen of this date came from moving a view that was already rendering into another window, not from using a second one. Video can sit in more than one window: it is a design choice, not a rule of the SDK, though it leans on the deprecated `createVideoElement:` and Zoom does not document it. The speaker window itself is gone (see 2026-11-11, the meeting window), so the ⌥⌘Z outcome stands but for a different reason. |
| 2026-08-24 | The full-display participant panel runs at normal window level (supersedes the .statusBar cover) | Covering the menu bar and Dock also covered every other window on that display — the reference monitor became single-purpose, reported live. Filling the display at normal level keeps it usable; the menu bar over the top sliver is the accepted price. |
| 2026-09-03 | The transparency page names the built-in browser's traffic as its own channels, not as "the main app's" | Greenroom Browser moves page loads into Greenroom's process, and the search-suggestion switch sends keystrokes to Google. Both are new facts about what leaves the Mac; the page's whole argument is that the list is complete, so they get their own cards, the system map gets a fourth amber link, and the hero says which two things leave without being asked. |
| 2026-09-04 | The main window grows only downward from an anchored top edge; the status log is hidden by default behind one toggle, Manual controls a pull-down | Two disclosures resized the window, and AppKit keeps the bottom-left corner on a content-size change, so every expansion sent the window climbing the screen while the rows above reflowed. Now the frame is set with the top edge held: the controls stay under the cursor and only the bottom edge travels, animated. The log stays closed by default (the teacher's call: it is diagnostic detail) but its line count sits on the toggle so "something happened" is visible without opening it. Three manual buttons used a few times a term become a menu that opens over the content instead of pushing it. |
| 2026-09-04 | Settings tabs share one grammar: grouped form, title + one-line subtitle left, control right | Layout used the grouped form while the other tabs used the column form with paragraph captions, so the tabs zigzagged and read as walls of text. A switch earns one sentence; the paragraphs live on the Guide and Privacy pages. |
| 2026-09-04 | The class transcript is saved into the class folder, and every "never written" claim was rewritten to match | Asked for directly: the teacher wants the record of what was said, beside the recording. The old promise ("the text stays in memory", "never written") appeared in the privacy page, the pipeline diagram, the capability table, the settings copy and two log lines, so all of them changed in the same commit rather than leaving the docs asserting something untrue. The claim that survives, and is still true, is the one that matters: the audio and the transcript never leave the Mac. Written per sentence as it lands, so a crash keeps what was said, and a switch turns it off. |
| 2026-09-04 | Cues ships with word patterns, not the model, and the model is a labelled opt-in | Both were scored against a recorded 45-minute class. Word patterns: 16 lookups, 90% recall, 56% precision. Apple's on-device model: 100% recall but 264 lookups and ~254 wrong cards at 3% precision, and no filter fixed it - confidence is uniformly 1.0 for right and wrong alike, and every phrase-shape filter tried moved precision by 2-3 points. A wrong card is an interruption on the reference display mid-lesson, so the precise detector is the default and the model is a switch that says plainly it finds more and interrupts more. |
| 2026-09-04 | A named product's own homepage is a card, fetched by guessing the domain and checking the title | The recording showed the teacher searching a product and opening its site within seconds; no free API returns an official website (Google Custom Search shuts down 2027, Brave dropped its free tier, DuckDuckGo only echoes Wikipedia). Guessing the domain from the name and verifying it is the honest version: it visits the product's own page, the same one the teacher would, never a search engine, and reads only as far as the title. A parked domain fails the title check. |
| 2026-09-04 | "No AI" becomes "No cloud AI" across the transparency page | Cues runs Apple's speech and language models on the Mac, so the old chip and the "orchestrator (no AI)" label would have been false the day it shipped. The claim that survives, and is drawn, is where the models run and what crosses: the microphone stream into Greenroom is a thick green line because it never leaves; the lookups are a thin amber line because a few words do. Off by default, and the page says so at every mention. |
| 2026-09-04 | Cues's cards are a rail block under the needs block, and a menu-bar popover otherwise | The reference display is the teacher-only surface the panel already owns, and the rail's discipline (fixed pool, in-place updates, one measuring/placing walk) is exactly what a poll-driven card list needs. With no panel, an AppKit status item and popover because a SwiftUI menu-bar extra with a window style activates the app, and a card must never pull Greenroom in front of the page being read. Exactly one waveform in the menu bar at a time: on GR while the rail is the surface, on its own item otherwise. |
| 2026-09-18 | Screenroom takes its picture from a local camera, not from the meeting | The Meeting SDK renders into one container and its video cannot leave that container's window (see 2026-08-24), so an evaluator's view of a remote student can only be built inside the participants panel and can only be tested by running a real class with a real second person in it. A local camera opens with no session, no OBS and no credentials, so the note box — which the plan calls the binding constraint — can actually be worked on. It is also the in-room case, which is half the product. **Corrected 2026-11-11:** "its video cannot leave that container's window" is not true; a remote student's video can be drawn in a window of its own with its own element from the same container. The choice of a local camera still stands, for the reason that remains: it opens with no session, no credentials and no second person, so the note box can be worked on. |
| 2026-09-18 | A Screenroom note is stamped from its first keystroke, not from Return | The moment worth marking is the moment the evaluator noticed something, and that is when their hands moved. Everything after is them finding the words. A long note is exactly the kind worth writing, so stamping on Return would push the most considered notes the furthest from the thing they describe — fifteen seconds of typing is fifteen seconds of drift on the note that mattered most. |
| 2026-09-18 | The Screenroom window borrows the Classroom Console's shape: media primary, a fixed 320pt column beside it | Two windows in one app should not disagree about what a side column is. The console settled on 320pt fixed precisely so arriving content cannot move the thing being watched, and a note list grows constantly — it is the same problem Cues cards posed to the rail. The composer sits at the foot of the notes column rather than under the picture, because a note is written into the run of notes. |
| 2026-09-18 | Screenroom' second pass reads the notes, not the video, and runs on-device | The plan costed a video pass and a notes pass; the notes pass is a few hundred words of text where the video pass is a batch job with a bill. It is also the one with the higher ceiling, because the notes hold the thing no footage analysis recovers — a human in the room deciding what mattered. On-device through the same FoundationModels framework Cues uses, so there is no key, no bill, and nothing about a student's performance leaves the Mac. |
| 2026-09-18 | When Apple Intelligence is unavailable the pass still runs, and says which engine wrote it | Apple Intelligence is off on most Macs and absent from all of them before macOS 26, so a report that failed there would make the feature conditional on a setting the teacher may not control. The counted engine claims nothing it cannot show — how many notes, across how long, where the longest silence was. An analysis written by a model and one counted from timestamps are different kinds of claim, so the file records which it was and report.md prints it. |
| 2026-09-18 | Cohort consistency is arithmetic and is kept away from the model | It is the one output whose entire purpose is to be shown to a student arguing about a grade. A model asked "were these marked consistently?" answers confidently either way and cannot show its working. Means, spreads and one correlation can. |
| 2026-09-18 | The speaker's report and the marker's report are different documents | The cohort findings are about the marker, not the student: "marks drifted downward through the session" is a fact about an afternoon, and putting it in the student's copy invites an argument about somebody else's grade. The teacher's copy carries them, because when a grade is questioned the person answering should already have looked. |
| 2026-09-18 | A remote presenter is captured from the window they appear in, not from the meeting SDK | The SDK renders into one container and the video cannot leave that container's window (2026-08-24), and a second container is ruled out by the capability matrix, so Screenroom cannot ask it for a student's video. Pointing at the window works with the participants panel, the native Zoom app, Meet in a browser and a recording being played back — and unlike anything through the SDK it can be tested with no meeting and no second person. System audio, not the microphone: a window on screen is heard through the machine playing it. **Corrected 2026-11-11:** the SDK does not limit video to one window, so a second container is not what rules the SDK out here (and Screenroom still cannot ask it for a student's video without a real class). Capturing the window a presenter appears in stands on its other merits: it works with Greenroom's own meeting window, the native Zoom app, Meet in a browser and a recording played back, and can be tested with no meeting and no second person. |
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
| 2026-09-18 | In Sessions the recording is not a tab; the work is | The player lived inside a Recording tab and the notes inside a Notes tab, so writing about something at 3:12 meant leaving the video to do it. Reported as "I am having to add notes without even being able to watch the video live". It was also a correctness bug: the playhead kept running while you switched and typed, so the note landed wherever the video got to. The picture and its scrubber are now permanent; the tabs below switch only Clips, Transcript, Analysis and Notes. It also fixes a category error — Recording and Transcript are views of the material, Analysis and Notes are work on it, and four peers in one row said otherwise. |
| 2026-09-18 | A note added while watching back is stamped at its first keystroke | Read at Return it drifted by however long the sentence took: 3:12 became 3:31. Frozen at the first keystroke it is right either way — paused, the same number; playing, the moment you reacted. The live window always did this; the two paths now follow one rule for the same reason. |
| 2026-09-18 | The Analysis tab is a glance; the report is the document | It printed the whole summary at 15pt into a pane a few hundred points tall, so a five-line paragraph became a fourteen-line wall you scroll. Reported as exactly that. The pane now carries four small numbers, at most three one-line things to change, and the door to the report. A paragraph is the report's job. The same four numbers appear there at four times the size, which is the difference between a glance and a document. |
| 2026-09-18 | Sidebar widths come from the row label, not from a guess | Sessions reserved 240pt minimum for a row whose longest label measured 149pt, so the video paid ~90pt for nothing. Dropping the seconds from the timestamp — the file size already disambiguates two recordings in one minute — takes the label to 132pt and the floor to 180, measured with room to be wrong in. The weekday stays: a teacher looks for Friday's class. |
| 2026-09-18 | Sessions is two lists behind one toggle, not one list of both | Classes and presentations are both sessions and are not the same thing, and mixing them is what made the sidebar unreadable: a row called "Test1" is a class or a student depending on which half of the app you were in. The kind is told from the FILES — Screenroom writes presentation.mov, a class is whatever OBS wrote — so a folder copied from another Mac, or one made before the distinction existed, still classifies correctly. The counts sit on the toggle so an empty list is explained by the tab rather than reading as lost work. |
| 2026-09-19 | Sessions filters on All / Greens / Screens, and unnamed folders use the same words | "Classes" and "Presentations" are words this app does not otherwise use, and naming its two halves after their contents throws away the vocabulary everything else is built on. Greenroom makes Greens, Screenroom makes Screens. An unnamed session is "Green - <when>" or "Screen - <when>" so a folder carries the same word as the tab it appears under. The exception is report.md's heading, which still says "Presentation": that document goes to a student who has never seen Greenroom, and the app's private vocabulary would mean nothing to them. |
| 2026-09-19 | Screenroom's camera is not mirrored, in the preview or the file | macOS mirrors a front-facing camera automatically because the usual job is a self-view, and a self-view should behave like a mirror. This camera is pointed at somebody PRESENTING: a mirrored record puts their right hand on the wrong side and any writing behind them backwards. Set explicitly on both connections rather than left to a default — and the preview matches the file, because a mirrored preview over an unmirrored recording is worse than either, since you frame the shot against one picture and get the other. The Zoom path already did this (enableMirrorEffect(false)); Screenroom was the one relying on the default. |
| 2026-09-23 | An analysis says roughly how much is left, or says nothing | The pass named its step, its place in the run and its elapsed time, but not the remaining half of the waiting-state rule. A step with a moving bar now extrapolates from its own rate; any other step uses what it took on this Mac before, scaled by recording length where the work is per second of video. With neither known — a first run, or a step already past what it took last time — no estimate is shown, because a guess printed as a number is worse than the clock alone. Rounded to the minute so it does not tick or jitter. |
| 2026-09-23 | The report's readings say where they sit, in words, once (supersedes the dials) | Reported from a screenshot as unreadable. The four dials had 8pt captions colliding with the ring and nothing saying whether 137 was fine, and "How it landed" then drew the same three numbers again as bars. Now one card per reading: the number and its unit, a meter with the range shaded, and a sentence ("In the comfortable range", "Faster than the comfortable range") with a check or arrow so the side is carried by shape as well as colour. The sentence describes the position against the band and stops there; judging it is still the teacher's call. Across the page the type floor is 10pt and anything meant to be read is secondary, not tertiary, which all but vanished on a dark window. The map's pace ribbon is drawn on a fixed scale with the band behind it, because scaled to its own peak a steady talk drew as one solid green slab. Sentence length is hidden under three breaths, where it is only the length of the clip. The written takeaways move up to sit under the map. |
| 2026-09-23 | The report's readings become rows sorted into "What to work on" and "What went well" (supersedes the reading cards) | Modelled on Yoodli's results panel, studied from its own published screenshots: each metric is one row, its name on the left and its value in words on the right ("4 fillers, 2%", "No pauses"); opened, it reads tip, evidence, a way to hear it, and where the talk sits against the others in the library. The same row moves between groups with the result, so the teacher sees where everything landed before opening anything. The grammar is borrowed, not the look: no purple, no emoji, no drop shadows. Values are green only under "went well" — a green "No pauses" under "work on" read as praise. Pace keeps a half-dial because pace is read against slow and fast, with its three words outside the arc, and its line breaks over silences. The eight detail sections below the map are folded into the rows. |
| 2026-09-03 | The timeline page uses one series and a step line, with releases as markers | The only honest quantity available for every release is the size of the code; a step line says "this is what shipped, until the next one shipped" rather than implying growth between releases. Single series, so brand green carries it and no legend is needed; three direct labels tell the story, the table carries the rest. The build that never launched is a hollow amber marker, never red: danger is reserved for the "what it never does" claims. |
| 2026-09-24 | A new mark: one G with the teacher in it, and the name in one deep green | The old mark was a gradient cascade of panes into a device, which broke this document's own "no gradients" rule. The new one is flat, built on a single unit (the G's stroke), survives at 16px with its own small-size artwork, and reads as a letter and a person without forming a second letter ("Ei", "Gi" and "Gj" were all tried and rejected). The name drops the lime "Green" because lime fails as text at every size. |
| 2026-09-24 | The app accent stays `#5FA83C`, not the logo's lime | Tried in the app: `#78C000` as the AccentColor turned the segmented control, Start Meeting, the focus ring and every link bright lime, which read as highlighter rather than brand. The lime stays in the mark (the head) and as a fill; the controls keep the quieter green they shipped with. |
| 2026-09-27 | The rail's controls take Zoom's shape and a third of the height | Reported from a screenshot: labels sat above the icons and the cells were mostly padding. The label-on-top was a bug - NSButton is flipped and the cell was drawn as if it were not. The padding was a choice: cells stretched to divide the column, so five icons spread across 700pt, and two caption lines were reserved in every cell for long labels that wrapped. Short Zoom labels, one line, natural-width cells centred in the column, no group eyebrows, End as a red cell, and the SESSION block deleted - its meeting number and recording state repeated the top bar, and its shortcuts moved into the bar and the tooltips. 386pt of controls became 108 on the reference display, and the room goes to Cues. |
| 2026-11-11 | Sessions, a session's page and its report are pages of the main window, and toasts, the upload question and the start card draw inside it while it is in view. Supersedes 2026-09-18 "The report gets its own window" | The owner wants one window and a low profile: Sessions was a window, the report a second, and each toast or card a floating panel over whatever the teacher was doing. Now Home → Sessions grid → one session → its report, each with a Back (⌘[, Esc), and the window grows from its anchored top edge to 1180×760 for them and returns to Home's size on Back. A session is one page rather than grid plus a 400pt inspector, so the picture can have the width a picture wants. The floating panels stay for when the window is closed, minimised or covered - the class itself, where Zoom and Chrome sit over everything and a hotkey toast must still land on the screen being watched. Settings and the live-class windows are unchanged. |
| 2026-11-11 | A class start arranges nothing by default; a floating control bar instead | The owner wants Greenroom low-profile: it should not open, move or resize windows unless asked. "Arrange windows when a class starts" is now a setting, off by default and on every Mac, and with it on today's behaviour is unchanged. With it off Zoom shows its own meeting window wherever it opens, because custom-UI video can only render inside our own panel and that panel is the arranging. A small pill at the bottom centre carries mute, camera, record, chat, people, the clock and End. It is non-activating like the readiness card, so a click works the meeting without pulling Greenroom in front of the teacher's slides. The notes bar and toasts sit above it. Amended the same day: custom meeting UI works without a layout too, so a class that arranges nothing is not forced onto Zoom's own window. With custom UI on, Zoom opens no windows and nothing opens by itself; the bar gains Speaker and People buttons that open the speaker window (a plain movable window, centred on the main display the first time) and the participants panel (full-screen on the reference display if there is one, otherwise a movable window on the main display). Both show open or closed like Chat and Notes. With custom UI off the bar has no such buttons and Zoom's own window is the picture. |
| 2026-11-11 | Greenroom's own meeting window runs every meeting, and Custom meeting UI is on by default | The owner wants one calm place for a class: video in the middle, a toolbar along the foot, Gallery or Speaker above, one side panel on the right. It is the familiar shape of a meeting app and none of its look: the type, colours, radii and motion are this document's, and the brand green appears only through `Brand.green`. It is the participants panel grown a meeting form, not a rewrite. The rail is gone from this form: you are the corner preview, and Cues and the needs block head the People panel. Speaker view has its own stage element, so it works in a 1:1, and says "Waiting for others" when you are alone. One controls model, owned by the coordinator, feeds the toolbar and the floating pill; the pill is shown only while the window is closed, minimised or fully covered (0.5s debounce), and its Speaker and People buttons became one Meeting window toggle. Placement: with no layout it opens once at Start, autosaved as `MeetingWindow`, filling the reference display or else centred (never borderless); arranged with a reference display it is today's full-display panel and the chat holds the column; arranged on one display it takes Zoom's slot in Speaker view, the toolbar appearing on hover, with the chat underneath. End asks again in place rather than raising a modal, because a modal activates the app and brings the main window over what is being taught. Supersedes the live-speaker window and the 2026-08-24 "no pop-out" reasoning (corrected above). Custom UI defaults to on, with a one-time migration key `customUIMode.migratedV2`; Zoom's own window stays as the fallback until its removal. |
| 2026-11-12 | Layout templates replace the fixed main-pane + side-column split; None is the default | The owner asked for a creator: teachers drag the windows they want onto a picture of their display, and name the layout. The old split could only say "one app, then the meeting over the chat, on the left or right", so a second app, a chat-less class or a reference display each needed another switch. Now a template is named pieces (Meeting, Chat, up to four apps) placed on a 12-by-12 grid, with an optional two-display version that replaces the "show participants on a second display" switch. None, the first card, is the default and arranges nothing (it replaces "Arrange windows when a class starts"); two starters and, for a Mac that had changed the old settings, "Your previous layout" are ordinary editable templates. The choice is made in Settings, in onboarding (the same cards), and in a quiet "Layout" line under Start and a menu-bar submenu, which are greyed while a class is live because a class keeps the layout it started with. The old keys are read once and by a settings import, never written or exported again. |
| 2026-11-12 | Surfaces show the window's own wallpaper-tinted background, not a painted one | `Brand.windowBackground` painted `windowBackgroundColor` as an opaque SwiftUI fill, which macOS does not wallpaper-tint, so Settings' title bar and tab bar (the real backdrop) were bluish over flat grey content. The token is deleted; pages paint nothing and keep `.scrollContentBackground(.hidden)`, as Home always did. Cards keep `controlBackgroundColor`. |
| 2026-11-12 | Every control on the meeting window's toolbar is one shape: a glyph over a caption, 64pt wide; menus are popped NSMenus; what does not fit goes into More | The first toolbar mixed icon-over-caption cells with SwiftUI `Menu` buttons, which macOS flattens to a small inline label, so Share, React and Host tools looked like a different toolbar. A menu cell is now a plain cell with a transparent overlay that pops a hand-built NSMenu upward (`MeetingMenuAppKit.swift`), which also keeps the non-activating panel's focus rules. Width is computed, not broken into sizes: `MeetingToolbarLayout` drops the least important control first (Notes, Record, React, the clock, Security, Chat, People, Share, Stop Video) and More lists them. Host tools is gone: Security holds the rules, the People panel holds Mute all and Ask all to unmute, and the waiting room's answers. |
| 2026-11-12 | Greenroom's own meeting window looks like Zoom's meeting window, dark whatever the system. Supersedes the "none of its look" line of 2026-11-11 and the 64pt cell of the entry above, for the meeting window only | The owner wants teachers and students to feel at home the moment the window opens: if it looks like the Zoom they already know, nobody has to learn where Mute, Participants or Share are. So this window now follows Zoom's macOS meeting window: #1A1A1A, tiles #232323 at 8pt radius and 4pt apart, a slim top bar in the title-bar area (green shield for meeting info, View menu with Speaker, Gallery and Fullscreen), a name capsule bottom left on each tile with a red slashed microphone when muted, a 2pt green ring on whoever is speaking, a yellow hand badge top left, the name large and centred when the camera is off, "Name (me)" on your own tile, Speaker view with its strip of small tiles along the TOP, Gallery paged by arrows at the sides, a 64pt toolbar with a hairline (Mute and Start Video with carets at the left, Security, Participants, Chat, React, Share in green, Record, Notes, More in the middle, a red End at the right, a lighter rounded wash on hover), and dark Participants (search, waiting room, initials rows, Invite and Mute All) and Chat (a rounded "Type message here..." input) panels. **The one hard line:** nothing is Zoom's logo, the word "Zoom" as branding inside the window, or Zoom's icon artwork; every glyph is an SF Symbol that reads the same. Every value lives in `MeetingTheme` (App/UI/MeetingTheme.swift), which says why, so no hex is scattered. Zoom's own meeting window is dark in any appearance, so this window forces dark aqua. The app accent stays `Brand.green` everywhere else; the greens here (shield, Share, speaking ring) are Zoom-familiar cues for this window only. Not changed: the reference display's full-display panel, the floating pill, Settings. Side-by-side view is not offered because it is not built. |
| 2026-11-12 | One click shrinks the meeting window into the floating bar and one click grows it back, as a morph | A teacher who wants the slides back should not have to close the window and wait for the pill to appear. A snapshot of the window travels to where the bar will sit and fades while the bar fades in (and the reverse), 0.35s ease in and out, or a plain crossfade under Reduce Motion. The window is hidden, not closed, so its video elements stay attached and coming back is instant. The bar's show-when-covered rule is suspended while it runs, and a second click turns the morph round from wherever it has got to. The controls: "Minimize to controls" in the top bar, More, the pill's Meeting window button, the puck's "Expand to meeting window", and an unbound shortcut. |
| 2026-11-13 | Floating surfaces use real macOS 26 Liquid Glass through one shared style; content never does | The owner saw the "Getting ready" banner over the dark main window as a flat grey slab with weak text, and said the HUD "is only good looking when the bg is the wallpaper and it gives the glass look. We have to stick with this macOS glass look throughout the app." Every floating control (banners, toasts, upload prompt, control pill, recording bar and countdown, readiness HUD, the editor's floating panels) now goes through `.greenroomGlass` / `GreenroomGlassAppKit` (`App/UI/Glass.swift`): `glassEffect` on macOS 26, material plus hairline on 14 and 15. Pages, cards, lists, side panels and docked bars stay plain, because glass belongs to the control layer. Banner text moved to semantic `.secondary` so it reads in light and dark. |
| 2026-11-13 | A session is a page whose work tabs sit in a 300-480pt inspector beside the player. Partly reverses 2026-11-11 "a session is one page rather than grid plus a 400pt inspector" | The one-centred-column page left dead space at both sides and hid the notes below the fold. The page stays a page with its own Back; only the work moves beside the picture, as an `.inspector` that folds away, and the player uses system inline controls. Kept: 2026-09-18 picture and scrubber always on screen, flat tabs, and an empty pane centred with its action. |
| 2026-11-13 | Browse grids drop the `controlBackgroundColor` card: the thumbnail is the card, with a hover lift. Reverses 2026-11-12 "Cards keep `controlBackgroundColor`" for browse grids only | The owner wanted a clear hover on every clickable card and a quieter selection. Photos and Music grids have no box, so Sessions follows. Choice tiles and grouped-form boxes keep their fills (choice tiles `.quinary`). Browse tiles show no lasting selection (a click opens, so it only read as a default after Back); only a keyboard focus ring. |
| 2026-11-13 | Sessions uses a system sidebar, search, sort and filter in the toolbar. Replaces the RasanAI-style Sessions sidebar of commit 5d744db (44pt rows, 15pt labels, custom fill; never logged) | The owner said the page felt unrelated to the rest of the UI and that the whole app should align with the macOS glass feel. A hand-drawn column gets no glass on 26; `NavigationSplitView` with a `.sidebar` List does, and the 180pt floor of 2026-09-18 stays. The status filter becomes a toolbar menu, since a single-selection List cannot combine it with Show. |
| 2026-11-13 | Glass rule amended: we never apply glass to content; system sidebars, inspectors and toolbars draw their own. Changes the "side panels never use glass" line of the entry above | A system inspector or sidebar gets its material from macOS, so allowing it adds no glass of ours, while the rule still bars glass on pages, cards and lists. In-content control bars may use `.greenroomGlassButton(prominent:)`. |
| 2026-11-13 | Segmented selections are no longer brand green | The scene-root `.tint(Brand.green)` made every segmented control fill its selection green. `GreenroomSegmented` clears the tint on the picker only, so the system draws the selection (a sliding glass piece on 26); Start, links and toggles stay green. A hand-built segmented control is barred. |
| 2026-11-13 | Segmented selections are brand green again, and they slide. Reverses the row above | The owner: "New Meeting should still be green like we had earlier, it's just that the menu shifting should animate well." The native Picker could be neutral and jump, or green and jump; `GreenroomSegmented` is now a custom row of buttons with one selection capsule (Brand green, white label) that slides: tinted Liquid Glass with `glassEffectID` on 26, `matchedGeometryEffect` before; Reduce Motion crossfades in 150ms. Same API, VoiceOver still hears a segmented Picker. |
| 2026-11-13 | Amber "leaves this Mac" moves off the buttons onto the glyph, a first-time confirm and the status strip | The Upload tile carried an amber subtitle; toolbar buttons have no room for one, and hover help alone would weaken the rule that anything reaching the network reads amber. The Upload and agent-analysis glyphs are tinted `Brand.net`, the first upload asks once per Mac ("This sends the recording to YouTube. It leaves this Mac."), and the status strip under the player keeps `Brand.netText` ("On YouTube - Unlisted"). |
| 2026-11-13 | Record what Sessions filters actually are: Everything / Classes / Recordings / Presentations plus a Status group | Out of step with the log: 2026-09-19 says All / Greens / Screens and 2026-09-18 says two lists behind one toggle, but the code ships the four Show options and a Status filter (None / Not uploaded / On YouTube / Analysed). This entry records what ships; the Show options become sidebar rows with counts and Status a toolbar menu. |
| 2026-11-13 | Segmented selection is a plain green capsule on every macOS, no Liquid Glass morph. Amends the two rows above | The glass track and glass selection inside a `GlassEffectContainer` rendered as a blurred grey blob with unreadable labels in Home, the Editor and Webcam. A crisp, readable control beats the morph; the capsule still slides with a spring and sits behind the label. |
| 2026-11-13 | Glass retried as a lone selection capsule over a plain track, labels outside the container: still no. Confirms the row above | One `.glassEffect(.regular.tint(Brand.green))` capsule, frame sliding, labels in a separate layer: labels stayed crisp, but in the real UI (background window) the selection rendered grey, not green, so the rule "Brand green selection" failed. Reverted to the plain green capsule. DebugTour gained `cmd=homeMode mode=create|join|record` for mid-slide shots. |
| 2026-11-13 | Home is "Direction A: Picture first": a 16:9 picture card on the left, name, setup chips, readiness pills and one mode-following button on the right; the New / Join / Record switcher moves to the toolbar centre and the big logo header goes. Chosen by the owner from HTML mockups | The old Home was a tall centred stack of text with no picture of what the class would see. The card draws the current look from the Webcam page's own numbers (shape, share kind, bubble position and size), so the camera is NOT on just because Home is open: the live preview is opt-in ("Show live" asks for the same preview the Webcam page and the Record view share), and it turns off again when Home is left or a start begins. Setup is five chips (look, behind you, camera, microphone, layout), each a menu wired to the setting the Webcam page writes, with "More…" into Settings; the mic chip draws a level only while a session already has the microphone open. Readiness is pills built from what a start checks (Zoom credentials, camera, microphone, Screen Recording): green check, or amber with the problem and a click that goes to the fix. The Status log stays one click away under "Details". End Session and Record are drawn only while a session is live, not dimmed before; the "Manual controls" menu moves under the button's chevron. Return in the name field starts. Options column on the left (mark and name, name field, equal Look / Share / Camera / Microphone / Layout tiles, one button that is Brand green in every mode, Record marked by a red dot only), picture card and ready pills on the right, level with each other; default window 984pt wide, 900pt minimum. The toolbar switcher has a track-less `toolbar` style with a solid green selection. |
| 2026-11-13 | Messages live top-right, never inside a window | The upload prompt appeared sometimes inside the main window, where on the short Home window it covered Start Meeting, and sometimes as a panel centred on screen. All messages now share one glass panel at the top-right of the working screen, where macOS puts its notifications; the in-window and centred paths are deleted. The upload glyph and Upload button are amber because the upload leaves this Mac. |
| 2026-11-13 | The meeting window's shrink action is labelled "Control bar", the yellow light and Command-M run it while a meeting is live, and a one-time glass tip points at it | The owner: people open the window and cannot tell that the small unlabelled arrows icon beside View shrinks it into the floating bar. The top-bar item is now icon plus "Control bar", styled as View (hover help: "Shrink the meeting to the control bar so you can get back to your slides (⌘M)"; the bar's expand button reads "Expand back to the meeting window"). "Control bar" names where it goes; "Shrink" alone would not. While a meeting is live the window's minimise (yellow light, Window menu, Command-M) runs the same morph instead of going to the Dock, by overriding `miniaturize` on the window (NSWindowDelegate has no should-miniaturize); with no live meeting it minimises as normal. "Shrink meeting to control bar" is a customisable shortcut, default Command-M, scoped to the meeting window (`ShortcutScope.meetingWindow`: never registered system-wide, so no other app loses the key; exempt from the reserved-key check, which exists for global hotkeys). The first meeting window on a Mac shows a small glass callout under the label with a close x, remembered in UserDefaults `meetingShrinkTip.done`, set by a shrink or by closing it; it is a small subview, so clicks elsewhere pass through. DEBUG: DebugTour `cmd=resetMeetingTip` (or `defaults delete <bundle id> meetingShrinkTip.done`) shows it again. Rules in `App/MeetingShrinkRules.swift`. The window stays forced dark (2026-11-12); the tip is a floating control, so it uses `GreenroomGlassAppKit` (2026-11-13 Glass). |
| 2026-11-13 | The menu bar menu follows state (Direction A): a native NSMenu whose first line is a status header, with items shown or hidden by state, never greyed | Idle: "Greenroom · Ready" (check) or "Needs attention" (amber) with the problems right under it, each clickable to its fix like Home's pills; then New Meeting, Join Meeting…, Record… (Home's three modes; Join and Record open Home in that mode, nothing records silently), Layout, Sessions…, "Last: title · length", Show Greenroom, Settings…, updates, privacy, Quit. Live: "● Live · class · elapsed" and "● Recording time" ("· Paused"), Pause/Resume, Stop/Start Recording, Notes, Snap Back, Speaker Tile, Draw, End Session… (destructive, near the bottom), Show Greenroom, Quit. Layout is hidden while live because a live class keeps its layout. Shortcuts come from the customisable bindings; SF Symbols on every action. The list is a pure function in `App/UI/MenuBarModel.swift`, unit-tested; `MenuBarView` only draws it. The menu bar icon already flips to a record glyph + REC while recording (extras render monochrome, so a red dot is not possible). |
| 2026-11-13 | The Sessions sidebar is the window's own root sidebar column, as in Finder, and Command-B toggles it. Replaces the nested split view and the `topInset` workaround of commit 3616f38; takes the named fallback of `docs/glass-redesign-plan.md` section 5 | The owner's side-by-side shots: in Finder the floating glass sidebar runs from the very top with the traffic lights inside it and the toolbar sits over the detail only; ours hung under a full-width toolbar band. A split view nested in a page layer cannot get that on macOS 26, so `ContentView`'s root is now a `NavigationSplitView`. The sidebar column (Show rows with badges, storage footer: `SessionsSidebar.swift`) exists for the Sessions grid, a session and its report; Home and Record collapse it (`.detailOnly`, `.toolbar(removing: .sidebarToggle)`) and look as before. Toolbar items sit in the detail column. The column appears and goes at the fade-out point of the Home / Sessions motion, while Home is invisible; the pinned page layers subtract the sidebar's width. Command-B is the View menu's single Show/Hide Sidebar item (it replaces the system one, so the menu shows one; Control-Command-S stays as a hidden key equivalent), does nothing on Home, and is saved; it is reserved from global hotkeys. Rules in `App/UI/SidebarRules.swift`. |
| 2026-11-13 | Messages move to top-centre and cards get smaller | The owner moved messages to top-centre and asked for smaller cards. The panel is centred on the working screen's `visibleFrame`, 12pt below the menu bar; cards 340pt wide (was 380) with tighter type and padding; the entrance drops down instead of sliding from the right. Supersedes the top-right placement row above. |
| 2026-11-13 | Home is calmer: setup is one summary line with Edit, readiness is one "Ready" chip, fewer words, one primary shape. Window opens 940 wide, 278 tall (no footer). Amends the Direction A row | The owner wanted less cognitive load. Setup collapses to "Cutout · Whole screen · MacBook Pro · MacBook Pro · Meeting and chat" with Edit unfolding the five tiles in place (250ms `snappy`, instant under Reduce Motion; Done folds; per launch, collapsed by default); a missing camera or a gone share target is amber in the line. The Ready chip is the details: a click shows the status log; with a problem only the amber problem pills show, each a click to its fix, and the Details link is gone. Removed: the NAME label (the placeholder stays, the field is labelled for VoiceOver), the mode subtitle (the switcher says it), the picture caption. Show live is an icon-only glass button with hover help. The chevron menu is a segment inside the Start button's one capsule (Brand green, red dot in Record). Window height is arithmetic from fixed parts (`HomeView.columnHeight`); the card fits beside the column, level top and bottom. Pure parts in `HomeCalmRules.swift`. |
| 2026-11-13 | A page grows from Home's top-left corner and Back restores Home's saved frame exactly. Amends 2026-09-04 "grows around the middle" | The window drifted upward across a Home -> Sessions -> Home round trip. The page frame is now Home's top-left, shifted only by the overflow past the screen it is on (`WindowFrameRules.pageFrame`); "moved on the page" compares the frame the window really settled at, not the target; Back restores the saved frame and size while Home's state is unchanged. |
| 2026-11-13 | While a class is live, closing the meeting window asks; quitting asks with the role's own words; the Dock, Show Greenroom and the menu bar's live header always bring it back | The owner closed the meeting window and the class kept running with nothing to return to. Close shows a sheet on the window: host "End Meeting for All", participant "Leave Meeting", "Shrink to Control Bar", Cancel (default and Escape), plus "Recording will stop and be saved." when recording. Quit offers End Meeting & Quit / Leave & Quit / Stop Recording & Quit with Cancel; logout, shutdown and restart end cleanly without asking. A Dock click brings back the meeting window, or the control bar if shrunk; the live header line in the menu bar is clickable. The yellow light still shrinks. Rules in `App/LiveExitRules.swift`; table in `docs/dead-ends-audit.md`. |
| 2026-11-13 | The floating meeting bar says what its buttons do: 14 items become 11, one timer, End is the only red control | The owner: "some of the buttons don't even make sense". The bar was grip, a shrink glyph that actually opened the meeting window, mic, camera, REC with a clock, pause, a red stop square, a pen that read as a compass, chat, notes, a two-windows icon, a people count, an unlabelled meeting clock and a red End: two timers nobody could tell apart, two red buttons side by side. Now: grip, `Meeting` (expand glyph plus the word; morphs back to the meeting window), mic, camera, the REC pill, Pause, `Draw` (`pencil.tip` plus the word), chat with its unread badge, the people count, `⋯` and End, grouped by hairlines. The pill shows ONE timer, the class time; its hover help gives the recording's length ("Recording 1:29 · class 1:38"); not recording it reads "Not recording" in secondary text. Its menu holds Start or Stop Recording and Pause or Resume; stop is not confirmed, as before (it ends nothing for anybody). The REC dot pulses red while recording (still under Reduce Motion) and is the recording signal, not a control; End is the only red control (the muted mic and stopped camera keep their red state glyphs). End asks in the close prompt's words, "End Meeting for All" or "Leave Meeting". `⋯` holds Notes, Meeting Views, Layout (the live class's layouts, Apply now) and Collapse to Small Button, so nothing was lost. Every hover help is the name plus the user's own bound key from ShortcutModel, never a hardcoded one. The Record view's bar follows the same rules: one timer, Draw has a word, the one red control is a labelled Stop. Widths come from `MeetingBarLayout` (584pt, or 620 with the meeting window, become 557 and 651; the Record view's bar 272 to 314 for the word Draw and a labelled Stop), asserted in `Tests/MeetingBarModelTests.swift`. |
| 2026-11-13 | Home's Start button is a standard 32pt large control; Show live says so; Edit swaps the summary for a Setup caption; the sidebar toggle is Sessions-only. Amends the calmer-Home row | The owner found the 44pt capsule fat and its chevron invisible, the camera icon unexplained, every value drawn twice while Edit was open, and a sidebar toggle on Home that did nothing. The chevron glyph is drawn under a clear Menu; Show live / Stop live is a glass capsule; the summary row and the "Setup / Done" row fade into each other at the same height. `.toolbar(removing: .sidebarToggle)` never reached the toggle SwiftUI's split view owns, so `ContentView.syncSidebarToggle` hides that AppKit toolbar item off Sessions pages. DebugTour gained `homeSetup expanded=`. |
| 2026-11-13/14 | Home is tried as one vertical column and Sessions moves to the toolbar's right. Amends the Direction A and calmer-Home rows | The owner asked to try vertical and to move Sessions right. Logo, a 16:9 picture card (Show live top-right), Ready chip, name, setup line with Edit, then a full-width primary button (content-sized looked ragged against the card and field edges), then the footer. 544pt column, 24pt side margins, window 592 wide by 636 tall, 52 more only when the footer shows, Edit grows it downward from the anchored top edge. 560 wide folded Help and Settings into an overflow chevron in light mode, so the default is 592 and the switcher words are New / Join / Record. The toolbar is the switcher centred, then Sessions (icon and label), a fixed spacer, then Help and Settings; the footer's trailing link reads All sessions (N). Home to Sessions and back returns the identical frame |
| 2026-11-14 | The meeting window gains Multi-speaker, Side-by-side share layouts and two tile filters. Reverses "Side-by-side view is not offered" in 2026-11-12 | The owner compared the window with Zoom's desktop app and approved these. Multi-speaker is a third view beside Speaker and Gallery: the 2-4 most recent speakers large, everyone else in a strip below, your preview at the strip's end; people keep a tile at least 3 s, and with fewer than three people it is Speaker, as Zoom's is. While someone shares, View offers Standard (the share fills the stage) and Side-by-side: Speaker, Gallery or Multi-speaker (share left, a draggable divider, default 70/30, clamped 50/85, double-click resets). The layout, the split, Hide self view and Hide participants with video off are remembered per Mac; a share's end returns to the view the person had. Hiding your self view changes only what this window draws. The segmented control is Speaker / Gallery / Multi-speaker and the shortcut is "Cycle meeting view". Still forced dark, same tiles, gaps and chrome; the divider's handle is a 4pt white pill at 28% (70% on hover). Logic lives in `MeetingViewRules.swift`, with tests. |
