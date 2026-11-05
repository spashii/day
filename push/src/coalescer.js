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
//
// What the object stores, and nothing else: the install ID while a push is
// pending, and the send times of the last hour's accepted widget pushes. One
// alarm does two jobs. After a notification it is the end of the coalescing
// window. Otherwise it is the moment the oldest send time turns an hour old,
// when it deletes that time and arms itself for the next one, so the list is
// gone an hour after the last widget push and no send time outlives its hour.
// The install ID is the one signal that tells the two apart: it is stored only
// while a push is pending. This is the per-device promise on the privacy page
// (see "Stored per device" in README.md): adding anything here needs the copy
// owner's sign-off first.

import { DurableObject } from "cloudflare:workers";
import { DEAD_TOKEN_REASONS, providerToken, sendPush } from "./apns.js";

// The first WIDGET_BURST widget pushes in any hour go out at once; after that at
// most one every WIDGET_SPACING_MS.
const WIDGET_BURST = 3;
const WIDGET_HOUR_MS = 60 * 60 * 1000;
const WIDGET_SPACING_MS = 15 * 60 * 1000;
const WIDGET_SENDS_KEY = "widgetPushes";
const INSTALL_KEY = "install"; // present only while a push is pending

export class InstallCoalescer extends DurableObject {
  /** Schedules a push at the end of the window, unless one is already pending. */
  async notify(installId) {
    const storage = this.ctx.storage;
    const now = Date.now();
    const pending = await storage.getAlarm();
    // A future alarm covers this notification only if it is a push alarm, which
    // is when an install ID is stored. Otherwise it is the alarm that deletes
    // old send times, and the window replaces it until the push re-arms it.
    // An alarm at or before now is firing, possibly with a sync already under
    // way, so schedule another.
    if (pending !== null && pending > now && (await storage.get(INSTALL_KEY)) !== undefined) return;
    await storage.put(INSTALL_KEY, installId);
    await storage.setAlarm(now + windowMs(this.env));
  }

  async alarm() {
    const storage = this.ctx.storage;
    const now = Date.now();
    const installId = await storage.get(INSTALL_KEY);
    const sends = recentWidgetSends((await storage.get(WIDGET_SENDS_KEY)) ?? [], now);
    if (installId) {
      const results = await pushInstall(this.env, installId, { now, widgets: widgetPushAllowed(sends, now) });
      // A push Apple refused spent no budget, so only accepted ones count.
      if (results.some((result) => result.kind === "widgets" && result.ok)) sends.push(now);
    }
    if (sends.length > 0) await storage.put(WIDGET_SENDS_KEY, sends);
    else await storage.delete(WIDGET_SENDS_KEY);
    // A notification that came in while the push was in flight set a new alarm,
    // later than this run started. Leave it: it keeps the install ID, and its
    // own run prunes and re-arms.
    const next = await storage.getAlarm();
    if (next !== null && next > now) return;
    await storage.delete(INSTALL_KEY);
    if (sends.length > 0) await storage.setAlarm(sends[0] + WIDGET_HOUR_MS);
  }

  /**
   * Deletes send times older than an hour, and the list once it is empty. The
   * daily cleanup calls it for every install, so a list that was written before
   * the deletion alarm existed, or whose alarm was lost, does not outlive its
   * hour. Returns how many send times it deleted. A pending push keeps its
   * alarm: that run prunes and re-arms on its own.
   */
  async prune(now = Date.now()) {
    const storage = this.ctx.storage;
    const stored = await storage.get(WIDGET_SENDS_KEY);
    if (stored === undefined) return 0;
    const sends = recentWidgetSends(stored, now);
    if (sends.length < stored.length) {
      if (sends.length > 0) await storage.put(WIDGET_SENDS_KEY, sends);
      else await storage.delete(WIDGET_SENDS_KEY);
    }
    if ((await storage.get(INSTALL_KEY)) === undefined) {
      if (sends.length > 0) await storage.setAlarm(sends[0] + WIDGET_HOUR_MS);
      else await storage.deleteAlarm();
    }
    return stored.length - sends.length;
  }

  /** Drops the pending push, the stored install ID and the send times. */
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
