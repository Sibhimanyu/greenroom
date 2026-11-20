# Greenroom SDK signature worker

The Zoom Meeting SDK needs a JWT signed with the General app's Client ID and
Client Secret. The secret cannot ship in the app, so this tiny Cloudflare
Worker signs it for people who signed in with Zoom.

One endpoint: `POST /signature` with body `{"meetingNumber": "123456789", "role": 1}`
(both optional; the app asks without a meeting number when it starts the SDK) and
the header `Authorization: Bearer <the person's Zoom access token>`.
It answers `{"signature": "<jwt>"}`.

## Deploy (the owner does this; nothing here deploys itself)

```sh
cd server/sdk-signature
npx wrangler login
npx wrangler secret put ZOOM_CLIENT_ID        # the General app's normal (confidential) Client ID
npx wrangler secret put ZOOM_CLIENT_SECRET    # its Client Secret
npx wrangler deploy
```

Then put the Worker's URL, ending in `/signature`, in
`ZoomOAuth.sdkSignatureEndpoint` (App/Zoom/ZoomUserAuthRules.swift) and ship the app.

## Test

```sh
npm test    # node --test, no dependencies
```

## Threat note

- The worker holds the one secret. It signs only for a caller whose Zoom access
  token Zoom itself accepts (`GET /v2/users/me`), so a random caller on the
  internet gets nothing. It never logs or stores tokens.
- Anyone with a valid Zoom account can still ask for a signature, and a
  signature lets that person's copy of the Meeting SDK start up under this app.
  That is the same as any public SDK app. Zoom's own review and rate limits are
  the guard rail; add Cloudflare rate limiting on the route if abuse appears.
- A host-role request that names a meeting is refused when Zoom says the meeting
  belongs to someone else. If the token cannot read the meeting (scope missing),
  the check is skipped and the SDK's own host rules decide.
- Signatures last two hours (Zoom allows 30 minutes to 48 hours).
- Rotate by running `wrangler secret put ZOOM_CLIENT_SECRET` after resetting the
  secret in the Zoom Marketplace. The app needs no update.
