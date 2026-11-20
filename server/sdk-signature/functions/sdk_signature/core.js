'use strict';
// The whole decision, with no HTTP framework in it, so it is testable:
// process({ method, path, authorization, body, env, fetchFn, now }) -> { status, body }

const { makeSignature } = require('./signer');

const ZOOM_API = 'https://api.zoom.us/v2';
const MEETING_NUMBER = /^\d{9,12}$/;

function reply(status, body) {
  return { status, body };
}

function bearer(header) {
  const match = /^Bearer\s+(\S+)$/i.exec(header || '');
  return match ? match[1] : null;
}

function zoomGet(path, token, fetchFn) {
  return fetchFn(`${ZOOM_API}${path}`, { headers: { authorization: `Bearer ${token}` } });
}

// null when the caller may have a host signature for this meeting, else an
// error string. A meeting we cannot read (the token lacks the read scope) is
// allowed: it cannot be checked, and the SDK itself refuses a host start for a
// meeting the person does not own.
async function checkOwnsMeeting({ token, userId, meetingNumber, fetchFn }) {
  const response = await zoomGet(`/meetings/${meetingNumber}`, token, fetchFn);
  if (response.status === 404) return 'that meeting is not yours';
  if (!response.ok) return null;
  const meeting = await response.json().catch(() => null);
  if (meeting && meeting.host_id && meeting.host_id !== userId) return 'that meeting is not yours';
  return null;
}

async function process({ method, path, authorization, body, env, fetchFn = fetch, now = Date.now() }) {
  // Catalyst serves the function under .../execute, so the route arrives as
  // "/execute/signature". "/signature" and "/" are accepted too.
  const route = (path || '/').replace(/^\/execute/, '') || '/';
  if (route !== '/signature' && route !== '/') return reply(404, { error: 'not found' });
  if (method !== 'POST') return reply(405, { error: 'use POST' });

  const token = bearer(authorization);
  if (!token) return reply(401, { error: 'missing bearer token' });
  if (!env.ZOOM_CLIENT_ID || !env.ZOOM_CLIENT_SECRET) return reply(500, { error: 'server not configured' });

  const input = body && typeof body === 'object' ? body : null;
  if (!input) return reply(400, { error: 'body must be JSON' });
  const role = input.role === undefined ? 1 : input.role;
  if (role !== 0 && role !== 1) return reply(400, { error: 'role must be 0 or 1' });
  let meetingNumber;
  if (input.meetingNumber !== undefined && input.meetingNumber !== null && input.meetingNumber !== '') {
    meetingNumber = String(input.meetingNumber).replace(/\s+/g, '');
    if (!MEETING_NUMBER.test(meetingNumber)) return reply(400, { error: 'meetingNumber must be 9 to 12 digits' });
  }

  // Who is asking? Zoom decides; a bad or expired token fails here.
  let me;
  try {
    const who = await zoomGet('/users/me', token, fetchFn);
    if (!who.ok) return reply(401, { error: 'Zoom did not accept that token' });
    me = await who.json();
  } catch (error) {
    return reply(502, { error: 'could not reach Zoom' });
  }
  if (!me || !me.id) return reply(401, { error: 'Zoom did not accept that token' });

  if (role === 1 && meetingNumber) {
    let problem = null;
    try {
      problem = await checkOwnsMeeting({ token, userId: me.id, meetingNumber, fetchFn });
    } catch (error) {
      problem = null;
    }
    if (problem) return reply(403, { error: problem });
  }

  const signature = await makeSignature({
    clientID: env.ZOOM_CLIENT_ID,
    clientSecret: env.ZOOM_CLIENT_SECRET,
    meetingNumber,
    role,
    now,
  });
  return reply(200, { signature });
}

module.exports = { process, checkOwnsMeeting };
