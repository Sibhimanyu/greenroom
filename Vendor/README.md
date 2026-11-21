# Vendor/ZoomSDK

The real Zoom **Meeting SDK for macOS** (v7.1.5.84750), already in place -
copied in from a zip downloaded via your own Zoom Marketplace account,
proprietary, so it is gitignored (`Vendor/ZoomSDK`, no trailing slash so a
worktree symlink is ignored too) and never committed.

## What's here

`ZoomSDK.framework` plus ~80 sibling frameworks/dylibs/bundles/helper
`.app` bundles it depends on at runtime - `project.yml` links just
`ZoomSDK.framework` directly and embeds+codesigns the rest via a
postbuild script (see that file's `postbuildScripts` entry). Confirmed
working: `xcodebuild` succeeds and the built app launches/quits cleanly
with no dyld errors.

**Don't rsync a new SDK version in here without checking the exclude list**
in `project.yml`'s postbuild script (`--exclude 'ZoomSDK.framework'`) -
that's the file it explicitly does NOT copy (already handled by Xcode's
own Embed Frameworks step). Any stray non-SDK file dropped in this folder
(like this README used to be, before it got moved out to
`Vendor/README.md`) gets swept into the app bundle and can break the
final codesign step.

## Credentials: Sign in with Zoom, or your own apps

Most people use **Sign in with Zoom** (Settings -> Zoom): a public PKCE
client with no secret in the app, the refresh token kept in the Keychain,
and the SDK JWT fetched from a small server function. See `codemap/zoom.md`.
Everything below is the advanced path (Settings -> Zoom -> "Use your own
Zoom apps"), where you paste your own app credentials.

The framework being here is necessary but not sufficient for that path.
It runs off TWO Marketplace apps:

**App 1 - General App with Meeting SDK (the in-process meeting client):**

1. Go to <https://marketplace.zoom.us> and sign in.
2. Build App -> **General App** (Meeting SDK is enabled as a toggle
   inside this, not its own app type anymore).
3. On its **Features** page -> **Embed** tab, toggle **Meeting SDK** on.
4. From **App Credentials**, copy the **Client ID** and **Client Secret**
   into Greenroom's Settings -> Zoom tab (both are stored in
   local app preferences / UserDefaults in plaintext - see
   `App/Zoom/SecretStore.swift`; only the Sign in with Zoom refresh token
   is in the Keychain - never put either in this repo).

**App 2 - Server-to-Server OAuth (powers "Start New Meeting", the
Scheduled-meetings list, and hosting your own meetings):**

1. Build App -> **Server-to-Server OAuth**.
2. On its Scopes page add ALL SEVEN scopes (each one's absence was
   discovered as a live 4711 error; the in-app errors name them too):
   - `meeting:write:meeting:admin` - create meetings
   - `meeting:read:list_meetings:admin` - the Scheduled list
   - `meeting:read:meeting:admin` - recurring meetings' next times, and loading a meeting to edit
   - `meeting:update:meeting:admin` - edit scheduled meetings
   - `meeting:delete:meeting:admin` - delete scheduled meetings
   - `user:read:token:admin` - the ZAK that host-starts your own meetings
   - `meeting:update:status:admin` - End session ends the meeting for
     everyone, and a meeting left running is cleared before the next start
3. Copy its **Account ID**, **Client ID**, and **Client Secret** into
   Greenroom's Settings -> Zoom tab.
4. Verify with the setup guide's "Test Zoom Connection" button (? on
   the main window -> credentials step).

**Why two apps (on this path)?** Zoom's headless `account_credentials`
token grant is exclusive to the S2S app type, and the Meeting SDK embed is
exclusive to the General App type. A first browser-consent attempt (Aug
2026) was reverted over redirect rules (Zoom rejects `localhost`, and only
allows loopback-IP redirects for PKCE public clients). Sign in with Zoom
(`ZoomUserAuth`, redirect `http://127.0.0.1:53682/callback`) later shipped
on a public client and is now the default; the two-app setup stays as the
advanced route.

## Confirmed limitation: same-account meetings only

Confirmed by live test: joining a meeting hosted under a *different* Zoom
account than the one that owns the Meeting SDK Marketplace app fails with
`ZoomSDKMeetingError_UnableToJoinExternalMeeting` (63). Zoom's dev forum
says publishing the app is the fix, but at least one developer there
reported the error persisting even after publishing. Zoom's other
documented mechanism (OAuth-fetched On-Behalf-Of tokens) went down with
the abandoned OAuth consolidation above - `ZoomMeetingSDKClient.join`
still accepts an `onBehalfToken` parameter should that ever be revisited,
but nothing feeds it.

Practical rule: **Greenroom works in meetings hosted under the
account that owns the Meeting SDK app** - which includes every meeting
"Start New Meeting" creates, as long as the S2S app belongs to that same
Zoom account.
