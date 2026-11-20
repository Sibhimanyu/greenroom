// POST /signature  { meetingNumber?, role? }  with  Authorization: Bearer <Zoom access token>
// Returns { signature }, a Meeting SDK JWT signed with the Worker's secrets.
//
// The caller must be a real Zoom user: their token is checked by asking Zoom
// who it belongs to (GET /v2/users/me). A host-role request for a given
// meeting is also checked to be that user's own meeting when Zoom lets us read
// it. Nothing is stored and nothing is logged.

import { makeSignature } from "./signer.js";

const ZOOM_API = "https://api.zoom.us/v2";
const MEETING_NUMBER = /^\d{9,12}$/;

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

function bearer(request) {
  const header = request.headers.get("authorization") || "";
  const match = /^Bearer\s+(\S+)$/i.exec(header);
  return match ? match[1] : null;
}

async function zoomGet(path, token, fetchFn) {
  return fetchFn(`${ZOOM_API}${path}`, { headers: { authorization: `Bearer ${token}` } });
}

// Returns null when the caller may have a host signature for this meeting,
// otherwise an error string. A meeting we cannot read (the token lacks the
// read scope) is allowed: it cannot be checked, and the SDK itself refuses a
// host start for a meeting the person does not own.
export async function checkOwnsMeeting({ token, userId, meetingNumber, fetchFn }) {
  const response = await zoomGet(`/meetings/${meetingNumber}`, token, fetchFn);
  if (response.status === 404) return "that meeting is not yours";
  if (!response.ok) return null;
  const meeting = await response.json().catch(() => null);
  if (meeting && meeting.host_id && meeting.host_id !== userId) return "that meeting is not yours";
  return null;
}

export async function handle(request, env, fetchFn = fetch, now = Date.now()) {
  const url = new URL(request.url);
  if (url.pathname !== "/signature") return json({ error: "not found" }, 404);
  if (request.method !== "POST") return json({ error: "use POST" }, 405);

  const token = bearer(request);
  if (!token) return json({ error: "missing bearer token" }, 401);
  if (!env.ZOOM_CLIENT_ID || !env.ZOOM_CLIENT_SECRET) return json({ error: "server not configured" }, 500);

  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: "body must be JSON" }, 400);
  }
  const role = body.role === undefined ? 1 : body.role;
  if (role !== 0 && role !== 1) return json({ error: "role must be 0 or 1" }, 400);
  let meetingNumber;
  if (body.meetingNumber !== undefined && body.meetingNumber !== null && body.meetingNumber !== "") {
    meetingNumber = String(body.meetingNumber).replace(/\s+/g, "");
    if (!MEETING_NUMBER.test(meetingNumber)) return json({ error: "meetingNumber must be 9 to 12 digits" }, 400);
  }

  // Who is asking? Zoom decides; a bad or expired token fails here.
  let me;
  try {
    const who = await zoomGet("/users/me", token, fetchFn);
    if (!who.ok) return json({ error: "Zoom did not accept that token" }, 401);
    me = await who.json();
  } catch {
    return json({ error: "could not reach Zoom" }, 502);
  }
  if (!me || !me.id) return json({ error: "Zoom did not accept that token" }, 401);

  if (role === 1 && meetingNumber) {
    let problem;
    try {
      problem = await checkOwnsMeeting({ token, userId: me.id, meetingNumber, fetchFn });
    } catch {
      problem = null;
    }
    if (problem) return json({ error: problem }, 403);
  }

  const signature = await makeSignature({
    clientID: env.ZOOM_CLIENT_ID,
    clientSecret: env.ZOOM_CLIENT_SECRET,
    meetingNumber,
    role,
    now,
  });
  return json({ signature });
}

export default {
  fetch(request, env) {
    return handle(request, env);
  },
};
