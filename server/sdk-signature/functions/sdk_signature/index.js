'use strict';
// Catalyst Advanced I/O function (Node 20, raw http template):
//   POST <function URL>/execute/signature   { meetingNumber?, role? }
//   Authorization: Bearer <the person's Zoom access token>
// answers { signature }, a Meeting SDK JWT signed with ZOOM_CLIENT_ID and
// ZOOM_CLIENT_SECRET from the function's environment variables.
//
// No CORS headers on purpose: the caller is a native app, and Catalyst injects
// them itself when Authorized Domains is on (setting them here would double them).
// The Catalyst SDK is not used: nothing here touches a Catalyst service.

const { process: decide } = require('./core');

function readBody(req) {
  return new Promise((resolve) => {
    if (req.body && typeof req.body === 'object') return resolve(req.body);
    if (typeof req.body === 'string') {
      try { return resolve(JSON.parse(req.body)); } catch (e) { return resolve(null); }
    }
    let data = '';
    req.on('data', (chunk) => { data += chunk; if (data.length > 10000) req.destroy(); });
    req.on('end', () => {
      try { resolve(data ? JSON.parse(data) : {}); } catch (e) { resolve(null); }
    });
    req.on('error', () => resolve(null));
  });
}

function sendJson(res, status, data) {
  res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(data));
}

module.exports = async (req, res) => {
  try {
    const path = new URL(req.url, `https://${req.headers.host || 'localhost'}`).pathname;
    const body = req.method === 'POST' ? await readBody(req) : {};
    const result = await decide({
      method: req.method,
      path,
      authorization: req.headers.authorization,
      body,
      env: process.env,
    });
    sendJson(res, result.status, result.body);
  } catch (error) {
    sendJson(res, 500, { error: 'internal error' });
  }
};
