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

## Motion

- **Approach:** Minimal-functional. Motion clarifies state; it never decorates.
- **Duration:** 150-250ms for hover and state changes. 250ms for layout moves
  (`snappy(0.25)` in SwiftUI).
- **Easing:** ease-out entering, ease-in leaving, ease-in-out for movement.
- **Allowed:** button hover lift (`translateY(-1px)`), arrow nudge on link
  hover, chat scroll-to-latest, shape-preview crossfade.
- **Not allowed:** scroll-driven animation, parallax, entrance choreography.

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
| 2026-08-18 | Promoted mono to an identity role in section eyebrows | Gives the brand a typographic signature without abandoning the platform font, and reinforces the technical-honesty posture of the transparency page. |
