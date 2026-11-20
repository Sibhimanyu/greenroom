'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createHmac } = require('node:crypto');
const { buildClaims, makeSignature } = require('../functions/sdk_signature/signer');
const { process: decide } = require('../functions/sdk_signature/core');

const NOW = Date.UTC(2026, 10, 20, 12, 0, 0);
const decode = (part) => JSON.parse(Buffer.from(part, 'base64url').toString());

test('signature verifies with the secret and has the app\'s claim shape', async () => {
  const jwt = await makeSignature({ clientID: 'KEY', clientSecret: 'SECRET', now: NOW });
  const [h, p, s] = jwt.split('.');
  assert.deepEqual(decode(h), { alg: 'HS256', typ: 'JWT' });
  assert.equal(s, createHmac('sha256', 'SECRET').update(`${h}.${p}`).digest('base64url'));
  const claims = decode(p);
  const iat = Math.floor(NOW / 1000);
  assert.equal(claims.appKey, 'KEY');
  assert.equal(claims.sdkKey, 'KEY');
  assert.equal(claims.iat, iat);
  assert.equal(claims.exp, claims.tokenExp);
  assert.ok(claims.exp - iat >= 1800 && claims.exp - iat <= 172800);
  assert.equal('mn' in claims, false);
  assert.equal('role' in claims, false);
});

test('meeting number and role are added when given', () => {
  const claims = buildClaims({ clientID: 'K', meetingNumber: '123456789', role: 1, now: NOW });
  assert.equal(claims.mn, '123456789');
  assert.equal(claims.role, 1);
});

test('lifetime is clamped into Zoom\'s 30 minutes to 48 hours', () => {
  const short = buildClaims({ clientID: 'K', now: NOW, lifetime: 5 });
  const long = buildClaims({ clientID: 'K', now: NOW, lifetime: 10 ** 9 });
  assert.equal(short.exp - short.iat, 1800);
  assert.equal(long.exp - long.iat, 172800);
});

const env = { ZOOM_CLIENT_ID: 'KEY', ZOOM_CLIENT_SECRET: 'SECRET' };
const call = (body, extra = {}, e = env, fetchFn) => decide({
  method: 'POST', path: '/execute/signature', authorization: 'Bearer tok', body, env: e, fetchFn, now: NOW, ...extra,
});

function zoom({ meGood = true, meeting } = {}) {
  const calls = [];
  const fetchFn = async (url, init) => {
    calls.push({ url, auth: init.headers.authorization });
    if (url.endsWith('/users/me')) {
      return meGood ? new Response(JSON.stringify({ id: 'USER1' }), { status: 200 }) : new Response('{}', { status: 401 });
    }
    return meeting || new Response('{}', { status: 400 });
  };
  return { fetchFn, calls };
}

test('no bearer token is refused without calling Zoom', async () => {
  const z = zoom();
  const res = await call({ role: 1 }, { authorization: undefined }, env, z.fetchFn);
  assert.equal(res.status, 401);
  assert.equal(z.calls.length, 0);
});

test('a token Zoom rejects is refused and nothing is signed', async () => {
  const z = zoom({ meGood: false });
  const res = await call({ role: 1 }, {}, env, z.fetchFn);
  assert.equal(res.status, 401);
  assert.equal(res.body.signature, undefined);
  assert.equal(z.calls[0].url, 'https://api.zoom.us/v2/users/me');
  assert.equal(z.calls[0].auth, 'Bearer tok');
});

test('a good token gets a signature', async () => {
  const res = await call({ role: 1 }, {}, env, zoom().fetchFn);
  assert.equal(res.status, 200);
  assert.equal(decode(res.body.signature.split('.')[1]).appKey, 'KEY');
});

test('a host signature for someone else\'s meeting is refused', async () => {
  const z = zoom({ meeting: new Response(JSON.stringify({ host_id: 'OTHER' }), { status: 200 }) });
  assert.equal((await call({ meetingNumber: '123456789', role: 1 }, {}, env, z.fetchFn)).status, 403);
});

test('own meeting is signed, with mn and role', async () => {
  const z = zoom({ meeting: new Response(JSON.stringify({ host_id: 'USER1' }), { status: 200 }) });
  const res = await call({ meetingNumber: '123 456 789', role: 1 }, {}, env, z.fetchFn);
  assert.equal(res.status, 200);
  const claims = decode(res.body.signature.split('.')[1]);
  assert.equal(claims.mn, '123456789');
  assert.equal(claims.role, 1);
});

test('a meeting that cannot be read (missing scope) is allowed', async () => {
  const z = zoom({ meeting: new Response(JSON.stringify({ code: 4711 }), { status: 400 }) });
  assert.equal((await call({ meetingNumber: '123456789', role: 1 }, {}, env, z.fetchFn)).status, 200);
});

test('bad input and wrong routes', async () => {
  const f = zoom().fetchFn;
  assert.equal((await call({ role: 7 }, {}, env, f)).status, 400);
  assert.equal((await call({ meetingNumber: '12' }, {}, env, f)).status, 400);
  assert.equal((await call(null, {}, env, f)).status, 400);
  assert.equal((await call({}, { path: '/execute/other' }, env, f)).status, 404);
  assert.equal((await call({}, { method: 'GET' }, env, f)).status, 405);
  assert.equal((await call({}, {}, {}, f)).status, 500);
  assert.equal((await call({}, { path: '/signature' }, env, f)).status, 200);
});
