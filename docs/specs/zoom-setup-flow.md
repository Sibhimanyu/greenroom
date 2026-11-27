# Zoom setup flow, redesigned (v2)

Branch: feat/zoom-setup-assist. Replaces the patchwork in R1–R20 of `zoom-setup-assist.md` (keep that file as the record of what Zoom's pages taught us). Decision record: `docs/adr/0003-one-setup-flow.md`. Owner, 2026-11-27: "you seem to overcomplicate this whole flow … go proper arch", "this should be a comprehensive guide", "test the whole flow".

## Problem

Twelve small rule files (Coach, Bar, Follow, Run, Connect, GuideFlow, MarketplaceGuide, CheckAction, StartOver, SignInState, Clipboard, Actor) each decide "which step is this and what should the person do", and six page scripts each read Zoom's page their own way. They disagree: the guide said "Needs a fix" while the bar said "set up ✓"; the counter drifted; a card had no action. The step is derived from the current address, so in-page flows (menus, dialogs) and Zoom's own tab order broke it every time. No test runs the whole flow.

## The shape

Three modules, one seam.

```
            ┌──────────────── ZoomSetupFlow (pure, deep) ────────────────┐
 facts ───► │ step(for: SetupFacts) -> SetupStep                          │ ───► guide, bar, coach
            │ absorb(snapshot, into: Evidence) -> Evidence                │      (render only)
            └─────────────────────────────────────────────────────────────┘
                     ▲ snapshot                         │ ActionPlan
            ┌────────┴────────┐                ┌────────▼────────┐
            │  ZoomPage seam  │◄───────────────│   ZoomActor     │
            │ read() snapshot │   perform/verify│ runs one plan   │
            │ draw(coach)     │                └─────────────────┘
            │ perform(step)   │
            └─────────────────┘
          adapters: WKWebView page (real) · FixturePage (recorded, tests)
```

**ZoomSetupFlow** is the only place that knows the steps. Its interface is two functions:

- `absorb(_ snapshot: ZoomPageSnapshot, into: Evidence) -> Evidence`: what this page proves (an app's ID, its keys, Meeting SDK on, the scopes present, activated, Information complete). Evidence only grows, except when the check or a page shows it's no longer true (for example a scope is removed).
- `step(for: SetupFacts) -> SetupStep`, where `SetupFacts` = evidence + the keys stored in Greenroom + the latest check per app + the current snapshot. The step is **the first step in the table below that isn't done**. It comes from evidence and checks, never from the address alone, so moving around Zoom never loses progress.

`SetupStep` is everything any surface shows: number and total, title, the app, one-line why, where it happens (a `ZoomPlace`), a status line, and exactly one call to action.

`CallToAction` is one of:
- `.goTo(place)`: "Take me there" (Greenroom loads the address itself; navigating is not clicking);
- `.doThisStep(plan)`: Greenroom does it, after one press;
- `.press(control, text)`: the person presses a spotlighted Zoom control (sign-in, terms, anything not on the allow-list);
- `.fill(control, text)`: the person types something only they know (an email Zoom didn't pre-fill);
- `.wait(text)`: a check or a page load is under way, with Continue still offered;
- `.checkAgain`;
- `.backToGreenroom`.

A step with no action can't be expressed.

**ZoomPage** is the seam. `read() -> ZoomPageSnapshot` is one script that reports everything the flow needs as plain data: the address kind, the open dialog and its state, visible menu items, the app list's types, the Meeting SDK switch, the scopes on the page, the activation state, Information's empty required fields, each key as value / copyable / hidden, and which known controls are present. Controls are named by `ZoomControl` IDs (`plus`, `buildApp`, `typeRadio(.hosting)`, `create`, `nameField`, `addScopes`, `scopeSearch`, `scopeCheckbox(name)`, `scopesDone`, `activate`, `continue`, `copy(.clientSecret)`, `navLink(.embed)` …), and one JS finder resolves every ID. The coach and the actor refer to IDs, never to labels. `draw(_ coach: CoachDrawing)` and `perform(_ step: ActorStep) -> Bool` complete the interface. Two adapters: the WKWebView page, and `FixturePage`, recorded snapshots that change as scripted actions happen. Two adapters, so it's a real seam.

**ZoomActor** runs an `ActionPlan` (`[press(id) | type(id, text) | waitFor(predicate)]`) against a `ZoomPage`. After each action it reads again and verifies; on any surprise it stops and returns what happened. The allow-list is the set of `ZoomControl` IDs a plan may name. The deny-list (regenerate, delete, remove, deactivate, disable, submit, publish, agree, accept, terms, sign out, uninstall) is checked on the resolved element's text at the moment of the press and always wins.

Deleted when v2 lands: ZoomCoachRules, ZoomBarRules, ZoomGuideFollowRules, ZoomRunRules, ZoomConnectRules, the step rows in ZoomMarketplaceGuide, ZoomStartOverRules' coach text, ZoomFinderScript, ZoomDialogScript, ZoomAppListScript, ZoomKeyReaderScript, ZoomSignInHeaderScript, and the coach's own finders. The kept parts: ZoomMarketplacePages (addresses), ZoomActorRules' deny-list, ZoomClipboardRules, the check (ZoomSetupChecker), and the window shell.

## The guide: every step

One run, eight steps. Each app is built completely first and its keys are copied LAST (owner, 2026-11-27: Zoom can change an app's keys as its settings change, so keys copied early go stale). Zoom shows a Server-to-Server app's App Credentials tab first; Greenroom takes the person past it (`.goTo`) and comes back at the end. "Done when" is the evidence. A check failure re-opens the step it names.

| # | Step (card title) | Why (card's second line) | Where | Done when | Call to action | Do this step does |
|---|---|---|---|---|---|---|
| 0 | Sign in to Zoom | Greenroom works in your own Zoom account. | any sign-in page | snapshot says signed in | `.press(signIn)` / passkey page: `.press(tryAnotherWay)` | nothing: sign-in is yours |
| 1 | Create the meeting app | It lets Greenroom join and run meetings. | Created apps → + menu → app type dialog | a General app's ID is in evidence | list has a General app: `.press(appRow)` "Use this app" (or build a new one); else `.doThisStep` | + → Build app → General app → Create (Zoom names it) |
| 2 | Turn on Meeting SDK | Without it Zoom won't let the app join meetings. | general/embed | switch on | `.doThisStep` | turns the switch on, verifies |
| 3 | Copy its keys | Greenroom signs in to meetings with them. Copied last, so they're the final ones. | general/information | Client ID + Secret stored and equal to the page's ID, read after step 2 | `.doThisStep` | reads Client ID; presses the secret row's copy control; takes it from the clipboard, then restores the clipboard |
| 4 | Create the hosting app | It lets Greenroom create and start your meetings as host. | Created apps → dialogs | an S2S app's ID is in evidence | `.press(appRow)` "Use this app" if one exists, else `.doThisStep` | + → Build app → Server to server OAuth app → Create → types "Greenroom Hosting" → Create |
| 5 | Fill in Information | Zoom asks for a contact before it turns the app on. | s2s/information (Zoom opens App Credentials first: `.goTo` Information) | no required field empty (Short Description, Company Name, Developer contact Name, Email) and Activation lists nothing missing | `.doThisStep` after the person confirms the values in the bar's small form | types the confirmed values into the empty required fields only, then presses Continue |
| 6 | Add the permissions | These eight let Greenroom create, list, start and end meetings. | s2s/scopes | all eight on the page, or the check passes scopes | `.doThisStep` | Add scopes → for each missing one: search, tick → Done; verifies all eight |
| 7 | Turn it on | Zoom only answers an app that's switched on. | s2s/activation | activated | `.doThisStep` | presses Activate, verifies |
| 8 | Copy its keys | Greenroom uses them to talk to Zoom for you. Copied last, so they're the final ones. | s2s/credentials | Account ID, Client ID, Secret stored and equal to the page, read after step 7 | `.doThisStep` | reads the three fields; presses Copy where a value can't be read |
| ✓ | Check | Makes sure both apps really work. | — | both apps' checks pass | `.wait("Checking…")`, then a failure re-opens its step; all pass: `.backToGreenroom` | runs the check |

Rules that apply to every step:
- **Away from the step's place,** the action is `.goTo(place)` ("Open Embed", "Open Scopes"). The person is never stranded.
- **A dialog open on the page** that belongs to the step (app type, name, Add scopes) is part of the step. Any other dialog: `.press(close)` "Close this window to carry on".
- **The app the person picks wins.** If they choose or open the other type, the evidence goes to that app and the step follows.
- **Existing apps:** on Created apps, a row of the needed type gives "Use this app"; opening it records its ID. Keys already stored for a different app: step 2/5 shows "Use the keys from this app" (`.doThisStep` replaces them, with Undo), never silently.
- **The check runs by itself** when an app's keys are copied (steps 3 and 8), and again after any fix. It never blocks Continue.
- **Card layout:** title (the action, imperative) · why line · status line, if any · the single action button. The bar shows "Step n of 8 · title" and the same action.

### Step 5's values (owner, 2026-11-27)

Zoom's Information page requires Short Description, Company Name, Developer contact Name and Email (red "This field cannot be empty"), and Activation then says "Your app can not be activated yet due to missing the following information: 1. Developer contact name 2. Developer contact email 3. Company name". Greenroom fills them:
- Short Description: "Lets Greenroom create, start and host my Zoom meetings."
- Name and Email: read (read-only) from the signed-in Zoom profile page (zoom.us/profile in the same data store, a hidden second web view, never clicking); else the Mac account's full name (`NSFullUserName()`) and an empty email the person must type.
- Company Name: the person's name unless they change it.
- The Greenroom bar shows these in a small native form (editable) with the step's Do this step; nothing is typed into Zoom before that press. Only empty required fields are typed into; a field the person already filled is kept.
- The snapshot reports Information's required fields (label → empty / filled / error) and Activation's "missing" list; a non-empty missing list re-opens step 5 naming the fields.

## Testing

- **Flow table tests:** `step(for:)` for every row above and every failure mapping (keys wrong → 3/8, Meeting SDK off → 2, scopes missing → 6, not activated → 7, signed out → 0). Keys read before the app's last settings step don't count: evidence records the keys' reading time against the app's last change, and a later change re-opens the keys step.
- **Whole-flow replay tests:** `FixturePage` scripted with snapshots recorded from the real Zoom pages. One test drives a brand-new setup from step 0 to Back to Greenroom by pressing each step's action. One starts with existing apps, one with a failing check, one where the person picks the other app type. These are the "test the whole flow" tests and run in `scripts/check.sh`.
- **Recorder:** a DEBUG `-zoomRecord` mode saves each `ZoomPageSnapshot` (key values replaced by their kind and length) to `Tests/Fixtures/zoom/`, so fixtures come from real pages and can be refreshed when Zoom changes.
- **Live end-to-end run** on the test account (Sibhi -8A): a fresh General app and a fresh S2S app, every step through Do this step, ending in a passing check. Recorded as above. Done by the parent agent, with the owner told what it creates.

## Plan

1. Record: build the snapshot reader and the recorder first, then run the live end-to-end flow on the test account with the current coach turned off, capturing every page and dialog. The fixtures are the ground truth.
2. `ZoomSetupFlow` + `ZoomControl` + `CallToAction`: pure, table tests first.
3. `ZoomPage` seam with the WKWebView and fixture adapters; `ZoomActor` on top; whole-flow replay tests.
4. Rewire the guide, bar and coach to render `SetupStep`; delete the modules listed above.
5. Live end-to-end run again on fresh test apps, then the owner tries it.
