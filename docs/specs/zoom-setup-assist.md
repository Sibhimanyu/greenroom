# Zoom setup, guided: Marketplace beside the guide

Branch: feat/zoom-setup-assist (stacked on feat/personal-room). Code: `App/UI/ZoomGuideStep.swift`, `App/Zoom/ZoomMarketplaceGuide.swift`, `App/Zoom/ZoomGuideFlowRules.swift`, new `App/Zoom/ZoomMarketplacePages.swift` (pure) and `App/UI/ZoomMarketplaceWindow.swift`. Evidence: `App/Debug/ZoomMarketplaceProbe.swift` (DEBUG only) and its log, 2026-11-27.

## Problem

The setup guide's Meeting app and Hosting app parts each have one link, "Open Zoom App Marketplace", to `marketplace.zoom.us/user/build`. From there people must find Build App, the right app type, the Scopes, Activation and App Credentials tabs on their own, then copy five values one by one and paste them back. Owner, 2026-11-27: "it should be very very easy for them to set it up".

## Decision

Owner, 2026-11-27: "I don't mind how you do it". Greenroom opens Zoom Marketplace in its own window beside the setup guide. The guide follows the page the person is on, links each step to that exact page, and fills the keys in from the page. Safari stays one click away.

## What the probe found (2026-11-27, owner's account)

- Signing in with Google works inside a WKWebView that uses `WKWebsiteDataStore.default()` and a Safari user agent.
- Marketplace's "Developers" link opens a new window (target=_blank). The web view must load such links in place.
- Created apps: `https://marketplace.zoom.us/user/build`.
- Build App makes a draft at `/develop/applications/<id>`, headed "What kind of app are you creating", with radios "General app", "Server to server OAuth app" and "Webhook only app".
- A Server-to-Server app lives at `/develop/apps/<id>/<tab>`, where tab is `information`, `credentials`, `feature`, `scope` or `activation`. Its credentials page has the labels Account ID, Client ID and Client Secret. Under them, in that order, are three `input.MuiInputBase-input` fields: text (22 characters), text (22) and password (32).
- A General (Meeting SDK) app lives at `/develop/applications/<id>/<tab>`, where tab is `information`, `features/sdk` (Embed), `features/access`, `scopes` and so on, each with a query string. Basic information has a Client ID label, a text input (22) and a password input (32).
- App IDs are 22 characters of letters, digits, `_` and `-`.

## Non-goals

- Greenroom never presses anything on Zoom's pages: no Create, Save, Activate, Add Scopes or Regenerate. People press Zoom's buttons themselves. The window may point at an element (R6), never click it.
- No Marketplace REST API. Its app list is reported to return empty results, and it would need another scope.
- No change to Sign in with Zoom (still Coming soon).
- Scopes are not read back from the page. Check Zoom setup stays the judge.

## Requirements

### R1. One Zoom window beside the guide

The guide's "Open Zoom App Marketplace" link becomes a button with the same title. It opens (or brings forward) one "Zoom" window: a normal, fully visible macOS window holding a WKWebView, with these properties:
- it uses `WKWebsiteDataStore.default()`, so the sign-in persists, and the probe's Safari user agent;
- new-window links load in place;
- its toolbar has Back, Forward, Reload, a read-only host-and-path label, and **Open in Safari** (the current page's URL).

The window opens beside the setup guide's window on the same screen (the guide moves left, Zoom takes the right, if both don't fit side by side; otherwise each keeps its size). It takes focus only when opened by the person's click. Closing it leaves the guide as is.

Acceptance: a pure `ZoomMarketplaceWindowPlacement.frames(screen:guide:)` is tested for a 1440×900 and a 1920×1080 screen and a guide already on the right; manual test: Developers opens in place.

### R2. The page is understood

The pure `ZoomMarketplacePages.page(for: URL) -> ZoomMarketplacePage?` maps an address to:
`.createdApps`, `.chooseType(draftID)`, `.s2s(appID, tab)` with tab ∈ information, credentials, feature, scopes, activation, `.general(appID, tab)` with tab ∈ information, embed, scopes or other, or `.signIn` (zoom.us/signin, accounts.google.com and the like), or nil for anything else.
- Only `https://marketplace.zoom.us` counts as Marketplace. Look-alike hosts are nil.
- IDs must match `[A-Za-z0-9_-]{10,40}`.

Acceptance: table tests covering each probe address above, query strings, trailing slashes, `marketplace.zoom.us.evil.com`, `http://` and an over-long ID.

### R3. The guide follows along

When the window shows a page, the matching guide part opens and its step list marks the current step:
- Meeting app: 1 choose General app (chooseType or createdApps), 2 turn on Meeting SDK under Embed (general/embed), 3 keys (general/information).
- Hosting app: 1 choose Server to server OAuth app, 2 add the scopes (s2s/scopes), 3 activate (s2s/activation), 4 keys (s2s/credentials).

The pure `ZoomGuideFollowRules.step(part:page:)` decides the step. A page of the other kind does not move the guide to a different part while that part has unsaved typing.

Acceptance: table tests for every page × part.

### R4. Every step links to its exact page

Once the window has seen an app of a kind, Greenroom remembers its ID for that part. Each step row then gets a small button:
- Meeting app: **Open Embed** (`/develop/applications/<id>/features/sdk`) and **Open Basic information** (`…/information`).
- Hosting app: **Open Scopes** (`/develop/apps/<id>/scope`), **Open Activation** (`…/activation`) and **Open App Credentials** (`…/credentials`).

Before an ID is known, step 1's button is **Create the app** (`/user/build`), and the later rows show their words without a button.

The IDs are kept in UserDefaults (they are not secrets) and cleared when the part's keys are cleared. `ZoomMarketplacePages.url(for:)` builds each address and round-trips through `page(for:)`.

Acceptance: round-trip tests for every tab.

### R5. Fill in from this page

On s2s/credentials or general/information, Greenroom reads the key inputs with a script that runs only on those pages, finding each value by its label (Account ID, Client ID, Client Secret). If the label lookup fails, the probe's input order (text, text, password) is the fallback. A value counts only if it matches `[A-Za-z0-9_-]{10,64}`.
- If the part's Greenroom fields are empty, they are filled straight away, and the part says "Filled in from Zoom" with Undo.
- If any field already has a different value, the part shows **Use the keys from this page** instead, and nothing is overwritten without that click.
- Values go into the same bindings as typing (so the same Keychain save path). They are never logged, never put in the window's title and never sent anywhere else.

Acceptance: pure `ZoomKeyFillRules.decide(current:found:)` tests (empty → fill, same → nothing, different → offer, a partial read → offer only the found fields), and `ZoomMarketplacePages.isKey(_:)` tests; a source scan that the reading code has no `print`, `log` or `NSLog` near the values.

### R6. Point at Zoom's control

On chooseType the window outlines the right radio ("Server to server OAuth app" for the Hosting app, "General app" for the Meeting app) with a 3pt `Brand.green` ring. On s2s/scopes it outlines "+ Add Scopes", and on s2s/activation the Activate button. It is a CSS outline only. No click, no focus, gone on the next page.

Acceptance: manual; the script is a constant beside `ZoomMarketplacePages`, matched by the visible label text.

### R7. Check runs by itself

When the last key of both parts becomes filled through R5 and no session is live, Check Zoom setup starts once by itself. Every failed check line that names a Marketplace place links straight to it through R4 (a missing scope goes to Scopes, a not-activated app to Activation, wrong keys to App Credentials).

Acceptance: `ZoomCheckActionRules` tests for the new targets.

### R8. Safari stays available

If the window shows a sign-in error page or the person prefers it, Open in Safari opens the same address. The guide's steps keep their words, so the flow still works by hand.

### R9. Words and docs

The steps in `ZoomMarketplaceGuide` are shortened to match R3. docs/zoom-setup.html and docs/guide.html describe the Zoom window and the fill-in. GLOSSARY gains "Zoom window". The codemaps are updated. scripts/render/zoom-guide.sh gains states: no ID known, IDs known with the current step marked, filled in from Zoom, and the offer to use the page's keys; light and dark.

## Plan

1. Pure rules first, red then green: R2, R4 URLs, R3, R5 decide, R1 placement, R7.
2. The window (R1, R6, the R5 reader), modelled on the probe.
3. Guide wiring (R3–R5, R7) through `OnboardingView`, with plain values and closures so the renders still work.
4. Docs, renders, the full check, then an owner live test with a fresh Server-to-Server app.
