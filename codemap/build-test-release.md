# Build, test, release, site, branding

Purpose. Greenroom is built from `project.yml` with XcodeGen (`Greenroom.xcodeproj` is generated and
gitignored). There are three targets/schemes: `Greenroom` (the app), `GreenroomTests` (a unit-test bundle
that compiles only the pure source files it tests, no host app, no Zoom SDK), and `CuesBench` (a command-line
scorer for the Cues word-pattern detector). Releases are cut from `main` by `scripts/release.sh` (Sparkle
EdDSA-signed zip + `docs/appcast.xml` + GitHub Release, optional DMG). `docs/` doubles as the public
website (GitHub Pages) and the home of plan/design `.md` files.

## Files

| Path | What it owns | Key contents |
|---|---|---|
| `project.yml` | XcodeGen spec: targets, SPM packages, build phases, version | `MARKETING_VERSION` (1.8.1), `CURRENT_PROJECT_VERSION` (42), packages `Sparkle` (>=2.6.0), `Apptics` (exact 3.3.17, product `AppticsAnalyticscoreWithKSCrash`), `Heresay` (>=0.2.14); `DEVELOPMENT_TEAM`; `XCODE_EMBEDS` list; pre/post build scripts |
| `Greenroom.xcodeproj/` | GENERATED, gitignored. Never edit or commit | recreate with `xcodegen generate` |
| `Vendor/ZoomSDK/` | Proprietary Zoom Meeting SDK 7.1.5.84750 (~600 MB, gitignored, a SYMLINK in worktrees) | `ZoomSDK.framework` + ~80 siblings |
| `Vendor/README.md` | How to obtain the SDK; the two Marketplace apps (General/Meeting SDK + Server-to-Server OAuth) and 7 S2S scopes; same-account-only limitation | |
| `Vendor/Apptics/` | Verbatim Apptics 3.3.17 helper scripts (`scripts/run`, `dsym_upload`, `sdk_info`...) run as a pre-build phase | `README.md` explains why vendored |
| `apptics-config.plist` | LIVE Apptics API key, gitignored, rewritten by builds (`APP_VERSION_META`) | template: `apptics-config.plist.example` |
| `Bench/` | `CuesBench` tool sources | `main.swift` (detector + resolver scoring), `Console.swift` (participant-window priority-ladder checks), `Resolver.swift`, `fixtures/detector.json` |
| `Tests/` | 59 XCTest files (~7.9k lines), `GreenroomTests` target | see "Tests" below |
| `scripts/release.sh` | Whole release ritual | `release.sh <version> <notes-file>` |
| `scripts/make-dmg.sh` | Drag-to-install DMG (plain by default; `GREENROOM_DMG_STYLE=styled` needs create-dmg + Pillow) | geometry paired with `scripts/dmg-background.py` |
| `scripts/dmg-background.py` | Renders `Branding/dmg-background.tiff` (620x400, 1x+2x) | `python3 scripts/dmg-background.py Branding/dmg-background.tiff` |
| `scripts/site-download-link.sh` | Repoints every Download button in `docs/*.html` at a release artifact | `site-download-link.sh <ver> <dmg|zip>` |
| `scripts/cues-bench.sh` | Generates project, builds `CuesBench`, runs it on `Bench/fixtures/detector.json` | `--verbose` lists misses/false alarms |
| `scripts/render/` | Off-screen PNG renders for UI review, no app launch, no focus: `layouts.sh` (Settings -> Layouts states + Preview: Everyone), `home-panels.sh` (Home's Camera/Screen pop-outs, who-sees icons), `appearance.sh` (light/dark: Home dock, pop-outs, Layouts, meeting bar), `self-view.sh` (the Meeting window's "You" tile in the four camera states, and the Self view window's tile), `meeting-topbar.sh` (the Meeting window's top bar with the share eye at 760, 320 and 1280pt; prints any overlap), `people.sh` (the Participants list, rows under the pointer, the person and footer menus), `stop-video.sh` (Stop video, R49: the bar's camera button per state x stopped, light and dark; the bar's and toolbar's camera menus drawn from their entries; the Meeting toolbar in every camera caption at 760pt and 1100pt (`meeting-toolbar-760-dark`, `meeting-toolbar-dark`); the "You" tile stopped), `zoom-settings.sh` (Settings -> Zoom: Sign in with Zoom Coming soon, the own-apps summary for no own apps, half set up, ready, signed in before; the open sign-in; the check panels; light and dark), `zoom-guide.sh` (the one-button layout: nothing filled, meeting done, both done and checked, a check with a key failure and with missing scopes (manual route open), Filled in from Zoom, the offer, Keys removed, on a step in the Zoom window; zoom-settings.sh shows Start over beside the setup button), `zoom-actor.sh` (dry run of Do this step: the real actor and coach scripts against mock Zoom pages in an off-screen web view, asserting each mock's final state and that Regenerate / Delete / Deactivate are never pressed; exits 1 on a failure; PNGs of the coach before and after), `zoom-bar.sh` (the Greenroom bar in its states at 900 and 1400pt, light and dark), `zoom-coach.sh` (the coach in an off-screen WKWebView on static mocks: the "What kind of app" page, Created apps (two rows, and a no-match one, through the real row scan) and a Google passkey error page; dim, ringed spotlight, card), `youtube-guide.sh` (the setup guide's YouTube step: not signed in, signed in with Greenroom's (folded and open), own app not set up via the deep link, Upload automatically without the answer; light and dark), `youtube.sh` (Settings -> YouTube per account state: Greenroom's app not signed in / signed in / signing in / not available yet / a failed sign-in, your own app not set up / set up and signed in / chosen while signed in through Greenroom's, automatic without the Made for Kids answer; and the upload sheet signed in with and without the answer, not signed in, not available yet; light and dark) (the setup guide's Zoom step: nothing filled in, part 1 done, parts 1 and 2 done, all done and checked, a check with failures; light and dark), `bar-menu.sh` (the bar's camera menu as MeetingMenuPanel draws and measures it, placed by `MenuPanelPlacement` above a bar near the bottom of a screen; prints each menu's size), `scheduled.sh` (Home's My Meetings picker field with the personal room chosen, a meeting chosen and nothing chosen at 360 and 460pt, and the menu's lines (a stand-in list; macOS draws the real menu) with and without the personal room; light and dark). Each compiles the real `App/` views with a `swift/*-main.swift` and stand-ins from `lib.sh` | `scripts/render/<name>.sh [outdir]`, default `$TMPDIR/greenroom-render/<name>`; `RENDER_REF=HEAD` renders the committed sources |
| `scripts/measure-quit.sh` | Measures quit latency end to end (finds DerivedData Debug/Release app) | per-phase log `~/Library/Logs/Greenroom-quit.log` |
| `.github/workflows/static.yml` | GitHub Pages deploy of the repo on push to `main` | |
| `docs/*.html` | Public site: `index.html` (home/download), `how-it-works.html`, `guide.html`, `brand.html`, `timeline.html`, `1.0.html` (the 1.0 launch page, historical) | shared `download-link.js` (finds newest DMG at view time), `sitemap.xml`, `robots.txt` |
| `docs/appcast.xml` | Sparkle feed, regenerated by `release.sh`; served at `https://sibhimanyu.github.io/greenroom/appcast.xml` (= `SUFeedURL`) | latest release only, one `<item>` |
| `docs/release/next.md` | Draft notes for the next release (+ screenshots `docs/release/*.jpg`) | pass a finished notes file to `release.sh` |
| `docs/*-plan.md`, `dead-ends-audit.md` | Design/plan docs: `cues-search-improvement-plan`, `drop-obs-plan`, `glass-redesign-plan`, `participant-window-redesign-plan`, `presence-bubble-plan`, `screenroom-plan`, `stage-and-looks-plan`, `dead-ends-audit` | read the plan before touching its area |
| `docs/recorditor-integration/` | Phased feature port log from Recorditor: `README.md` plus `events/camera/controls/drawing/editor/follow-port-log.md` | keep current |
| `docs/brand/` | Site brand assets (SVG/PNG) | |
| `Branding/` | Logo sources: `greenroom-logo{,-dark}.{svg,png}`, `greenroom-mark.{svg,png}`, `greenroom-mark/` (final mark + guidelines), `dmg-background.tiff`, `brand-sheet.png`, `github-social-preview.png` | regenerate app-icon PNGs from the vector if the logo changes |
| `DESIGN.md` | Design system for BOTH the site (`docs/`) and the SwiftUI app (`App/UI/`): fonts, colours, spacing, motion, "macOS App Mapping", "Open drift to fix", "Decisions Log" | read before any visual change |
| `TODOS.md` | Open items, newest first (mostly "verify live" checklists per feature) | |
| `README.md` | Public readme: features, install, build from source, Cues bench, release | its "Cutting a release" snippet is a manual fallback; real path is `release.sh` |
| `CLAUDE.md` / `AGENTS.md` | Agent rules: gstack skill routing, DESIGN.md rule, Heresay flow | |
| `dist/` | Release outputs (gitignored): `Greenroom-<ver>.zip`, `.dmg` | wiped by each `release.sh` run |
| `.sparkle-tools/` | Sparkle CLI tools (`generate_appcast`, `generate_keys`), fetched on first release, gitignored | |
| `.context/` | Scratch/evidence area (screenshots, one-off scripts); not source. Render harnesses worth keeping go in `scripts/render/` | |

## How it fits

- **Generate + build (app).** From the repo root:
  ```sh
  xcodegen generate
  xcodebuild -project Greenroom.xcodeproj -scheme Greenroom -configuration Debug build
  ```
  Product lands in `~/Library/Developer/Xcode/DerivedData/Greenroom-*/Build/Products/Debug/Greenroom.app`.
  Each worktree has its own DerivedData folder: ask Xcode which with
  `xcodebuild -project Greenroom.xcodeproj -scheme Greenroom -configuration Debug -showBuildSettings | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}'`.
- **Run tests.** The `GreenroomTests` scheme has a `test` action:
  ```sh
  xcodegen generate
  xcodebuild test -project Greenroom.xcodeproj -scheme GreenroomTests -destination 'platform=macOS'
  ```
  (project.yml's comment gives `xcodebuild test -scheme GreenroomTests`). It needs no Zoom SDK and no host app, signing is ad hoc (`CODE_SIGN_IDENTITY: "-"`).
- **Cues bench.** `scripts/cues-bench.sh [--verbose]` (xcodegen + build scheme `CuesBench` + run). No network/mic/model; same input gives same score; put before/after numbers in the commit message when changing the detector. Exit 2 on build failure (judged by xcodebuild exit status, not output grep).
- **Zoom SDK in worktrees.** `.gitignore` has `Vendor/ZoomSDK` WITHOUT a trailing slash on purpose, so a symlink is ignored too. A git worktree never copies ignored files, so link it in:
  `ln -s /Users/sibhi-zstch1643/squeak/repos/greenroom/Vendor/ZoomSDK Vendor/ZoomSDK` (this worktree already has that symlink). Without it the pre-build phase "Check the Zoom SDK is present" fails with an explicit message. The app target needs it; `GreenroomTests` and `CuesBench` do not compile Zoom code (but `scripts/cues-bench.sh` still runs the whole project generation, which is fine without the SDK for those schemes).
- **Build phases of the app target** (`project.yml`): pre: "Check the Zoom SDK is present", "Apptics pre build" (skipped if `apptics-config.plist` missing or still the placeholder key); post: "Copy Apptics config into the bundle", "Embed remaining ZoomSDK support binaries" (rsync with `--delete` excluding the `XCODE_EMBEDS` frameworks, then `codesign --force --deep` of everything not Sparkle/Apptics).
- **Release flow** (`scripts/release.sh <version> <notes.md>`, run from `main`, no PR flow, no App Store):
  1. fetch Sparkle 2.6.4 tools into `.sparkle-tools/` if missing;
  2. bump `MARKETING_VERSION` to `<version>` and `CURRENT_PROJECT_VERSION` +1 in `project.yml` (sed);
  3. `xcodegen generate`, Release build, `codesign --verify --deep --strict`;
  4. `ditto` zip into `dist/`, unzip and re-verify; linkage gate (every `@rpath` lib in the binary must exist in `Contents/Frameworks`); smoke launch of the zipped app for 5 s (quits any running Greenroom first);
  5. `generate_appcast` with the EdDSA key from the FILE `~/.greenroom-sparkle-ed25519` (Keychain is inaccessible non-interactively; export with `.sparkle-tools/bin/generate_keys -x`), writes `docs/appcast.xml` with embedded notes, download prefix `https://github.com/Sibhimanyu/greenroom/releases/download/v<ver>/`;
  6. `scripts/make-dmg.sh` (best effort; on failure the release is zip-only); on success `scripts/site-download-link.sh <ver> dmg` repoints the site buttons;
  7. `git add project.yml docs/appcast.xml docs/*.html`, commit "Version <ver>", `git push`, `gh release create v<ver>` with zip (+ dmg), `--latest`, `--notes-file`.
  Pages then serves the new appcast and installed copies see the update (Sparkle checks every 6 h, `UpdateGate` blocks scheduled checks mid-class).
- **Site.** Static HTML in `docs/`, served by GitHub Pages (`static.yml` on push to `main`). Download buttons are `sed`-edited by `site-download-link.sh` and corrected at view time by `docs/download-link.js`. Design rules in `DESIGN.md` (never hardcode a green; `--accent-lime` is fill-only, green text is `--brand-green`; amber text under 14px uses `--net-text`).

## Tests (what each file covers, grouped)

All in `Tests/`, one XCTestCase per file named after the subject. The bundle compiles the real sources listed in `project.yml` `GreenroomTests.sources` (so tests pin shipped code, not copies).

| Group | Test files | Source under test |
|---|---|---|
| Layout model/geometry | `LayoutGeometryTests`, `LayoutMigrationTests` (385), `LayoutResolverTests`, `LayoutViewPieceTests`, `LayoutAppOrderingTests`, `LayoutPlacementRulesTests` | `App/Layout/LayoutTemplate.swift`, `LayoutGeometry.swift`, `App/UI/LayoutAppOrdering.swift`, `App/Layout/LayoutPlacementRules.swift` |
| Presence/stage | `PresenceGeometryTests`, `PresenceVisibilityTests`, `ScreenRecoveryTests`, `SlideShowFollowTests`, `ScreenAnnotationTests` (also Audio-only card), `TileAppearanceTests` | `App/Stage/PresenceGeometry`, `PresenceVisibility`, `ScreenRecovery`, `SlideShowFollow`, `AudioOnlyCard`, `App/Recording/ScreenAnnotation`, `App/UI/TileAppearance` |
| Window frames/previews | `WindowFrameRulesTests`, `PreviewFrameRulesTests`, `PreviewOutlineRulesTests`, `MainWindowTests`, `OnboardingPlacementTests` | `App/UI/WindowFrameRules`, `PreviewFrameRules`, `PreviewOutlineRules`, `MainWindow`, `OnboardingPlacement` |
| Meeting bar/window | `MeetingBarPlacementTests`, `PeoplePopOutPlacementTests`, `MeetingBarModelTests`, `MeetingToolbarTests` (class `MeetingToolbarLayoutTests`, 63 tests), `MeetingCollapseRulesTests`, `MeetingShrinkRulesTests`, `ShareVisibilityRulesTests`, `PresentMenuTests`, `ViewsMenuTests`, `NotchStatusRulesTests`, `ParticipantActionRulesTests` (person controls per viewer, footer "...") | `App/MeetingBarPlacement`, `UI/MeetingBarModel`, `UI/MeetingToolbarLayout`, `MeetingCollapseRules`, `MeetingShrinkRules`, `ShareVisibilityRules`, `UI/PresentMenuSpec`, `UI/MeetingViewsMenu`, `UI/NotchStatusRules`, `UI/ParticipantConsole/ParticipantActionRules` |
| Meeting views/video | `MeetingViewRulesTests`, `MeetingViewFlagTests`, `RecentSpeakersTests`, `VideoBudgetTests`, `SubscribeBackoffTests`, `HandsUpOrderingTests`, `ChatGroupingTests` | `UI/MeetingVideo/MeetingViewRules`, `Zoom/RecentSpeakers`, `Zoom/VideoBudget`, `Zoom/SubscribeBackoff`, `Zoom/HandsUpOrdering`, `UI/ChatGrouping` (+ `Zoom/MeetingShareRules`, `MeetingRoomLedgers`) |
| Start/exit/lifecycle | `StartChoreographyTests`, `StartFailureTests` (a start that does not go live: the island says why, the Meeting window and its loop go), `FreshInstallTests` (launch-time model setup on empty UserDefaults), `RecordStartFlowTests`, `MainWindowVisibilityTests`, `LiveExitRulesTests`, `MenuBarModelTests`, `SidebarRulesTests`, `HomeCalmRulesTests` | `App/StartChoreography`, `RecordStartFlow`, `MainWindowVisibility`, `LiveExitRules`, `UI/MenuBarModel`, `UI/SidebarRules`, `UI/HomeCalmRules` |
| Shortcuts | `ShortcutModelTests` | `App/ShortcutModel.swift` |
| Settings file | `SettingsTransferTests` (format, round trip, old-file fixture), `SettingsImportRulesTests` (validations, Blur fallback, mic), `SettingsDefaultsBridgeTests`, `SettingsCatalogTests` (guard: scans `App/` for persisted keys, fails on any not classified) | `App/Settings/*` (not the coordinator extension), `CameraDirectorSettings.swift`, `CameraBackgroundChoice.swift`, `ShareTarget.swift` |
| Sessions/recording | `SessionsQueryTests`, `SessionSelectionTests`, `SessionDetailRulesTests`, `SessionFolderRulesTests`, `SessionTitleSuggesterTests`, `PauseClockTests` (also audio mix), `SegmentedMathTests` | `UI/SessionsQuery`, `SessionSelection`, `SessionDetailRules`, `Recording/SessionFolderRules`, `UI/SessionTitleSuggester`, `Recording/PauseClock`, `AudioMixer`, `UI/SegmentedMath` |
| Zoom requests | `NewMeetingRequestTests`, `PersonalRoomTests` | `Zoom/NewMeetingRequest`, `ZoomScopes`, `ZoomServerToServerClient`, `ZoomPersonalRoom` |
| YouTube | `YouTubeRouteRulesTests`, `YouTubeAccountChoiceRulesTests`, `YouTubeGuideFlowRulesTests`, `YouTubeOAuthTests`, `YouTubeUploadRulesTests`, `YouTubeErrorRulesTests` | `YouTube/YouTubeRouteRules`, `YouTubeAccountChoiceRules`, `YouTubeGuideFlowRules`, `YouTubeOAuth`, `YouTubeUploadRules` (incl. `YouTubeStudioHandoff`), `YouTubeErrorRules` |
| Camera state matrix | `CameraMatrixTests` (the four states x the toolbar and bar button, its menu, Home's chip, the shortcut toast, the bubble, the stage, the Room screen with Show my camera on and off, the "You" tile's mark, the own People row, other apps' recorders; Off -> on, layout switch, Start with each saved state; and a videoStopped dimension, R49), `StopVideoRulesTests` (camera state x video stopped: icon, tint, caption, click, menu row; Zoom's status; moments) | `CameraState`, `Visibility`, `MeetingBarModel`, `HomeTilePanelRules`, `SelfViewRules`, `RoomScreenRules`, `PresenceVisibility`, `PresenceRecorderRules`, `StopVideoRules` |
| Source scans | `SourceScanTests` (reads `App/` from disk, fails at file:line: raw `Color(red:` in `App/UI`, "class" in `App/UI` strings, `.sharingType =` outside `RecorderVisibility.swift`, exact `==` on rects in `App/Layout`, Zoom's own video mute `.setMyVideo(`: exactly one call, Stop video's in `CoordinatorController+StopVideo.swift` (R49), the camera state is the control everywhere else; allow-lists carry a reason each, `knownDrift` entries are real violations to fix) | the sources themselves, compiles none |

Not covered by XCTest: `CoordinatorController`, windows/AppKit controllers, Cues detector (covered by `CuesBench` instead), Screenroom, Editor, the YouTube network calls (`YouTubeAuth`, `YouTubeUploader`), Zoom SDK client.

## To change X, go to Y

- Bump the app version by hand -> `project.yml` `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` (normally only `release.sh` does it).
- Cut a release -> `scripts/release.sh <version> <notes.md>` from `main`; draft notes live in `docs/release/next.md`.
- Add a Swift package -> `project.yml` `packages:` + the target's `dependencies:`; if it embeds a framework, ALSO add its `.framework` to `XCODE_EMBEDS` and the re-sign exclusion list in the postbuild script (else rsync deletes it and the app dies at launch with a dyld error), then run `xcodegen generate`.
- Add a new source file to the app -> just create it under `App/` (directory source), then `xcodegen generate`.
- Make a pure file testable -> add its path to `GreenroomTests.sources` in `project.yml` (and its dependencies, if it uses another pure file), add `Tests/<Name>Tests.swift`, regenerate.
- Add a test for existing rules -> new `Tests/*Tests.swift` (auto-included via `path: Tests`); keep the source file Foundation-only.
- Change Sparkle feed URL / public key / check interval -> `App/Info.plist` (`SUFeedURL`, `SUPublicEDKey`, `SUScheduledCheckInterval`).
- Change signing team -> `project.yml` `DEVELOPMENT_TEAM` (never in Xcode's Signing UI: regeneration overwrites it).
- Change minimum macOS -> `project.yml` (`deploymentTarget` and `MACOSX_DEPLOYMENT_TARGET`).
- Change entitlements -> `App/App.entitlements`.
- Score a Cues detector change -> `scripts/cues-bench.sh`; add cases to `Bench/fixtures/detector.json`; the compiled file list is `CuesBench.sources` in `project.yml`.
- Change the DMG look -> `scripts/dmg-background.py` and `scripts/make-dmg.sh` together (window size and icon coordinates must match); use the `make-dmg` skill, never `hdiutil create -srcfolder` or `create-dmg` on this Mac.
- Repoint site Download buttons -> `scripts/site-download-link.sh <ver> <dmg|zip>`; edit site copy in `docs/*.html`.
- Update the Apptics vendored scripts -> replace `Vendor/Apptics/scripts/` from the matching HelperScripts.zip and keep `exactVersion` in `project.yml` in step.
- Add a site page -> new `docs/<name>.html`; add to `docs/sitemap.xml`; follow DESIGN.md tokens.
- Update the logo -> `Branding/` sources, then `App/Assets.xcassets` (`AppIcon`, `LogoMark`, `MenuBarMark`) and `docs/brand/`.
- A source scan fails -> fix the line; only a legitimate use joins an allow-list in `Tests/SourceScanTests.swift`, with its reason. Fixing a `knownDrift` entry means deleting it (a stale entry fails).
- Record a visual decision or drift -> `DESIGN.md` ("Open drift to fix", "Decisions Log").
- See a UI change without launching the app -> `scripts/render/<layouts|home-panels|appearance|self-view|meeting-topbar|people|stop-video|bar-menu|scheduled|zoom-settings|zoom-guide|zoom-coach|zoom-bar|youtube|youtube-guide>.sh [outdir]`. A render that stops compiling after a view change: add the new source file (or a stand-in) in `scripts/render/lib.sh`, or update the sample call in `scripts/render/swift/`.
- Measure quit speed -> `scripts/measure-quit.sh [settle-seconds]`.
- Log a follow-up to verify live -> `TODOS.md`.

## Gotchas

- `xcodegen generate` OVERWRITES `Greenroom.xcodeproj`; put every project setting in `project.yml`. Anything that writes into the xcodeproj (CocoaPods) is erased, which is why Apptics comes in via SPM.
- This is a git worktree setup: `Vendor/ZoomSDK` is a symlink to the main checkout's copy (`/Users/sibhi-zstch1643/squeak/repos/greenroom/Vendor/ZoomSDK`). Never commit it, never rsync stray files into the real folder (they get embedded and break codesign). Do not run `git stash` bare (shared stash).
- `apptics-config.plist` holds the real API key and is rewritten by builds; gitignored; the key ships inside the app by design.
- Do not install the dev build to /Applications on this Mac; run from DerivedData. Open the Debug build after each build only as the user's preference notes say; never drive it or start meetings without asking.
- Release prerequisites: `xcodegen`, authed `gh`, the key file `~/.greenroom-sparkle-ed25519`, Vendor/ZoomSDK present. The script pushes and tags in the SAME run; a failure after the bump push needs a manual finish (bash 3.2 empty-array expansion bug was fixed with `${DMG_ARG[@]+"${DMG_ARG[@]}"}`).
- `generate_appcast` scans `dist/`; the DMG is built AFTER it on purpose so it does not become an update enclosure. Sparkle updates ship as the zip; the DMG is for manual installs.
- DMG creation is best-effort: `hdiutil`-based tools hit CrowdStrike "Resource busy" on this Mac, so a zip-only release is acceptable (site Download buttons keep pointing at the previous DMG). Use the `make-dmg` skill for DMGs.
- The appcast keeps only the LATEST release (single item), so enclosure URLs are per-tag.
- Linkage gate exists because v0.3.0 shipped without Sparkle embedded: `codesign` passes on missing frameworks. Keep the gate.
- The `GreenroomTests` bundle only sees files listed in `project.yml`; a test that references a type from an unlisted file fails to compile. Listed files must not pull in AppKit-heavy coordinator types or Zoom SDK.
- Debug UI (`App/Debug`, Settings debug rows) is `#if DEBUG` only. Check Release binaries with `strings` before shipping.
- Site design: never hardcode a green; `--accent-lime` is not valid for text; amber under 14px uses `--net-text` (`DESIGN.md`). UI wording says "meeting"/"everyone", not "class".
- `docs/` is public: do not put credentials, the user's own footage, or private names there.
- `dist/` is deleted at the start of each release run.
