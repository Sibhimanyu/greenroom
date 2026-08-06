# Vendor/ZoomSDK

The real Zoom **Meeting SDK for macOS** (v7.1.5.84750), already in place -
copied in from a zip downloaded via your own Zoom Marketplace account,
proprietary so it isn't committed to version control history in spirit
(this repo just isn't a git repo at all right now).

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

## Still needed: your own app credentials (two Marketplace apps)

The framework being here is necessary but not sufficient. Zoom-facing
features run off TWO Marketplace apps:

**App 1 - General App with Meeting SDK (powers the chat window):**

1. Go to <https://marketplace.zoom.us> and sign in.
2. Build App -> **General App** (Meeting SDK is enabled as a toggle
   inside this, not its own app type anymore).
3. On its **Features** page -> **Embed** tab, toggle **Meeting SDK** on.
4. From **App Credentials**, copy the **Client ID** and **Client Secret**
   into Greenroom's Settings -> Meeting Chat tab (Client ID goes to
   UserDefaults, harmless; Secret goes to the Keychain - see
   `App/Zoom/KeychainStore.swift` - never put either in this repo).

**App 2 - Server-to-Server OAuth (powers "Start New Meeting"; optional):**

1. Build App -> **Server-to-Server OAuth**.
2. Add a meeting-write scope (search "meeting" on its Scopes page and
   pick the create-a-meeting one).
3. Copy its **Account ID**, **Client ID**, and **Client Secret** into
   Greenroom's Settings -> Start Meeting tab.

**Why two apps?** Zoom's headless `account_credentials` token grant is
exclusive to the S2S app type, and the Meeting SDK embed is exclusive to
the General App type. A one-app consolidation via browser-consent OAuth +
PKCE was fully built (Aug 2026) and then deliberately reverted: Zoom
rejects `localhost` redirect URLs outright, only permits loopback-IP
redirects for PKCE public-client apps, and even with the public-client
toggle + PKCE in place the authorize endpoint kept rejecting the
registered redirect (their own dev forum documents allow-list entries
silently failing to save). Not worth it for a personal tool - the second
app is a one-time 5-minute setup. If ever revisited, the working PKCE
client implementation is in this project's conversation history.

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

Practical rule: **the chat window works in meetings hosted under the
account that owns the Meeting SDK app** - which includes every meeting
"Start New Meeting" creates, as long as the S2S app belongs to that same
Zoom account.
