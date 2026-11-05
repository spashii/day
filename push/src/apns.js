// APNs over plain fetch. A Worker's outbound fetch speaks HTTP/2 to Apple, so no
// HTTP/2 client or community package is needed.

import { base64urlEncode } from "./token.js";

const HOSTS = {
  sandbox: "https://api.sandbox.push.apple.com",
  production: "https://api.push.apple.com",
};

// Apple wants the provider token refreshed between every 20 and 60 minutes.
// Issuing it at the start of a 30 minute window makes every isolate use the same
// issue time, so many isolates never look like a token being renewed too often.
const TOKEN_WINDOW_SECONDS = 30 * 60;

// Apple's reasons for a token that will never work again: drop it.
export const DEAD_TOKEN_REASONS = new Set(["BadDeviceToken", "Unregistered"]);

const encoder = new TextEncoder();
let signingKey = null; // { pem, key }
let cached = null; // { keyId, iat, jwt }

function importKey(pem) {
  if (signingKey?.pem !== pem) {
    const body = pem.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "").replace(/\s+/g, "");
    const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
    const key = crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
    signingKey = { pem, key };
  }
  return signingKey.key;
}

/** The ES256 provider token, or null while the APNs key is not configured. */
export async function providerToken(env, now = Date.now()) {
  if (!env.APNS_KEY || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) return null;
  const iat = Math.floor(now / 1000 / TOKEN_WINDOW_SECONDS) * TOKEN_WINDOW_SECONDS;
  if (cached && cached.keyId === env.APNS_KEY_ID && cached.iat === iat) return cached.jwt;
  const header = base64urlEncode(encoder.encode(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })));
  const claims = base64urlEncode(encoder.encode(JSON.stringify({ iss: env.APNS_TEAM_ID, iat })));
  const input = `${header}.${claims}`;
  // WebCrypto returns the raw r||s signature, which is the JWS form.
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    await importKey(env.APNS_KEY),
    encoder.encode(input),
  );
  const jwt = `${input}.${base64urlEncode(new Uint8Array(signature))}`;
  cached = { keyId: env.APNS_KEY_ID, iat, jwt };
  return jwt;
}

/**
 * The request for one push.
 * kind "background": wakes the app for a sync (iPhone and Mac).
 * kind "widgets": asks WidgetKit to reload Day's widgets (iPhone).
 */
export function pushRequest(env, { environment, kind, token, jwt, now = Date.now() }) {
  const headers = {
    authorization: `bearer ${jwt}`,
    "content-type": "application/json",
    // A device that is offline gets the newest push when it comes back, for an hour.
    "apns-expiration": String(Math.floor(now / 1000) + 3600),
  };
  let body;
  if (kind === "widgets") {
    headers["apns-push-type"] = "widgets";
    headers["apns-topic"] = `${env.APNS_TOPIC}.push-type.widgets`;
    body = { aps: { "content-changed": true } };
  } else {
    headers["apns-push-type"] = "background";
    headers["apns-topic"] = env.APNS_TOPIC;
    headers["apns-priority"] = "5";
    body = { aps: { "content-available": 1 } };
  }
  const host = HOSTS[environment] ?? HOSTS.production;
  return new Request(`${host}/3/device/${token}`, { method: "POST", headers, body: JSON.stringify(body) });
}

/** Sends one push. Resolves to { ok, status, reason }; never throws. */
export async function sendPush(env, options) {
  try {
    const response = await fetch(pushRequest(env, options));
    if (response.ok) {
      await response.body?.cancel();
      return { ok: true, status: response.status, reason: null };
    }
    let reason = null;
    try {
      const parsed = await response.json();
      // Apple's reasons are short identifiers; anything else is not logged.
      if (typeof parsed?.reason === "string" && /^[A-Za-z]{1,64}$/.test(parsed.reason)) reason = parsed.reason;
    } catch {
      // No JSON body.
    }
    return { ok: false, status: response.status, reason };
  } catch (error) {
    return { ok: false, status: 0, reason: error?.name === "TypeError" ? "NetworkError" : "FetchFailed" };
  }
}
