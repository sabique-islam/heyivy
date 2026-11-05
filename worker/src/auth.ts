import { SIGNING_KEY_MINIMUM_LENGTH } from "./policy";
import { RequestRejectedError } from "./http";

// ivy1.<16 random bytes as base64url>.<expiry, unix seconds>.<HMAC-SHA256 as base64url>
const DEVICE_TOKEN_PATTERN = /^Bearer (ivy1\.([A-Za-z0-9_-]{22})\.(\d{10}))\.([A-Za-z0-9_-]{43})$/;

function decodeBase64Url(encoded: string): Uint8Array<ArrayBuffer> {
  const binary = atob(encoded.replaceAll("-", "+").replaceAll("_", "/"));
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

/**
 * Returns the device ID, or null if the request isn't from a device we issued a token to.
 *
 * The signature is what makes this safe to run on every request from the internet: it
 * costs no storage, and nobody reaches a Durable Object or a vendor without passing it.
 */
export async function authenticateDevice(request: Request, env: Env): Promise<string | null> {
  // A missing or weak key must lock everyone out, never let everyone in.
  if ((env.DEVICE_TOKEN_SIGNING_KEY ?? "").length < SIGNING_KEY_MINIMUM_LENGTH) {
    console.log(JSON.stringify({ event: "signing_key_misconfigured" }));
    throw new RequestRejectedError("service_unavailable");
  }

  const tokenMatch = DEVICE_TOKEN_PATTERN.exec(request.headers.get("authorization") ?? "");
  if (!tokenMatch) return null;
  const [, signedPart, deviceId, expiresAtSeconds, encodedSignature] = tokenMatch as unknown as [
    string,
    string,
    string,
    string,
    string,
  ];

  const signingKey = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(env.DEVICE_TOKEN_SIGNING_KEY),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );
  // subtle.verify compares in constant time, so the signature can't be guessed byte by byte.
  const signatureIsValid = await crypto.subtle.verify(
    "HMAC",
    signingKey,
    decodeBase64Url(encodedSignature),
    new TextEncoder().encode(signedPart),
  );
  if (!signatureIsValid) return null;

  if (Number(expiresAtSeconds) * 1000 <= Date.now()) return null;

  const revokedDeviceIds = env.REVOKED_DEVICE_IDS.split(",").map((revokedDeviceId) => revokedDeviceId.trim());
  if (revokedDeviceIds.includes(deviceId)) return null;

  return deviceId;
}
