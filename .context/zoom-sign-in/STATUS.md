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
4. Optional: add scopes `meeting:update:status` (end a meeting over REST) and `meeting:read:meeting` (edit sheet, recurring next time) to the General app, then sign in again.

## Not tested
Nothing was run against Zoom, no browser sign-in, no meeting started. The OAuth calls match what probe.sh proved. Revoke by the public client is untried: if Zoom refuses, sign out only deletes locally and says so.

## How to test
- `npm test` in `server/sdk-signature` (10 tests); `xcodebuild ... -scheme GreenroomTests test` (ZoomUserAuthRulesTests).
- By hand: build Debug, Settings -> Zoom -> Sign in with Zoom, approve in the browser, see "Signed in as ...". Start a meeting from Home. With the endpoint empty and no pasted SDK keys, Start says sign-in is not finished; with pasted SDK keys it signs locally.
