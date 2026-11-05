// One Durable Object per install, addressed by the install ID. It turns a burst
// of Google notifications into one push per COALESCE_MS window.
//
// Why a Durable Object rather than a timestamp in D1: a D1 timestamp can only
// throttle on the leading edge, so a change that lands just after a push would
// be dropped until the device's timer catches it. Sending once at the end of the
// window needs a timer that survives the request, and an alarm is exactly that,
// retried by the runtime if it fails. Calls for one install are serialized here,
// so two notifications in the same millisecond cannot both schedule a push, and
// D1 takes no write per notification.
//
// The object also rate limits the WidgetKit push. Apple budgets those pushes per
// app, and the app's own reloadTimelines draws on the same budget, so a burst of
// calendar changes (a colleague reorganizing a shared calendar) would leave the
// Lock Screen without reloads for the rest of the day. The background push is
// not limited here: iOS throttles it on its own.

import { DurableObject } from "cloudflare:workers";
import { DEAD_TOKEN_REASONS, providerToken, sendPush } from "./apns.js";

// The first WIDGET_BURST widget pushes in any hour go out at once; after that at
// most one every WIDGET_SPACING_MS.
const WIDGET_BURST = 3;
const WIDGET_HOUR_MS = 60 * 60 * 1000;
const WIDGET_SPACING_MS = 15 * 60 * 1000;
const WIDGET_SENDS_KEY = "widgetPushes";

export class InstallCoalescer extends DurableObject {
  /** Schedules a push at the end of the window, unless one is already pending. */
  async notify(installId) {
    const storage = this.ctx.storage;
    const now = Date.now();
    const pending = await storage.getAlarm();
    // An alarm in the future already covers this notification. One at or before
    // now is firing, possibly with a sync already under way, so schedule another.
    if (pending !== null && pending > now) return;
    await storage.put("install", installId);
    await storage.setAlarm(now + windowMs(this.env));
  }

  async alarm() {
    const storage = this.ctx.storage;
    const installId = await storage.get("install");
    if (!installId) return;
    const now = Date.now();
    const sends = recentWidgetSends((await storage.get(WIDGET_SENDS_KEY)) ?? [], now);
    const results = await pushInstall(this.env, installId, { now, widgets: widgetPushAllowed(sends, now) });
    // A push Apple refused spent no budget, so only accepted ones count.
    if (results.some((result) => result.kind === "widgets" && result.ok)) sends.push(now);
    if (sends.length > 0) await storage.put(WIDGET_SENDS_KEY, sends);
    else await storage.delete(WIDGET_SENDS_KEY);
  }

  /** Drops the pending push and the stored install ID. */
  async forget() {
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
  }
}

/** The send times still inside the last hour, oldest first. */
export function recentWidgetSends(sends, now) {
  return sends.filter((time) => time > now - WIDGET_HOUR_MS);
}

/** Whether a widget push may go out, given the send times from recentWidgetSends. */
export function widgetPushAllowed(sends, now) {
  if (sends.length < WIDGET_BURST) return true;
  return now - sends[sends.length - 1] >= WIDGET_SPACING_MS;
}

function windowMs(env) {
  const value = Number(env.COALESCE_MS);
  return Number.isFinite(value) && value >= 0 ? value : 3000;
}

/**
 * Sends the pushes one install should get: the background push to the app, and
 * on iPhone also the WidgetKit push unless `widgets` is false (rate limited).
 * Tokens Apple calls dead are removed.
 */
export async function pushInstall(env, installId, { now = Date.now(), widgets = true } = {}) {
  const install = await env.DB.prepare(
    "SELECT platform, environment, app_token, widget_token FROM installs WHERE install_id = ?",
  )
    .bind(installId)
    .first();
  if (!install) return [];

  const pushes = [];
  if (install.app_token) pushes.push({ column: "app_token", kind: "background", token: install.app_token });
  if (widgets && install.platform === "ios" && install.widget_token) {
    pushes.push({ column: "widget_token", kind: "widgets", token: install.widget_token });
  }
  if (pushes.length === 0) return [];

  const jwt = await providerToken(env, now);
  if (!jwt) {
    console.warn("day-push: APNs key not configured, push skipped");
    return [];
  }

  const results = await Promise.all(
    pushes.map(async (push) => ({
      ...push,
      ...(await sendPush(env, { environment: install.environment, kind: push.kind, token: push.token, jwt, now })),
    })),
  );

  const drops = [];
  for (const result of results) {
    if (result.ok) continue;
    if (DEAD_TOKEN_REASONS.has(result.reason)) {
      // Only clear the token we sent to: the device may have re-registered meanwhile.
      drops.push(
        env.DB.prepare(`UPDATE installs SET ${result.column} = NULL WHERE install_id = ? AND ${result.column} = ?`).bind(
          installId,
          result.token,
        ),
      );
    }
    console.warn(`day-push: APNs ${result.kind} push failed: ${result.status} ${result.reason ?? "no reason"}`);
  }
  if (drops.length) await env.DB.batch(drops);
  return results.map(({ kind, ok, status, reason }) => ({ kind, ok, status, reason }));
}
