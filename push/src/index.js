// Day's push relay: Google Calendar notifications in, APNs pushes out.
//
// Privacy rule for this file: never read, log or store X-Goog-Resource-URI. It
// holds the calendar ID, which for a primary calendar is the account's email
// address. The handler reads only the channel token, the channel ID (a random
// string the device made) and the resource state.

import { InstallCoalescer } from "./coalescer.js";
import { channelToken, normalizeInstallId, verifyChannelToken } from "./token.js";

export { InstallCoalescer };

const MAX_BODY_BYTES = 64 * 1024;
const MAX_CHANNELS = 300;
const CHANNEL_ROWS_PER_INSERT = 30; // 3 parameters a row, D1 allows 100 a statement
const PUSH_TOKEN = /^[0-9a-f]{32,512}$/;
const CHANNEL_ID = /^[A-Za-z0-9_+/=-]{1,64}$/; // Google's alphabet for channel IDs
const STALE_INSTALL_MS = 30 * 24 * 60 * 60 * 1000;
const MAX_FORGET_PER_RUN = 40;

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    if (pathname === "/day/push") return handlePush(request, env);
    if (pathname === "/day/devices") return handleRegister(request, env);
    if (pathname.startsWith("/day/devices/")) return handleDelete(request, env, pathname.slice("/day/devices/".length));
    return new Response(null, { status: 404 });
  },

  async scheduled(controller, env) {
    await cleanup(env, Date.now());
  },
};

// POST /day/push, called by Google for every channel the devices opened.
async function handlePush(request, env) {
  try {
    if (request.method !== "POST") return new Response(null, { status: 405, headers: { allow: "POST" } });
    if (!env.HMAC_KEY) return new Response(null, { status: 503 });
    const installId = await verifyChannelToken(env.HMAC_KEY, request.headers.get("x-goog-channel-token"));
    if (!installId) return new Response(null, { status: 401 });
    // Google's first message on a new channel. Nothing changed yet.
    if (request.headers.get("x-goog-resource-state") === "sync") return new Response(null, { status: 200 });
    // Google keeps posting to a channel until it expires, even after the device
    // dropped it (account removed or signed out, calendar hidden) and can no
    // longer stop it. Only a channel the install still holds may wake it, so the
    // device is not pushed for calendars it no longer shows. The channel row
    // also proves the install still exists. 200 because Google retries only 5xx.
    const channelId = request.headers.get("x-goog-channel-id");
    if (!channelId || !CHANNEL_ID.test(channelId)) return new Response(null, { status: 200 });
    const held = await env.DB.prepare("SELECT 1 FROM channels WHERE channel_id = ? AND install_id = ?")
      .bind(channelId, installId)
      .first();
    if (held) await coalescer(env, installId).notify(installId);
    return new Response(null, { status: 200 });
  } catch (error) {
    // The error name only: nothing from the request goes into a log line.
    console.error(`day-push: push notification failed: ${error?.name ?? "Error"}`);
    // 503 makes Google retry with backoff.
    return new Response(null, { status: 503 });
  }
}

// POST /day/devices: register or refresh an install. See README.md for the body.
async function handleRegister(request, env) {
  if (request.method !== "POST") return json({ error: "method not allowed" }, 405, { allow: "POST" });
  if (!env.HMAC_KEY) return json({ error: "not configured" }, 503);
  if (Number(request.headers.get("content-length")) > MAX_BODY_BYTES) return json({ error: "body too large" }, 413);
  const text = await request.text();
  if (text.length > MAX_BODY_BYTES) return json({ error: "body too large" }, 413);
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    return json({ error: "body is not JSON" }, 400);
  }
  const parsed = parseRegistration(body);
  if (parsed.error) return json({ error: parsed.error }, 400);
  const { installId, platform, environment, tokens, channels } = parsed;

  const now = Date.now();
  const statements = [
    env.DB.prepare(
      `INSERT INTO installs (install_id, platform, environment, app_token, widget_token, last_seen)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6)
       ON CONFLICT (install_id) DO UPDATE SET
         platform = excluded.platform,
         environment = excluded.environment,
         app_token = CASE WHEN ?7 THEN excluded.app_token ELSE installs.app_token END,
         widget_token = CASE WHEN ?8 THEN excluded.widget_token ELSE installs.widget_token END,
         last_seen = excluded.last_seen`,
    ).bind(
      installId,
      platform,
      environment,
      tokens.app ?? null,
      tokens.widget ?? null,
      now,
      tokens.app !== undefined ? 1 : 0,
      tokens.widget !== undefined ? 1 : 0,
    ),
  ];
  if (channels) {
    // The list is the install's whole set: channels it no longer reports are gone.
    statements.push(env.DB.prepare("DELETE FROM channels WHERE install_id = ?").bind(installId));
    for (let i = 0; i < channels.length; i += CHANNEL_ROWS_PER_INSERT) {
      const rows = channels.slice(i, i + CHANNEL_ROWS_PER_INSERT);
      statements.push(
        env.DB.prepare(
          `INSERT INTO channels (channel_id, install_id, expiry) VALUES ${rows.map(() => "(?, ?, ?)").join(", ")}
           ON CONFLICT (channel_id) DO UPDATE SET install_id = excluded.install_id, expiry = excluded.expiry`,
        ).bind(...rows.flatMap((channel) => [channel.id, installId, channel.expiry])),
      );
    }
  }
  try {
    await env.DB.batch(statements);
  } catch (error) {
    console.error(`day-push: register failed: ${error?.name ?? "Error"}`);
    return json({ error: "storage unavailable" }, 503);
  }
  return json({ channelToken: await channelToken(env.HMAC_KEY, installId) }, 200);
}

// DELETE /day/devices/<install>: forget an install and its channels.
async function handleDelete(request, env, rawId) {
  if (request.method !== "DELETE") return json({ error: "method not allowed" }, 405, { allow: "DELETE" });
  let installId = null;
  try {
    installId = normalizeInstallId(decodeURIComponent(rawId));
  } catch {
    // Malformed escape: not a UUID either.
  }
  if (!installId) return json({ error: "install must be a UUID" }, 400);
  try {
    await env.DB.batch([
      env.DB.prepare("DELETE FROM channels WHERE install_id = ?").bind(installId),
      env.DB.prepare("DELETE FROM installs WHERE install_id = ?").bind(installId),
    ]);
    await coalescer(env, installId).forget();
  } catch (error) {
    console.error(`day-push: delete failed: ${error?.name ?? "Error"}`);
    return json({ error: "storage unavailable" }, 503);
  }
  return new Response(null, { status: 204 });
}

export function parseRegistration(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) return { error: "body must be an object" };
  const installId = normalizeInstallId(body.install);
  if (!installId) return { error: "install must be a UUID" };
  if (body.platform !== "ios" && body.platform !== "macos") return { error: "platform must be ios or macos" };
  if (body.environment !== "sandbox" && body.environment !== "production") {
    return { error: "environment must be sandbox or production" };
  }

  // A token given as a string is set, null clears it, and a missing one is kept.
  const tokens = {};
  const given = body.tokens ?? {};
  if (typeof given !== "object" || Array.isArray(given)) return { error: "tokens must be an object" };
  for (const name of ["app", "widget"]) {
    const value = given[name];
    if (value === undefined) continue;
    if (value === null) {
      tokens[name] = null;
      continue;
    }
    if (typeof value !== "string" || !PUSH_TOKEN.test(value.toLowerCase())) {
      return { error: `tokens.${name} must be a hex push token` };
    }
    tokens[name] = value.toLowerCase();
  }
  // The Mac gets only the background push.
  if (body.platform === "macos") tokens.widget = null;

  let channels = null;
  if (body.channels !== undefined) {
    if (!Array.isArray(body.channels)) return { error: "channels must be an array" };
    if (body.channels.length > MAX_CHANNELS) return { error: `at most ${MAX_CHANNELS} channels` };
    channels = [];
    for (const channel of body.channels) {
      if (!channel || typeof channel.id !== "string" || !CHANNEL_ID.test(channel.id)) {
        return { error: "channels[].id must be a Google channel ID" };
      }
      // Google returns the expiration as milliseconds since the epoch, in a string.
      const expiry = typeof channel.expiration === "string" ? Number(channel.expiration) : channel.expiration;
      if (!Number.isSafeInteger(expiry) || expiry <= 0) {
        return { error: "channels[].expiration must be milliseconds since the epoch" };
      }
      channels.push({ id: channel.id, expiry });
    }
  }
  return { installId, platform: body.platform, environment: body.environment, tokens, channels };
}

/** Drops expired channels, then installs that have none left and stopped registering. */
export async function cleanup(env, now) {
  await env.DB.prepare("DELETE FROM channels WHERE expiry < ?").bind(now).run();
  const { results } = await env.DB.prepare(
    `SELECT install_id FROM installs
     WHERE last_seen < ? AND NOT EXISTS (SELECT 1 FROM channels WHERE channels.install_id = installs.install_id)
     LIMIT ?`,
  )
    .bind(now - STALE_INSTALL_MS, MAX_FORGET_PER_RUN)
    .all();
  if (results.length === 0) return 0;
  await env.DB.prepare(`DELETE FROM installs WHERE install_id IN (${results.map(() => "?").join(", ")})`)
    .bind(...results.map((row) => row.install_id))
    .run();
  await Promise.all(results.map((row) => coalescer(env, row.install_id).forget()));
  return results.length;
}

function coalescer(env, installId) {
  return env.COALESCER.get(env.COALESCER.idFromName(installId));
}

function json(value, status, headers = {}) {
  return Response.json(value, { status, headers });
}
