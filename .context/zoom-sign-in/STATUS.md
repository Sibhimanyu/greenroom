# Sign in with Zoom: status

## Done (branch zoom-sign-in, not pushed)
- `App/Zoom/ZoomUserAuth*.swift`, `ZoomLoopbackListener.swift`: browser sign-in, PKCE, public client, no secret; refresh token in SecretStore; sign out (tries revoke, always forgets locally).
- `ZoomRESTAccess` + coordinator: signed in -> meetings, ZAK, list as the person; else the pasted S2S app, unchanged.
- SDK JWT: signed in and endpoint set -> from the Catalyst function; else pasted SDK key and secret; else "Sign in with Zoom isn't finished setting up".
- `server/sdk-signature`: Catalyst Advanced I/O function (Node 20) + README + threat note + node tests.
- UI: Settings -> Zoom and the setup guide's Zoom step lead with Sign in with Zoom; the old fields sit under a folding "Use your own Zoom apps (advanced)".

## Needs the owner
1. Deploy the function: see `server/sdk-signature/README.md` (`catalyst deploy --only functions:sdk_signature`, then set `ZOOM_CLIENT_ID` and `ZOOM_CLIENT_SECRET` in the console, never in the repo).
2. Put the function URL (`.../server/sdk_signature/execute/signature`) in `ZoomOAuth.sdkSignatureEndpoint`. Until then, signed-in users with no pasted SDK keys see "isn't finished setting up".
3. Zoom beta-share approval so accounts other than the owner's can authorize the app (see zoom-review-checklist.md).
4. Scopes the signed-in path calls but the app does not have yet (each fails with a scope error from Zoom; none blocks a start, the SDK ends the meeting itself):
   - `PUT /meetings/{id}/status` (end for everyone, back-up for the SDK end): `meeting:update:status`
   - `GET /meetings/{id}` (edit sheet, next time of recurring meetings): `meeting:read:meeting`
   - `PATCH /meetings/{id}` (save an edit): `meeting:update:meeting`
   - `DELETE /meetings/{id}` (delete a scheduled meeting): `meeting:delete:meeting`
   The five granted scopes cover the rest: `/users/me` (user:read:user), ZAK (user:read:token, user:read:zak), create (meeting:write:meeting), list and live (meeting:read:list_meetings).

## Link and deploy the function (Catalyst project "Greenroom", org "Sibhimanyu G", 60083782173)
```sh
cd server/sdk-signature
catalyst login
catalyst init --org 60083782173      # pick the existing project "Greenroom"; writes .catalystrc, keeps catalyst.json's functions entry
# if already initialised elsewhere: catalyst project:use Greenroom
npm test
catalyst deploy --only functions:sdk_signature
```
Then in the Catalyst console (Greenroom -> Functions -> sdk_signature -> Configuration) set `ZOOM_CLIENT_ID` and `ZOOM_CLIENT_SECRET`, and put `<function URL>/execute/signature` in `ZoomOAuth.sdkSignatureEndpoint`. No project IDs are written in the repo; `.catalystrc` is made by `init`.

## When a scope changes (owner's steps)
1. Add the scope to the Zoom Marketplace app.
2. Add it to `ZoomOAuth.requiredScopes` (App/Zoom/ZoomUserAuthRules.swift).
3. Ship. People signed in before see "Greenroom needs one more Zoom permission" in Settings, Home's pill and the menu bar, with Sign in again; Start waits until they do. The check reads the scopes Zoom returned with their token, so nothing fails mid-meeting.
Order matters: add it in the Marketplace BEFORE the constant, or Sign in again cannot grant it.
Switching the client ID (Development to Production) = change `ZoomOAuth.publicClientID`, ship, and people sign in once ("Zoom sign-in needs renewing"; ZoomCredentialCheck).

## Storage
The refresh token is a Keychain item (service com.sibhimanyu.greenroom.zoom, after first unlock, this device only); an old copy in preferences is moved once and deleted.

## Not tested
Nothing was run against Zoom, no browser sign-in, no meeting started. The OAuth calls match what probe.sh proved. Revoke by the public client is untried: if Zoom refuses, sign out only deletes locally and says so.

## How to test
- `npm test` in `server/sdk-signature` (10 tests); `xcodebuild ... -scheme GreenroomTests test` (ZoomUserAuthRulesTests).
- By hand: build Debug, Settings -> Zoom -> Sign in with Zoom, approve in the browser, see "Signed in as ...". Start a meeting from Home. With the endpoint empty and no pasted SDK keys, Start says sign-in is not finished; with pasted SDK keys it signs locally.
