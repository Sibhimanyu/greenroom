// Meeting SDK JWT, HS256. The claim shape is the one the app's own local signer
// (App/Zoom/ZoomMeetingSDKJWT.swift) uses: appKey, iat, exp, tokenExp, plus
// sdkKey (Zoom accepts either name), and mn and role when a meeting is given.
// Uses WebCrypto only, so it runs in a Worker and in node.

const encoder = new TextEncoder();

function base64url(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function base64urlJSON(value) {
  return base64url(encoder.encode(JSON.stringify(value)));
}

// Zoom wants exp and tokenExp between 30 minutes and 48 hours after iat.
export const DEFAULT_LIFETIME_SECONDS = 2 * 60 * 60;
const MIN_LIFETIME = 1800;
const MAX_LIFETIME = 172800;

export function buildClaims({ clientID, meetingNumber, role, now, lifetime = DEFAULT_LIFETIME_SECONDS }) {
  const iat = Math.floor(now / 1000);
  const exp = iat + Math.min(Math.max(lifetime, MIN_LIFETIME), MAX_LIFETIME);
  const claims = { appKey: clientID, sdkKey: clientID, iat, exp, tokenExp: exp };
  if (meetingNumber) {
    claims.mn = meetingNumber;
    claims.role = role;
  }
  return claims;
}

export async function signJWT(claims, secret) {
  const header = { alg: "HS256", typ: "JWT" };
  const input = `${base64urlJSON(header)}.${base64urlJSON(claims)}`;
  const key = await crypto.subtle.importKey(
    "raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(input)));
  return `${input}.${base64url(mac)}`;
}

export async function makeSignature({ clientID, clientSecret, meetingNumber, role, now = Date.now() }) {
  return signJWT(buildClaims({ clientID, meetingNumber, role, now }), clientSecret);
}
