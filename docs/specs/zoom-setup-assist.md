# Zoom setup, guided: Marketplace in its own window

Branch: feat/zoom-setup-assist (stacked on feat/personal-room). Code: `App/UI/ZoomGuideStep.swift`, `App/Zoom/ZoomMarketplaceGuide.swift`, `App/Zoom/ZoomGuideFlowRules.swift`, new `App/Zoom/ZoomMarketplacePages.swift` (pure) and `App/UI/ZoomMarketplaceWindow.swift`. Evidence: `App/Debug/ZoomMarketplaceProbe.swift` (DEBUG only) and its log, 2026-11-27.

## Problem

The setup guide's Meeting app and Hosting app parts each have one link, "Open Zoom App Marketplace", to `marketplace.zoom.us/user/build`. From there people must find Build App, the right app type, the Scopes, Activation and App Credentials tabs on their own, then copy five values one by one and paste them back. Owner, 2026-11-27: "it should be very very easy for them to set it up".

## Decision

Owner, 2026-11-27: "I don't mind how you do it". Greenroom opens Zoom Marketplace in its own large window, centred on the guide's screen. The guide follows the page the person is on, links each step to that exact page, and fills the keys in from the page. Safari stays one click away.

## What the probe found (2026-11-27, owner's account)

- Signing in with Google works inside a WKWebView that uses `WKWebsiteDataStore.default()` and a Safari user agent.
- Marketplace's "Developers" link opens a new window (target=_blank). The web view must load such links in place.
- Created apps: `https://marketplace.zoom.us/user/build`.
- Build App makes a draft at `/develop/applications/<id>`, headed "What kind of app are you creating", with radios "General app", "Server to server OAuth app" and "Webhook only app".
- A Server-to-Server app lives at `/develop/apps/<id>/<tab>`, where tab is `information`, `credentials`, `feature`, `scope` or `activation`. Its credentials page has the labels Account ID, Client ID and Client Secret. Under them, in that order, are three `input.MuiInputBase-input` fields: text (22 characters), text (22) and password (32).
- A General (Meeting SDK) app lives at `/develop/applications/<id>/<tab>`, where tab is `information`, `features/sdk` (Embed), `features/access`, `scopes` and so on, each with a query string. Basic information has a Client ID label, a text input (22) and a password input (32).
- App IDs are 22 characters of letters, digits, `_` and `-`.

## Non-goals

- Greenroom never presses anything on Zoom's pages on its own. The coach only points (R6). The one exception is R16 ("Do this step"): on the person's press, for four listed safe steps, through an allow-list and a deny-list (never Regenerate, Delete, Remove, Deactivate, Disable, Submit, Publish, Agree, Accept, Terms, Sign out, Log out or Uninstall). Everything else is pressed by the person.
- No Marketplace REST API. Its app list is reported to return empty results, and it would need another scope.
- No change to Sign in with Zoom (still Coming soon).
- Scopes are not read back from the page. Check Zoom setup stays the judge.

## Requirements

### R1. One Zoom window

Status: built (window, placement tested); untested live: Developers opening in place, sign-in persistence, Sign out of Zoom.

The guide's "Open Zoom App Marketplace" link becomes a button with the same title. It opens (or brings forward) one "Zoom" window: a normal, fully visible macOS window holding a WKWebView, with these properties:
- it uses `WKWebsiteDataStore.default()`, so the sign-in persists, and the probe's Safari user agent;
- new-window links load in place;
- its one bar is the Greenroom bar (R13): Back, Forward, Reload, **Tips** (R6) and a "..." menu with **Open in Safari** (the current page's URL) and, only when the window is signed in, **Sign out of Zoom**. The page's host and path are the bar title's tooltip.
- The sign-in is remembered in Greenroom (separate from Safari) until Zoom ends it; Sign out of Zoom clears it, and is offered only while signed in (`ZoomSignInStateRules`: a sign-in page or a "Sign In" link in Marketplace's header means signed out, an account menu means signed in, unknown until the first report, signed out at once after signing out). It removes the website data of every record in `WKWebsiteDataStore.default()` whose name contains "zoom", then reloads `https://marketplace.zoom.us/user/build`.

The window opens large and centred on the setup guide's screen: about 85% of the visible frame, capped at 1400x1000, never under 900x700 (unless the screen is smaller). The setup guide is not moved or resized (owner, 2026-11-27: side by side was dropped). It takes focus only when opened by the person's click. Closing it leaves the guide as is.

Acceptance: a pure `ZoomMarketplaceWindowPlacement.frame(screen:)` is tested for 1440x900, 1920x1080, 2560x1440, small and offset screens; manual test: Developers opens in place.

### R2. The page is understood

Status: built (`ZoomMarketplacePagesTests`).

The pure `ZoomMarketplacePages.page(for: URL) -> ZoomMarketplacePage?` maps an address to:
`.createdApps`, `.chooseType(draftID)`, `.s2s(appID, tab)` with tab ∈ information, credentials, feature, scopes, activation, `.general(appID, tab)` with tab ∈ information, embed, scopes or other, or `.signIn` (zoom.us/signin, accounts.google.com and the like), or nil for anything else.
- Only `https://marketplace.zoom.us` counts as Marketplace. Look-alike hosts are nil.
- IDs must match `[A-Za-z0-9_-]{10,40}`.

Acceptance: table tests covering each probe address above, query strings, trailing slashes, `marketplace.zoom.us.evil.com`, `http://` and an over-long ID.

### R3. The guide follows along

Status: built (`ZoomGuideFollowRulesTests`). A Hosting app page `information` or `feature` marks no step. "Unsaved typing" means some but not all of the part's fields are filled.

When the window shows a page, the matching guide part opens and its step list marks the current step:
- Meeting app: 1 choose General app (chooseType or createdApps), 2 turn on Meeting SDK under Embed (general/embed), 3 keys (general/information).
- Hosting app: 1 choose Server to server OAuth app, 2 add the scopes (s2s/scopes), 3 activate (s2s/activation), 4 keys (s2s/credentials).

The pure `ZoomGuideFollowRules.step(part:page:)` decides the step. A page of the other kind does not move the guide to a different part while that part has unsaved typing.

Acceptance: table tests for every page × part.

### R4. Every step links to its exact page

Status: built (round trips in `ZoomMarketplacePagesTests`, rows in `ZoomGuideFollowRulesTests`).

Once the window has seen an app of a kind, Greenroom remembers its ID for that part. Each step row then gets a small button:
- Meeting app: **Open Embed** (`/develop/applications/<id>/features/sdk`) and **Open Basic information** (`…/information`).
- Hosting app: **Open Scopes** (`/develop/apps/<id>/scope`), **Open Activation** (`…/activation`) and **Open App Credentials** (`…/credentials`).

Before an ID is known, step 1's button is **Create the app** (`/user/build`), and the later rows show their words without a button.

The IDs are kept in UserDefaults (they are not secrets) and cleared when the part's keys are cleared. `ZoomMarketplacePages.url(for:)` builds each address and round-trips through `page(for:)`.

Acceptance: round-trip tests for every tab.

### R5. Fill in from this page

Status: built, untested live: the reader script's label lookup and input-order fallback have not run on a real credentials page.

On s2s/credentials or general/information, Greenroom reads the key inputs with a script that runs only on those pages, finding each value by its label (Account ID, Client ID, Client Secret). If the label lookup fails, the probe's input order (text, text, password) is the fallback. A value counts only if it matches `[A-Za-z0-9_-]{10,64}`.
- If the part's Greenroom fields are empty, they are filled straight away, and the part says "Filled in from Zoom" with Undo.
- If any field already has a different value, the part shows **Use the keys from this page** instead, and nothing is overwritten without that click.
- Values go into the same bindings as typing (so the same Keychain save path). They are never logged, never put in the window's title and never sent anywhere else.

Acceptance: pure `ZoomKeyFillRules.decide(current:found:)` tests (empty → fill, same → nothing, different → offer, a partial read → offer only the found fields), and `ZoomMarketplacePages.isKey(_:)` tests; a source scan that the reading code has no `print`, `log` or `NSLog` near the values.

### R6. A coach on Zoom's page

Status: built (rules and script scan tested, off-screen render done); untested live on real Marketplace pages (label matching, the search-field case, following the target).

On each guided page the Zoom window draws a coach on top of the page: the rest of the page dims (about 45% black), the target control sits in a clear rounded spotlight with a 2pt `Brand.green` ring, and a callout card beside it (system font, rounded 12pt, light and dark through `prefers-color-scheme`) says what to do in one line, with a step counter: "Step 1 of 4 · Choose Server to server OAuth app, then press Create." Every card's header row carries the Greenroom mark (about 16pt, the small-size app icon as a data-URI PNG made at runtime from the app's icon, never an address, in its own colours), "Greenroom" in semibold, and " \u00B7 Step 1 of 4" in secondary; cards with no counter (Find my app, Got it) show the mark and "Greenroom" only, so the tip is plainly Greenroom's, not Zoom's. The card has **Hide tips**, which turns the coach off for this setup; the toolbar's **Tips** toggle turns it back on.
- Targets, found by visible label text (never by Mui class names): chooseType: the "Server to server OAuth app" or "General app" row (per guide part), then Create; s2s/scopes: "+ Add Scopes" (and while the Add Scopes panel is open, its search field, with the card saying "Paste one scope, tick it, repeat. Copy scopes is in the guide."); s2s/activation: the Activate button; general/embed: the Meeting SDK toggle; credentials pages: no spotlight, only a small card "Got it: the keys are in Greenroom." once R5 has filled.
- It never clicks, never takes focus and never blocks: the dim layer and the card are `pointer-events: none` except the card's own Hide tips link, so clicks go straight to Zoom's page. It follows the target on scroll and resize, moves when the page changes route, and simply disappears if the target is not found.
- It is drawn inside the page in a closed shadow root on one fixed-position host with a very high z-index, so Zoom's CSS cannot break it and it cannot break Zoom's. It respects `prefers-reduced-motion` (no animated movement); otherwise a 200ms ease.
- Which label and card text for (part, page, step) is the pure `ZoomCoachRules`; the script is a constant (`ZoomCoachScript`) and its card text comes from Swift as JSON, never from the page.

Acceptance: `ZoomCoachRules` table tests; a scan that the script is a closed shadow root, `pointer-events: none`, reduced-motion aware and has no click, focus, dispatch, network or console call; an off-screen render (`scripts/render/zoom-coach.sh`) of the real script on a static mock page; manual: the ring sits on the right radio on a real Marketplace page.

### R7. Check runs by itself

Status: built (`ZoomCheckActionTargetTests`); the auto check is untested live. Failed-line buttons open the Zoom window.

When the last key of both parts becomes filled through R5 and no session is live, Check Zoom setup starts once by itself. Every failed check line that names a Marketplace place links straight to it through R4 (a missing scope goes to Scopes, a not-activated app to Activation, wrong keys to App Credentials).

Acceptance: `ZoomCheckActionRules` tests for the new targets.

### R8. Safari stays available

Status: built (Open in Safari is always in the toolbar; a failed load says so there). No sign-in error page is detected specially.

If the window shows a sign-in error page or the person prefers it, Open in Safari opens the same address. The guide's steps keep their words, so the flow still works by hand.

### R9. Words and docs

Status: built (docs, glossary, codemaps, renders).

The steps in `ZoomMarketplaceGuide` are shortened to match R3. docs/zoom-setup.html and docs/guide.html describe the Zoom window and the fill-in. GLOSSARY gains "Zoom window". The codemaps are updated. scripts/render/zoom-guide.sh gains states: no ID known, IDs known with the current step marked, filled in from Zoom, and the offer to use the page's keys; light and dark. scripts/render/zoom-coach.sh renders the coach.

### R10. Start over

In the Zoom step, whenever any Zoom key is filled, a quiet "Start over\u2026" button (plain, not green) sits under the three parts. It asks "Remove your Zoom keys from Greenroom?" with "Greenroom forgets both apps' keys on this Mac and signs out of Zoom here. Your apps in Zoom stay as they are, and you can fill the keys in again from Zoom.", buttons **Remove keys** (destructive) and Cancel. Remove keys clears all five key bindings (the secrets leave the Keychain through the same save path typing uses; an empty value removes the item's key, pinned by `SecretStoreTests.testSettingEmptyRemoves`), both remembered app IDs, the last check, the "Filled in from Zoom" / Undo state, signs the Zoom window out (Sign out of Zoom) and opens part 1. It is disabled while a meeting or session is live, with "End the meeting first." Settings \u2192 Zoom shows the same button (when a key is filled) beside Set up / Edit setup, through one shared view and one action (`ZoomStartOverButton`, `ZoomSetupAssist.startOver`).

Acceptance: `ZoomStartOverRulesTests` (shown when any key, words, disabled help, the five fields).

Status: built; the confirmation dialog is untested live (it cannot be rendered off screen).

### R11. Each part: Use a different app

In an open part that is Done, a small plain "Use a different app" link under the fields clears only that part's keys and remembered app ID, shows "Keys removed \u00B7 Undo" for that part until the next change, and opens the Zoom window at Created apps. The page that was open cannot fill the keys straight back.

Status: built, untested live.

### R12. Done but no app ID known: Find my app

When a part's keys are filled (any of them) but its app ID is not remembered, step 1's button reads **Find my app** (Created apps) instead of "Create the app", and on Created apps the coach card (no spotlight, no counter) says "Click the app you made for Greenroom." Opening the app remembers its ID, and the R4 buttons appear. Only when the part's keys are empty does step 1 say "Create the app".

Acceptance: `ZoomStartOverRulesTests` (rows and coach).

Status: built, untested live.

### R13. The Greenroom bar

One native SwiftUI bar (about 44pt) above the web view, replacing the old toolbar. Content from the pure `ZoomBarRules` (same page and step facts as the guide and the coach). Left: "Hosting app \u00B7 Step 2 of 4 \u00B7 Add the scopes"; before an app page is known "Hosting app \u00B7 Find or create the app"; signed out or on a sign-in page "Sign in to Zoom". Contextual: on the Hosting scopes step **Copy scopes** (the guide's text, with a brief "Copied"); on a credentials page of a complete part "<Part> is set up" with a green check; while signed out **Sign in** (opens Created apps, which Marketplace redirects to its sign-in; Greenroom never presses Zoom's own Sign In). Primary: when a part is complete on its credentials page, **Next: <other part>** (Created apps, or the other app's known page: Meeting app's Basic information, Hosting app's Scopes); when both parts are complete, **Back to Greenroom**, which closes the Zoom window, brings the guide forward and starts Check Zoom setup unless it is running or has results (`shouldCheckOnReturn`, so R7's auto check never runs twice). Right: Back, Forward, Reload, Tips and the "..." menu. It is a plain stack (never an overflow chevron); at the 900pt minimum the fixed parts take about 520pt and the title truncates at its tail.

Status: built; rules tested (`ZoomBarRulesTests`, `ZoomSignInStateRulesTests`); off-screen renders (`scripts/render/zoom-bar.sh`); untested live.

### R14. Connect Zoom, one button

The guide's Zoom step is calm: title and one line; ONE large button, "Set up Zoom" / "Continue setup", opening the Zoom window on the first unfinished part (Created apps, or the remembered app's next page); one status line per part (mark, name, state words or the window's "Step n of N", and when done "Use a different app" and a "..." menu of that app's page shortcuts, only for known IDs); the Check row once both parts are done (or a check has run); a folded "Enter the keys yourself" with each part's steps as text, the key fields, the scope checklist and "Show me each click", which deep links (`.sdkCredentials`, `.s2sCredentials`, `.s2sScopes`, `.s2sActivation`) unfold and scroll to; a quiet footer (Import, Start over\u2026, Sign in with Zoom Coming soon). "Filled in from Zoom \u00B7 Undo", the offer to use the page's keys and "Keys removed \u00B7 Undo" show on the part's status line. Settings' button reads "Set up Zoom\u2026" / "Continue setup\u2026" / "Edit setup\u2026" and opens the step's top. Pure: `ZoomConnectRules`, `ZoomGuideFlowRules.setupEntry`.

Status: built (`ZoomConnectRulesTests`); renders in `scripts/render/zoom-guide.sh`. R4's row buttons and R12's "Find my app" step button no longer have a place on screen (the steps are text in the manual route); the rows rule stays tested, and Find my app lives on in the coach card on Created apps.

### R15. Created apps is a coached step; passkeys; diagnosis

Owner live test, 2026-11-27: the window opened on Created apps and no coach appeared. Cause found in the code: `ZoomCoachRules` had no case for `createdApps` (it returned nil unless the keys were filled but no app ID was known), so there was nothing to draw; the script, the closed shadow root and the `.defaultClient` world were not at fault. Other things made safer: the coach script now answers with a status word (`drawn`, `no-target`, `cleared`), the mark image hides itself if a page's CSP refuses the data URI, and DEBUG builds append script errors, the coach call's result and the page kind (never page text, IDs or values) to `~/Library/Logs/Greenroom/zoom-window.log`. The host element re-attaches itself if Zoom's page removes it, and a mutation observer redraws when a target appears late (both already in the script).

- Created apps is always coached. A read-only scan (`ZoomAppListScript`, shared with the coach so a row index means the same in both) lists the table rows' **Type** text only (never an app's name; found by the "Type" header, with the known type words as the fallback). `ZoomCoachRules` decides: exactly one row of the part's type (Meeting app: General app; Hosting app: Server-to-Server OAuth, hyphens optional) spotlights that row, "This is your Meeting app. Click it." (Hosting likewise); several spotlight the first, "Click the General app you made for Greenroom." (or "\u2026the Server-to-Server OAuth app\u2026"); none spotlights the round + button (by an aria-label or title with build, create or add, else the button after the "Developer" heading), "Press + to build your Meeting app." The header stays the mark, "Greenroom" and "Step 1 of N". (The brief's `idKnown` input was not needed: the rows say what to do.)
- The bar on Created apps says "Meeting app \u00B7 Find your app" when a matching row exists, else "Meeting app \u00B7 Create the app".
- Passkeys cannot work in this window (WebAuthn for other sites needs Apple's web-browser entitlement). Google's passkey challenge (`accounts.google.com/.../signin/challenge/pk`, `/presend`, `/error`) is its own page kind, `.passkey` (exact host only; Zoom's own passkey page was not identified). The coach says "Passkeys don't work in this window. Press Try another way and use your password, or sign in in Safari.", spotlighting "Try another way" if found by its exact text and showing the card alone if not. The bar says "Sign in to Zoom" with **Open in Safari** as its contextual button. The coach also runs on accounts.google.com; it never clicks and reads only the button's text match.

Acceptance: `ZoomCoachRulesTests`, `ZoomBarRulesTests`, `ZoomMarketplacePagesTests`, `ZoomSignInStateRulesTests` (rows, matching, passkey pages); mock renders in `scripts/render/zoom-coach.sh` (Created apps with two rows, no match, passkey page; through the real scan).

Status: built; the real Created apps table and Google's real passkey page are untested live (the mocks follow the structure the owner described).

### R16. Do this step

Owner decision, 2026-11-27 (A). The coach card gets a green **Do this step** button next to Hide tips, only on four steps, with a small secondary line saying what it will do first ("Greenroom will press + \u2192 Build, choose General app and press Create."). One press runs that step only; while it runs the button and the bar say "Working\u2026"; afterwards the card says what happened (`ZoomActorRules.message`) and the coach moves on as usual.
1. Created apps / the chooser: press + (only if the dialog is not open), press the menu's Build, choose the part's radio, press Create; stop there.
2. Hosting app, Scopes: for each of the eight scopes not already on the page, type its exact name into the panel's search field (native value setter and an input event, so React sees it), wait for the result, tick the checkbox of the row holding that exact string, clear the search; then press Done (else Save, else Continue, else stop: "Press Done to save the scopes."); then verify every scope is visible on the page and report "Added 8 scopes." or "Added 6 of 8; couldn't find X, Y: add them by hand (Copy scopes is in the bar)."
3. Hosting app, Activation: press Activate / Activate your app; verify the page shows an activated state.
4. Meeting app, Embed: turn on the Meeting SDK switch if it is off; verify it is on.

Safety, in one place: `ZoomActorRules` (pure, table tests) holds each step's allow-list of exact labels and the deny-list, which wins even over an allowed label. The page script (`ZoomActorScript`) gets those lists as arguments and has exactly ONE call that clicks; every press is matched to the allow-list first. It touches no input except the scopes panel's search field, never runs on a credentials or Information address, runs only on the person's press, waits about 5s per action for its expected result and stops on any surprise. Each action is logged in DEBUG to `zoom-window.log` as `step:scopes click done ok` (allow-list labels only, never values or app names).

Related coach behaviour (same round): each in-page step has a done state that moves the coach on without an address change (the Meeting SDK switch on \u2192 Basic information; all eight scopes visible \u2192 Activation; activated \u2192 App Credentials); an open dialog is exclusive (the coach points only inside it, otherwise shows the card alone beside it, "Finish this window first."); the name dialog ("Create a Server-to-Server OAuth app" / "Create a General app") spotlights the App Name field while empty (only whether it has text is read) and then Create; and the part follows the type a dialog names or the person picks (`ZoomCoachRules.part(forHeading:)`, `partFollowing`).

Acceptance: `ZoomActorRulesTests`, `ZoomCoachRulesTests`, `ZoomBarRulesTests`; the dry-run harness `scripts/render/zoom-actor.sh` (the real scripts against mock Zoom pages in an off-screen web view, each with Regenerate / Delete / Deactivate buttons that must stay unpressed; exits 1 on a failure).

Real DOM checked, 2026-11-27 (DEBUG dump, look-only commands, this account): Created apps is a real table (th/td; Type cell "General app User Managed"); the table fills late (hence rows=0 then rows=1), so the window now looks again for 15s. The round + is `button[aria-label="Add"]`; its menu item reads "Build app" (not "Build"); the type dialog is a MUI Dialog (`role=dialog`) with `label > span > input[type=radio]` cards and Create (disabled) / Cancel. The General app's Embed page lists checkboxes (`span > span > input[type=checkbox]`, no role=switch, no aria-label), "Meeting SDK" being one; the left nav links are plain `a` (not in a `nav`): Basic information, Access, Surface, Embed, Connect, Custom Form, Scopes. The scopes page's button reads "Add scopes"; its panel is a MUI Dialog with a "Search scope" input, product tabs, result rows `li > div[role=button]` each holding a `span > input[type=checkbox]` and the exact scope string in `p > span` (a header row without a checkbox comes first), and a "Done" button plus an unlabelled close icon. A Draft General app's Basic information shows the Client ID as plain text in a sibling div (not an input), and no Client Secret. Not seen (this account has no Server-to-Server app): the S2S Scopes, Activation and App Credentials pages, and what happens after ticking a row (a click on the checkbox inside a role=button row might toggle twice; the actor verifies and reports instead of guessing).

Status: built; the harness passes on mocks that now follow the real markup; steps 2 and 3 are untested on a real Server-to-Server app, and no step has been pressed on the real account. DEBUG-only tools for that: `-zoomDomDump YES` writes the page's control structure (never values) to `~/Library/Logs/Greenroom/zoom-dom.jsonl`; `-zoomWindowURL <url>` opens the Zoom window at a marketplace.zoom.us page.

### R17. One continuous run, and the keys

Owner decisions, 2026-11-27. The Zoom window's setup is ONE run of seven steps across both apps, numbered from one source (`ZoomRun`): 1 Create the meeting app, 2 Turn on Meeting SDK, 3 Copy its keys, 4 Create the hosting app, 5 Add the permissions, 6 Turn it on, 7 Copy its keys. The bar reads "Step 5 of 7 \u00B7 Add the permissions" (steps 3 and 7 add the app name, as the only place a name does not say which app); the coach card's header carries the same counter and its text carries no part prefix. After step 3 the bar's primary is **Continue** (straight to step 4: Created apps, coached for the hosting app), after step 7 **Back to Greenroom**; when the Meeting app is already done the window starts at step 4. The guide's Connect Zoom list stays two lines (it shows "Step n of 7" on the app the window is on) and its button stays Set up Zoom / Continue setup.

Keys: labels match case-insensitively (Zoom writes "Client secret"). The reader takes a key shown as plain text beside its label (Basic information's Client ID); a text that ends with an ellipsis is not readable; reveal, eye and show buttons are never pressed. Zoom does not put the secret in the page (dots only), so the person presses Zoom's own copy button and Greenroom picks the copied text up from the clipboard: while a credentials page is shown and for 60s after, a new clipboard string that is key-shaped and not a key already known is assigned to the missing field the coach points at (`ZoomClipboardRules`), through the same fill, offer and Undo path as a page read; it is never logged or kept. On credentials pages the coach always speaks: a missing key spotlights its row, "Hover Client secret and press its copy button. Greenroom fills it in."; all keys known, "Got it: the keys are in Greenroom."; no "Do this step" there.

Status: built (`ZoomClipboardRulesTests`, `ZoomGuideFollowRulesTests`, `ZoomBarRulesTests`, `ZoomCoachRulesTests`; the reader and the credentials coach on a mock of the real card in `scripts/render/zoom-actor.sh`); the clipboard pickup and the continue flow are untested live.

### R18. Zoom's own order, and the check as the judge

Owner live test, 2026-11-27. Zoom opens `/develop/apps/<id>/credentials` first after creating a Server-to-Server app (its wizard order is App Credentials, Information, Feature, Scopes, Activation), and the run had wrongly called the app "set up" with no scopes and no activation. Now: the run has eight steps in Zoom's order (`ZoomRun`, one source): 1 Create the meeting app, 2 Copy its keys (Basic information comes first on a General app), 3 Turn on Meeting SDK, 4 Create the hosting app, 5 Copy its keys, 6 Fill in Information (the Feature page counts as 6: just Continue), 7 Add the permissions, 8 Turn it on.

Keys in is not done. An app is **set up** only when its keys are complete AND the latest Check Zoom setup passed for that app (`ZoomRunRules.passed`): the Meeting app's line is `sdk`, the hosting app's are all the others. A part's keys becoming complete starts the check by itself (not in a session, not twice), and it re-runs after each completed Do this step and when the person leaves a fixed place, until it passes (`shouldCheckAfterKeys`, `shouldRecheck`). A failed line is the current step (`ZoomRunRules.fix`): missing scopes, Scopes ("Add 8 missing permissions"); a refused token, Activation; Meeting SDK off, Embed; missing keys, the credentials page. The bar and the guide's status line show it ("Step 7 of 8 \u00B7 Add 8 missing permissions") and Continue goes there when it is behind the person; a fix still ahead waits its turn, so Continue follows Zoom's order. "\u2713 set up" never shows while the latest check for that app has failures; Back to Greenroom shows only when both apps passed. A part showing "Needs a fix" requires some of its keys to be filled in.

Status: built (`ZoomRunRulesTests`, `ZoomBarRulesTests`, `ZoomGuideFollowRulesTests`, `ZoomCoachRulesTests`); the loop is untested live.

### R19. Do this step on every step, and the real credentials pages

Owner live tests, 2026-11-27. **Name dialog:** Do this step carries on through Zoom's name dialog in the same press (+ \u2192 Build app \u2192 type \u2192 Create \u2192 name \u2192 Create), typing "Greenroom Hosting" / "Greenroom Meeting" only in a dialog headed "Create a Server-to-Server OAuth app" / "Create a General app" (that name field is the one input the actor may type into besides the scope search; a name the person typed is kept). The plan line, the button and the result line belong to the CURRENT stage: when the coach moves on, the old result is cleared and the new stage's own plan shows (`ZoomCoachStage.action`, `.plan`).

**Keys:** the reader takes each value from the nearest following input of its label (read-only or disabled inputs included; case-insensitive), under the "App Credentials" card in the probe's order as the fallback, and logs only how each field was read ("read accountID=input22;clientID=missing"). If a value truly cannot be read, the coach spotlights that row's own **Copy** button ("Press Copy next to Account ID. Greenroom fills it in."; "Hover \u2026" stays only for the General app card, where copy appears on hover), and the card never covers any row's field (beside the group, else below it). Do this step on a keys page reads the keys, then presses each missing key's own Copy control (a mouseover on the row first, for hover-only controls; reveal, show, eye and view are never pressed; a Copy inside a Regenerate control is denied) and picks the key up from the clipboard, then puts the clipboard back as it was (cleared if it was not plain text). On Server-to-Server Information and Feature: if a required field is empty the coach spotlights it ("Fill in <label>, then press Continue."; nothing is typed), else Do this step presses Continue.

Status: built (`ZoomActorRulesTests`, `ZoomCoachRulesTests`, `ZoomKeyReaderScriptTests`; the actor harness covers a mock of the S2S credentials rows, the hover card, the Information page and the name dialog); untested live (the real S2S pages were not reachable from this account when checked).

## Plan

1. Pure rules first, red then green: R2, R4 URLs, R3, R5 decide, R1 placement, R7.
2. The window (R1, R6, the R5 reader), modelled on the probe.
3. Guide wiring (R3–R5, R7) through `OnboardingView`, with plain values and closures so the renders still work.
4. Docs, renders, the full check, then an owner live test with a fresh Server-to-Server app.
