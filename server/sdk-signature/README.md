# Greenroom SDK signature function (Zoho Catalyst)

The Zoom Meeting SDK needs a JWT signed with the General app's Client ID and
Client Secret. The secret cannot ship in the app, so this Catalyst Advanced I/O
function (Node 20) signs it for people who signed in with Zoom.

One endpoint: `POST <function URL>/execute/signature` with body
`{"meetingNumber": "123456789", "role": 1}` (both optional; the app asks without a
meeting number when it starts the SDK) and the header
`Authorization: Bearer <the person's Zoom access token>`. It answers
`{"signature": "<jwt>"}`. Layout follows Catalyst's function project shape:
`catalyst.json`, `functions/sdk_signature/{index.js, catalyst-config.json, package.json}`.

## Deploy (the owner does this; nothing here deploys itself)

```sh
cd server/sdk-signature
catalyst login
catalyst init            # link this folder to your Catalyst project (creates .catalystrc)
catalyst deploy --only functions:sdk_signature
```

1. In the Catalyst console, open Functions, then `sdk_signature`, then Configuration,
   and add the environment variables `ZOOM_CLIENT_ID` (the General app's normal,
   confidential Client ID) and `ZOOM_CLIENT_SECRET`. They are set in the console
   on purpose: `catalyst-config.json` keeps `"env_variables": {}` so the secret is
   never in the repo. If a later deploy clears them, set them again.
2. `catalyst deploy` prints `https://<project>.catalystserverless.com/server/sdk_signature/`.
   The real address needs `/execute/signature` added. Put
   `https://<project>.catalystserverless.com/server/sdk_signature/execute/signature`
   in `ZoomOAuth.sdkSignatureEndpoint` (App/Zoom/ZoomUserAuthRules.swift) and ship the app.
3. Functions are public by default (Security Rules `authentication: optional`).
   Leave it that way: the caller is Greenroom, not a Catalyst user, and the function
   does its own check of the Zoom token. Do not add CORS headers or turn on API
   Gateway for this route unless you also want the gateway's rate limiting (see the
   threat note); never use both Security Rules and the gateway.

## Test

```sh
npm test    # node --test, no dependencies
```

## Threat note

- The function holds the one secret. It signs only for a caller whose Zoom access
  token Zoom itself accepts (`GET /v2/users/me`), so a random caller on the
  internet gets nothing. It never logs or stores tokens.
- Anyone with a valid Zoom account can still ask for a signature, and a signature
  lets that person's copy of the Meeting SDK start up under this app. That is the
  same as any public SDK app. Zoom's own review and rate limits are the guard rail;
  turn on Catalyst API Gateway rate limiting for this route if abuse appears.
- A host-role request that names a meeting is refused when Zoom says the meeting
  belongs to someone else. If the token cannot read the meeting (scope missing),
  the check is skipped and the SDK's own host rules decide.
- Signatures last two hours (Zoom allows 30 minutes to 48 hours).
- Rotate by resetting the secret in the Zoom Marketplace and updating
  `ZOOM_CLIENT_SECRET` in the console. The app needs no update.
