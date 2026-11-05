// Channel tokens: "<install ID>.<HMAC>", put by the device into events.watch and
// echoed by Google in X-Goog-Channel-Token. The HMAC under HMAC_KEY proves the
// install ID came from us, so spoofed notifications are rejected and no token is
// stored. Rotating HMAC_KEY invalidates every channel; devices recover when they
// next register and renew their watches.

const encoder = new TextEncoder();
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const keys = new Map();

/** Returns the install ID in canonical lower case, or null if it is not a UUID. */
export function normalizeInstallId(value) {
  if (typeof value !== "string") return null;
  const id = value.toLowerCase();
  return UUID.test(id) ? id : null;
}

function hmacKey(secret) {
  let key = keys.get(secret);
  if (!key) {
    key = crypto.subtle.importKey("raw", base64urlDecode(secret), { name: "HMAC", hash: "SHA-256" }, false, [
      "sign",
      "verify",
    ]);
    keys.set(secret, key);
  }
  return key;
}

function message(installId) {
  return encoder.encode(`day-push/channel/v1/${installId}`);
}

export async function channelToken(secret, installId) {
  const signature = await crypto.subtle.sign("HMAC", await hmacKey(secret), message(installId));
  return `${installId}.${base64urlEncode(new Uint8Array(signature))}`;
}

/** Returns the install ID the token was issued for, or null if the token is not ours. */
export async function verifyChannelToken(secret, token) {
  if (typeof token !== "string" || token.length > 256) return null;
  const dot = token.indexOf(".");
  if (dot < 0) return null;
  const installId = normalizeInstallId(token.slice(0, dot));
  if (!installId || installId !== token.slice(0, dot)) return null;
  let signature;
  try {
    signature = base64urlDecode(token.slice(dot + 1));
  } catch {
    return null;
  }
  // subtle.verify compares in constant time.
  const ok = await crypto.subtle.verify("HMAC", await hmacKey(secret), signature, message(installId));
  return ok ? installId : null;
}

export function base64urlEncode(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function base64urlDecode(text) {
  if (!/^[A-Za-z0-9_-]*$/.test(text)) throw new Error("not base64url");
  const base64 = text.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (text.length % 4)) % 4);
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}
