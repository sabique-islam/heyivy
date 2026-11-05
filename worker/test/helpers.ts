import { createExecutionContext, env, waitOnExecutionContext } from "cloudflare:test";
import worker from "../src/index";

export const REVOKED_DEVICE_ID = "revokedDeviceId0000000";

function base64Url(bytes: ArrayBuffer): string {
  return btoa(String.fromCharCode(...new Uint8Array(bytes)))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

export function uniqueDeviceId(): string {
  const randomBytes = crypto.getRandomValues(new Uint8Array(16));
  return base64Url(randomBytes.buffer);
}

/** Signs independently of the Worker, so a bug in its verifier can't hide here. */
export async function mintToken(
  deviceId: string = uniqueDeviceId(),
  options: { expiresAtSeconds?: number; signingKey?: string } = {},
): Promise<string> {
  const expiresAtSeconds = options.expiresAtSeconds ?? Math.floor(Date.now() / 1000) + 3600;
  const signedPart = `ivy1.${deviceId}.${expiresAtSeconds}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(options.signingKey ?? env.DEVICE_TOKEN_SIGNING_KEY),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(signedPart));
  return `${signedPart}.${base64Url(signature)}`;
}

export async function callWorker(
  path: string,
  init: RequestInit & { token?: string } = {},
  testEnv: Env = env,
): Promise<Response> {
  const { token, ...requestInit } = init;
  const headers = new Headers(requestInit.headers);
  if (token) headers.set("authorization", `Bearer ${token}`);
  const context = createExecutionContext();
  const request = new Request(`https://secrets.worker.ivy.ivyx.me${path}`, {
    method: "POST",
    ...requestInit,
    headers,
  }) as Parameters<typeof worker.fetch>[0];
  const response = await worker.fetch(request, testEnv, context);
  // A streaming response is only finished once its body is read, so don't wait on it here.
  if (!response.body) await waitOnExecutionContext(context);
  return response;
}

export function jsonBody(body: unknown): RequestInit {
  return { body: JSON.stringify(body), headers: { "content-type": "application/json" } };
}

export const VALID_CHAT_BODY = {
  system: "You are a tutor.",
  messages: [{ role: "user", content: "hello" }],
};

export function sseStream(frames: string[]): ReadableStream<Uint8Array> {
  const encoder = new TextEncoder();
  return new ReadableStream({
    start(controller) {
      for (const frame of frames) controller.enqueue(encoder.encode(frame));
      controller.close();
    },
  });
}

export function spendFor(deviceId: string): Promise<{ todayMicroDollars: number }> {
  return env.DEVICE_LIMITER.getByName(deviceId).readSpend();
}
