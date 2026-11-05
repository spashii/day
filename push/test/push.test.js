import { env, runDurableObjectAlarm, runInDurableObject, SELF } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { providerToken } from "../src/apns.js";
import worker, { cleanup } from "../src/index.js";

const BASE = "https://apps.idea2prod.in";
const IPHONE = "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b";
const MAC = "0a1b2c3d-4e5f-4a6b-8c7d-8e9f0a1b2c3d";
const APP_TOKEN = "a".repeat(64);
const WIDGET_TOKEN = "b".repeat(64);
const MAC_TOKEN = "c".repeat(64);
const EMAIL = "someone.private@example.com";
const RESOURCE_URI = `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(EMAIL)}/events?alt=json`;

let apnsCalls;
let apnsReplies;
let realFetch;

// Durable Object storage outlives a test, so each one starts with empty objects.
beforeEach(async () => {
  for (const installId of [IPHONE, MAC]) {
    await runInDurableObject(coalescer(installId), (instance) => instance.forget());
  }
  apnsCalls = [];
  apnsReplies = [];
  realFetch = globalThis.fetch;
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input, init);
    const url = new URL(request.url);
    if (!url.hostname.endsWith("push.apple.com")) return realFetch(input, init);
    apnsCalls.push({
      host: url.hostname,
      path: url.pathname,
      headers: Object.fromEntries(request.headers),
      body: await request.json(),
    });
    const reply = apnsReplies.shift();
    if (reply instanceof Error) throw reply;
    if (!reply) return new Response(null, { status: 200, headers: { "apns-id": crypto.randomUUID() } });
    return Response.json({ reason: reply.reason }, { status: reply.status });
  });
});

afterEach(() => {
  vi.restoreAllMocks();
});

function register(body) {
  return SELF.fetch(`${BASE}/day/devices`, { method: "POST", body: JSON.stringify(body) });
}

function notify(channelToken, state = "exists", channelId = "chan-1") {
  return SELF.fetch(`${BASE}/day/push`, {
    method: "POST",
    headers: {
      "X-Goog-Channel-ID": channelId,
      "X-Goog-Channel-Token": channelToken,
      "X-Goog-Channel-Expiration": "Tue, 12 Nov 2026 10:00:00 GMT",
      "X-Goog-Message-Number": "2",
      "X-Goog-Resource-ID": "resource-id-1",
      "X-Goog-Resource-State": state,
      "X-Goog-Resource-URI": RESOURCE_URI,
    },
  });
}

function coalescer(installId) {
  return env.COALESCER.get(env.COALESCER.idFromName(installId));
}

function pendingAlarm(installId) {
  return runInDurableObject(coalescer(installId), (_instance, state) => state.storage.getAlarm());
}

async function registerIphone(extra = {}) {
  const response = await register({
    install: IPHONE,
    platform: "ios",
    environment: "sandbox",
    tokens: { app: APP_TOKEN, widget: WIDGET_TOKEN },
    channels: [
      { id: "chan-1", expiration: String(Date.now() + 86_400_000) },
      { id: "chan-2", expiration: Date.now() + 86_400_000 },
    ],
    ...extra,
  });
  expect(response.status).toBe(200);
  return (await response.json()).channelToken;
}

async function registerMac() {
  const response = await register({
    install: MAC,
    platform: "macos",
    environment: "production",
    tokens: { app: MAC_TOKEN, widget: WIDGET_TOKEN },
    channels: [{ id: "mac-chan-1", expiration: Date.now() + 86_400_000 }],
  });
  expect(response.status).toBe(200);
  return (await response.json()).channelToken;
}

function widgetCalls() {
  return apnsCalls.filter((call) => call.headers["apns-push-type"] === "widgets");
}

function backgroundCalls() {
  return apnsCalls.filter((call) => call.headers["apns-push-type"] === "background");
}

// Widget push send times as the Durable Object keeps them, given as minutes ago.
function seedWidgetSends(installId, minutesAgo) {
  const now = Date.now();
  return runInDurableObject(coalescer(installId), (_instance, state) =>
    state.storage.put("widgetPushes", minutesAgo.map((minutes) => now - minutes * 60_000)),
  );
}

function storedWidgetSends(installId) {
  return runInDurableObject(coalescer(installId), (_instance, state) => state.storage.get("widgetPushes"));
}

// One Google change, then the end of its coalescing window.
async function changeAndWait(token, installId = IPHONE, channelId = "chan-1") {
  await notify(token, "exists", channelId);
  await runDurableObjectAlarm(coalescer(installId));
}

function installRow(installId) {
  return env.DB.prepare("SELECT * FROM installs WHERE install_id = ?").bind(installId).first();
}

describe("POST /day/devices", () => {
  it("registers an install and returns a channel token bound to it", async () => {
    const token = await registerIphone();
    expect(token).toMatch(new RegExp(`^${IPHONE}\\.[A-Za-z0-9_-]{43}$`));
    expect(token.length).toBeLessThanOrEqual(256);
    const row = await installRow(IPHONE);
    expect(row).toMatchObject({ platform: "ios", environment: "sandbox", app_token: APP_TOKEN, widget_token: WIDGET_TOKEN });
    const { results } = await env.DB.prepare("SELECT channel_id FROM channels WHERE install_id = ? ORDER BY channel_id")
      .bind(IPHONE)
      .all();
    expect(results.map((r) => r.channel_id)).toEqual(["chan-1", "chan-2"]);
  });

  it("keeps omitted tokens, clears null ones and replaces the channel set", async () => {
    await registerIphone();
    const newApp = "d".repeat(64);
    const response = await register({
      install: IPHONE.toUpperCase(),
      platform: "ios",
      environment: "sandbox",
      tokens: { app: newApp },
      channels: [{ id: "chan-3", expiration: Date.now() + 1000 }],
    });
    expect(response.status).toBe(200);
    let row = await installRow(IPHONE);
    expect(row.app_token).toBe(newApp);
    expect(row.widget_token).toBe(WIDGET_TOKEN);
    const { results } = await env.DB.prepare("SELECT channel_id FROM channels WHERE install_id = ?").bind(IPHONE).all();
    expect(results.map((r) => r.channel_id)).toEqual(["chan-3"]);

    await register({ install: IPHONE, platform: "ios", environment: "sandbox", tokens: { widget: null } });
    row = await installRow(IPHONE);
    expect(row.widget_token).toBeNull();
    expect(row.app_token).toBe(newApp);
  });

  it("stores nothing about an install beyond its tokens, platform and last registration", async () => {
    const { results } = await env.DB.prepare("PRAGMA table_info(installs)").all();
    expect(results.map((column) => column.name)).toEqual([
      "install_id",
      "platform",
      "environment",
      "app_token",
      "widget_token",
      "last_seen",
    ]);
    const channels = await env.DB.prepare("PRAGMA table_info(channels)").all();
    expect(channels.results.map((column) => column.name)).toEqual(["channel_id", "install_id", "expiry"]);

    await registerIphone();
    expect(Object.keys(await installRow(IPHONE)).sort()).toEqual(
      ["app_token", "environment", "install_id", "last_seen", "platform", "widget_token"],
    );
  });

  it("never stores a widget token for a Mac", async () => {
    await registerMac();
    expect((await installRow(MAC)).widget_token).toBeNull();
  });

  it("rejects malformed registrations", async () => {
    const good = { install: IPHONE, platform: "ios", environment: "sandbox" };
    for (const body of [
      { ...good, install: "not-a-uuid" },
      { ...good, platform: "android" },
      { ...good, environment: "staging" },
      { ...good, tokens: { app: "zz" } },
      { ...good, channels: [{ id: "has spaces", expiration: 1 }] },
      { ...good, channels: [{ id: "ok", expiration: "soon" }] },
      { ...good, channels: "nope" },
    ]) {
      expect((await register(body)).status, JSON.stringify(body)).toBe(400);
    }
    expect((await SELF.fetch(`${BASE}/day/devices`, { method: "POST", body: "{" })).status).toBe(400);
  });
});

describe("POST /day/push", () => {
  it("rejects tokens it did not issue", async () => {
    const token = await registerIphone();
    expect((await notify("")).status).toBe(401);
    expect((await notify(`${IPHONE}.${"A".repeat(43)}`)).status).toBe(401);
    expect((await notify(`${MAC}${token.slice(IPHONE.length)}`)).status).toBe(401);
    expect(await pendingAlarm(IPHONE)).toBeNull();
  });

  it("answers sync at once and schedules nothing", async () => {
    const token = await registerIphone();
    const response = await notify(token, "sync");
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("");
    expect(await pendingAlarm(IPHONE)).toBeNull();
  });

  it("coalesces a burst into one push per window", async () => {
    const token = await registerIphone();
    const before = Date.now();
    const responses = await Promise.all([notify(token), notify(token, "exists", "chan-2"), notify(token)]);
    expect(responses.map((r) => r.status)).toEqual([200, 200, 200]);
    const alarm = await pendingAlarm(IPHONE);
    expect(alarm).toBeGreaterThanOrEqual(before + 3000);
    expect(alarm).toBeLessThanOrEqual(Date.now() + 3000);
    expect(apnsCalls).toHaveLength(0);

    expect(await runDurableObjectAlarm(coalescer(IPHONE))).toBe(true);
    expect(apnsCalls).toHaveLength(2);
    expect(await runDurableObjectAlarm(coalescer(IPHONE))).toBe(false);

    // The next change after the window opens a new one.
    await notify(token);
    expect(await pendingAlarm(IPHONE)).not.toBeNull();
  });

  it("sends a WidgetKit push and a background push to an iPhone", async () => {
    const token = await registerIphone();
    await notify(token);
    await runDurableObjectAlarm(coalescer(IPHONE));
    const widget = apnsCalls.find((c) => c.headers["apns-push-type"] === "widgets");
    const background = apnsCalls.find((c) => c.headers["apns-push-type"] === "background");
    expect(widget).toMatchObject({
      host: "api.sandbox.push.apple.com",
      path: `/3/device/${WIDGET_TOKEN}`,
      body: { aps: { "content-changed": true } },
    });
    expect(widget.headers["apns-topic"]).toBe("io.github.spashii.day.push-type.widgets");
    expect(background).toMatchObject({
      host: "api.sandbox.push.apple.com",
      path: `/3/device/${APP_TOKEN}`,
      body: { aps: { "content-available": 1 } },
    });
    expect(background.headers["apns-topic"]).toBe("io.github.spashii.day");
    expect(background.headers["apns-priority"]).toBe("5");
    await expectValidJwt(background.headers.authorization);
  });

  it("sends only a background push to a Mac, on the production host", async () => {
    const token = await registerMac();
    await notify(token, "exists", "mac-chan-1");
    await runDurableObjectAlarm(coalescer(MAC));
    expect(apnsCalls).toHaveLength(1);
    expect(apnsCalls[0]).toMatchObject({ host: "api.push.apple.com", path: `/3/device/${MAC_TOKEN}` });
    expect(apnsCalls[0].headers["apns-push-type"]).toBe("background");
  });

  it("drops tokens Apple reports dead and keeps the rest", async () => {
    const token = await registerIphone();
    await notify(token);
    apnsReplies = [
      { status: 410, reason: "Unregistered" },
      { status: 400, reason: "BadDeviceToken" },
    ];
    await runDurableObjectAlarm(coalescer(IPHONE));
    let row = await installRow(IPHONE);
    expect(row.app_token).toBeNull();
    expect(row.widget_token).toBeNull();

    await registerIphone();
    await notify(token);
    apnsReplies = [{ status: 403, reason: "InvalidProviderToken" }, new TypeError("network down")];
    await runDurableObjectAlarm(coalescer(IPHONE));
    row = await installRow(IPHONE);
    expect(row.app_token).toBe(APP_TOKEN);
    expect(row.widget_token).toBe(WIDGET_TOKEN);
  });

  it("does not wake an install for a channel it no longer holds", async () => {
    const token = await registerIphone();
    await registerMac();
    // Never registered, registered by another install, and no channel header at all.
    expect((await notify(token, "exists", "stopped-chan")).status).toBe(200);
    expect((await notify(token, "exists", "mac-chan-1")).status).toBe(200);
    expect((await notify(token, "exists", "has spaces")).status).toBe(200);
    const noChannel = await SELF.fetch(`${BASE}/day/push`, {
      method: "POST",
      headers: { "X-Goog-Channel-Token": token, "X-Goog-Resource-State": "exists" },
    });
    expect(noChannel.status).toBe(200);
    expect(await pendingAlarm(IPHONE)).toBeNull();
    expect(await pendingAlarm(MAC)).toBeNull();

    // A channel the device dropped from its set stops waking it, the others do not.
    await register({
      install: IPHONE,
      platform: "ios",
      environment: "sandbox",
      channels: [{ id: "chan-2", expiration: Date.now() + 86_400_000 }],
    });
    await notify(token, "exists", "chan-1");
    expect(await pendingAlarm(IPHONE)).toBeNull();
    await notify(token, "exists", "chan-2");
    expect(await pendingAlarm(IPHONE)).not.toBeNull();
  });

  it("does not wake anything for an install that was deleted", async () => {
    const token = await registerIphone();
    expect((await SELF.fetch(`${BASE}/day/devices/${IPHONE}`, { method: "DELETE" })).status).toBe(204);
    expect((await notify(token)).status).toBe(200);
    expect(await pendingAlarm(IPHONE)).toBeNull();
  });
});

describe("widget push rate limit", () => {
  it("sends the first three in an hour, then holds the widget push back and keeps the background push", async () => {
    const token = await registerIphone();
    for (let i = 0; i < 6; i++) await changeAndWait(token);
    expect(widgetCalls()).toHaveLength(3);
    expect(backgroundCalls()).toHaveLength(6);
    expect(await storedWidgetSends(IPHONE)).toHaveLength(3);
  });

  it("allows one more every 15 minutes once the first three are spent", async () => {
    const token = await registerIphone();
    await seedWidgetSends(IPHONE, [50, 40, 14]);
    await changeAndWait(token);
    expect(widgetCalls()).toHaveLength(0);
    expect(await storedWidgetSends(IPHONE)).toHaveLength(3);

    await seedWidgetSends(IPHONE, [50, 40, 16]);
    await changeAndWait(token);
    expect(widgetCalls()).toHaveLength(1);
    // The 50 minute old send is still inside the hour, so it is kept.
    expect(await storedWidgetSends(IPHONE)).toHaveLength(4);
    expect(backgroundCalls()).toHaveLength(2);
  });

  it("counts only the last hour and prunes older send times", async () => {
    const token = await registerIphone();
    await seedWidgetSends(IPHONE, [130, 100, 70, 1]);
    await changeAndWait(token);
    expect(widgetCalls()).toHaveLength(1);
    expect(await storedWidgetSends(IPHONE)).toHaveLength(2);

    await seedWidgetSends(IPHONE, [30, 1]);
    await changeAndWait(token);
    expect(widgetCalls()).toHaveLength(2);
  });

  it("does not count a push Apple refused", async () => {
    const token = await registerIphone();
    await notify(token);
    apnsReplies = [{ status: 200 }, { status: 403, reason: "InvalidProviderToken" }];
    await runDurableObjectAlarm(coalescer(IPHONE));
    expect(await storedWidgetSends(IPHONE)).toBeUndefined();
  });

  it("limits each install on its own and sends a Mac nothing to count", async () => {
    const iphoneToken = await registerIphone();
    const macToken = await registerMac();
    await seedWidgetSends(IPHONE, [50, 40, 1]);
    await changeAndWait(iphoneToken);
    await changeAndWait(macToken, MAC, "mac-chan-1");
    expect(widgetCalls()).toHaveLength(0);
    expect(backgroundCalls()).toHaveLength(2);
    expect(await storedWidgetSends(MAC)).toBeUndefined();
  });

  it("forgets the send times with the install", async () => {
    const token = await registerIphone();
    await changeAndWait(token);
    expect(await storedWidgetSends(IPHONE)).toHaveLength(1);
    await SELF.fetch(`${BASE}/day/devices/${IPHONE}`, { method: "DELETE" });
    expect(await storedWidgetSends(IPHONE)).toBeUndefined();
  });
});

describe("DELETE /day/devices/<install>", () => {
  it("removes the install, its channels and any pending push", async () => {
    const token = await registerIphone();
    await notify(token);
    expect(await pendingAlarm(IPHONE)).not.toBeNull();
    expect((await SELF.fetch(`${BASE}/day/devices/${IPHONE}`, { method: "DELETE" })).status).toBe(204);
    expect(await installRow(IPHONE)).toBeNull();
    const { results } = await env.DB.prepare("SELECT * FROM channels WHERE install_id = ?").bind(IPHONE).all();
    expect(results).toHaveLength(0);
    expect(await pendingAlarm(IPHONE)).toBeNull();
    expect((await SELF.fetch(`${BASE}/day/devices/%E0%A4%A`, { method: "DELETE" })).status).toBe(400);
  });
});

describe("cleanup cron", () => {
  it("drops expired channels and installs that went quiet", async () => {
    const now = Date.now();
    await registerIphone({ channels: [{ id: "old", expiration: now - 1 }, { id: "live", expiration: now + 60_000 }] });
    await registerMac();
    await env.DB.prepare("UPDATE installs SET last_seen = ?").bind(now - 40 * 86_400_000).run();
    await env.DB.prepare("UPDATE channels SET expiry = ? WHERE install_id = ?").bind(now - 1, MAC).run();

    expect(await cleanup(env, now)).toBe(1);
    const channels = await env.DB.prepare("SELECT channel_id FROM channels").all();
    expect(channels.results.map((r) => r.channel_id)).toEqual(["live"]);
    expect(await installRow(MAC)).toBeNull();
    expect(await installRow(IPHONE)).not.toBeNull();
  });
});

describe("provider token", () => {
  it("keeps one issue time per 30 minute window", async () => {
    const start = Math.floor(Date.now() / 1_800_000) * 1_800_000;
    const a = await providerToken(env, start + 1000);
    const b = await providerToken(env, start + 25 * 60_000);
    const c = await providerToken(env, start + 31 * 60_000);
    expect(b).toBe(a);
    expect(c).not.toBe(a);
    await expectValidJwt(`bearer ${c}`);
  });
});

// The approval's hard rule: X-Goog-Resource-URI holds the calendar ID, often an
// email address, and must never reach a log line or storage, on any path.
describe("privacy", () => {
  it("never logs or stores the resource URI, on success and error paths", async () => {
    const lines = [];
    for (const method of ["log", "info", "warn", "error", "debug", "trace"]) {
      vi.spyOn(console, method).mockImplementation((...args) => {
        lines.push(args.map((arg) => (typeof arg === "string" ? arg : safeStringify(arg))).join(" "));
      });
    }

    const token = await registerIphone();
    await notify(token, "sync");
    await notify(token);
    await notify(`${IPHONE}.forged`);
    await notify(token, "not_exists");
    // A channel the install no longer holds, and a notification without a channel ID.
    await notify(token, "exists", "stopped-chan");
    await SELF.fetch(`${BASE}/day/push`, {
      method: "POST",
      headers: { "X-Goog-Channel-Token": token, "X-Goog-Resource-State": "exists", "X-Goog-Resource-URI": RESOURCE_URI },
    });
    // Apple refuses both pushes, so the alarm path logs.
    apnsReplies = [{ status: 403, reason: "ExpiredProviderToken" }, new TypeError("connection reset")];
    await runDurableObjectAlarm(coalescer(IPHONE));

    // Storage failing mid-request must not leak the request either.
    const failingEnv = {
      ...env,
      DB: {
        prepare() {
          throw new Error("D1_ERROR: storage is down");
        },
      },
    };
    const request = new Request(`${BASE}/day/push`, {
      method: "POST",
      headers: {
        "X-Goog-Channel-ID": "chan-1",
        "X-Goog-Channel-Token": token,
        "X-Goog-Resource-State": "exists",
        "X-Goog-Resource-URI": RESOURCE_URI,
      },
    });
    expect((await worker.fetch(request, failingEnv)).status).toBe(503);

    // The capture works: the failing paths above did log.
    expect(lines.some((line) => line.includes("APNs"))).toBe(true);
    expect(lines.some((line) => line.includes("push notification failed"))).toBe(true);

    const needles = [EMAIL, encodeURIComponent(EMAIL), RESOURCE_URI, "someone.private", "calendars/"];
    for (const line of lines) {
      for (const needle of needles) expect(line).not.toContain(needle);
    }

    const dump = JSON.stringify([
      (await env.DB.prepare("SELECT * FROM installs").all()).results,
      (await env.DB.prepare("SELECT * FROM channels").all()).results,
      await runInDurableObject(coalescer(IPHONE), async (_i, state) => [...(await state.storage.list()).entries()]),
    ]);
    for (const needle of needles) expect(dump).not.toContain(needle);
  });
});

function safeStringify(value) {
  try {
    return value instanceof Error ? `${value.name}: ${value.message} ${value.stack}` : JSON.stringify(value);
  } catch {
    return String(value);
  }
}

async function expectValidJwt(authorization) {
  expect(authorization).toMatch(/^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
  const jwt = authorization.slice("bearer ".length);
  const [header, claims, signature] = jwt.split(".");
  const decode = (part) => JSON.parse(atob(part.replace(/-/g, "+").replace(/_/g, "/")));
  expect(decode(header)).toEqual({ alg: "ES256", kid: "TESTKEY123" });
  expect(decode(claims).iss).toBe("JMCP69LCSU");
  const key = await crypto.subtle.importKey(
    "jwk",
    JSON.parse(env.TEST_APNS_PUBLIC_JWK),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
  const raw = Uint8Array.from(atob(signature.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    raw,
    new TextEncoder().encode(`${header}.${claims}`),
  );
  expect(ok).toBe(true);
}
