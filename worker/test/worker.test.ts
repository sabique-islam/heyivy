import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, type MockInstance, vi } from "vitest";
import { DAILY_SPEND_CAP_MICRO_DOLLARS, REQUESTS_PER_MINUTE } from "../src/policy";
import {
  REVOKED_DEVICE_ID,
  VALID_CHAT_BODY,
  callWorker,
  jsonBody,
  mintToken,
  spendFor,
  sseStream,
  uniqueDeviceId,
} from "./helpers";

let upstreamFetch: MockInstance<typeof fetch>;

const successfulStream = (): Response =>
  new Response(
    sseStream([
      'event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":100,"output_tokens":1}}}\n\n',
      'event: message_delta\ndata: {"type":"message_delta","usage":{"output_tokens":50}}\n\n',
      'event: message_stop\ndata: {"type":"message_stop"}\n\n',
    ]),
    { status: 200, headers: { "content-type": "text/event-stream" } },
  );

beforeEach(() => {
  upstreamFetch = vi.spyOn(globalThis, "fetch");
  upstreamFetch.mockImplementation(async () => {
    throw new Error("unexpected upstream call");
  });
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.useRealTimers();
});

describe("nobody without a valid token gets anywhere", () => {
  const validBody = jsonBody(VALID_CHAT_BODY);

  it.each([
    ["no header", {}],
    ["wrong scheme", { headers: { authorization: "Basic abc" } }],
    ["garbage", { headers: { authorization: "Bearer not-a-token" } }],
    ["empty bearer", { headers: { authorization: "Bearer " } }],
  ])("rejects %s", async (_name, init) => {
    const response = await callWorker("/chat", { ...validBody, ...init });
    expect(response.status).toBe(401);
    expect(upstreamFetch).not.toHaveBeenCalled();
  });

  it("rejects a tampered device ID", async () => {
    const token = await mintToken();
    const parts = token.split(".");
    parts[1] = uniqueDeviceId();
    const response = await callWorker("/chat", { ...validBody, token: parts.join(".") });
    expect(response.status).toBe(401);
  });

  it("rejects a pushed-out expiry", async () => {
    const parts = (await mintToken()).split(".");
    parts[2] = String(Number(parts[2]) + 100000);
    const response = await callWorker("/chat", { ...validBody, token: parts.join(".") });
    expect(response.status).toBe(401);
  });

  it("rejects a token signed with another key", async () => {
    const token = await mintToken(undefined, { signingKey: "a-different-signing-key-of-decent-length" });
    expect((await callWorker("/chat", { ...validBody, token })).status).toBe(401);
  });

  it("rejects an expired token", async () => {
    const token = await mintToken(undefined, { expiresAtSeconds: Math.floor(Date.now() / 1000) - 1 });
    expect((await callWorker("/chat", { ...validBody, token })).status).toBe(401);
  });

  it("rejects a revoked device whose signature is valid", async () => {
    const token = await mintToken(REVOKED_DEVICE_ID);
    expect((await callWorker("/chat", { ...validBody, token })).status).toBe(401);
    expect(upstreamFetch).not.toHaveBeenCalled();
  });

  it("does not accept a token in the query string", async () => {
    const token = await mintToken();
    expect((await callWorker(`/chat?token=${token}`, validBody)).status).toBe(401);
  });

  it("does not reveal which routes exist", async () => {
    const unknownRoute = await callWorker("/does-not-exist");
    const knownRoute = await callWorker("/chat");
    expect(unknownRoute.status).toBe(401);
    expect(await unknownRoute.text()).toBe(await knownRoute.text());
  });

  it("does not allow browsers to read responses", async () => {
    const response = await callWorker("/chat", { headers: { origin: "https://evil.example" } });
    expect(response.headers.get("access-control-allow-origin")).toBeNull();
  });

  it.each(["", "too-short"])("fails closed when the signing key is %j", async (signingKey) => {
    const token = await mintToken();
    const response = await callWorker("/chat", { ...validBody, token }, {
      ...env,
      DEVICE_TOKEN_SIGNING_KEY: signingKey,
    });
    expect(response.status).toBe(503);
    expect(upstreamFetch).not.toHaveBeenCalled();
  });
});

describe("routing", () => {
  it("returns 404 for an unknown route, and 405 for a wrong method, in one error shape", async () => {
    const token = await mintToken();
    const notFound = await callWorker("/nope", { token });
    expect(notFound.status).toBe(404);
    expect(await notFound.json()).toEqual({ error: { code: "not_found", message: expect.any(String) } });
    const wrongMethod = await callWorker("/chat", { token, method: "GET" });
    expect(wrongMethod.status).toBe(405);
    expect(wrongMethod.headers.get("allow")).toBe("POST");
  });
});

describe("/chat", () => {
  it("uses the server's model and limits, whatever the caller asks for", async () => {
    upstreamFetch.mockResolvedValue(successfulStream());
    const token = await mintToken();
    const response = await callWorker("/chat", {
      token,
      ...jsonBody({ ...VALID_CHAT_BODY, model: "claude-opus-5-5", max_tokens: 64000, stream: true }),
    });
    expect(response.status).toBe(200);
    await response.text();
    const [url, init] = upstreamFetch.mock.calls[0]!;
    expect(url).toBe("https://api.anthropic.com/v1/messages");
    const sentBody = JSON.parse(init!.body as string);
    expect(sentBody.model).toBe("claude-sonnet-5-5");
    expect(sentBody.max_tokens).toBe(2048);
    expect(sentBody.stream).toBe(true);
    expect(sentBody.output_config).toEqual({ effort: "low" });
    expect(sentBody.thinking).toEqual({ type: "between_tools" });
    const sentHeaders = new Headers(init!.headers);
    expect(sentHeaders.get("x-api-key")).toBe("test-anthropic-key");
    expect(sentHeaders.get("anthropic-version")).toBe("2026-10-21");
    expect(sentHeaders.get("authorization")).toBeNull();
  });

  it("passes the event stream through byte for byte", async () => {
    upstreamFetch.mockResolvedValue(successfulStream());
    const expected = await successfulStream().text();
    const response = await callWorker("/chat", { token: await mintToken(), ...jsonBody(VALID_CHAT_BODY) });
    expect(response.headers.get("content-type")).toBe("text/event-stream");
    expect(await response.text()).toBe(expected);
  });

  it("charges what the stream actually used", async () => {
    upstreamFetch.mockResolvedValue(successfulStream());
    const deviceId = uniqueDeviceId();
    const response = await callWorker("/chat", { token: await mintToken(deviceId), ...jsonBody(VALID_CHAT_BODY) });
    await response.text();
    // 100 input tokens at $2/MTok plus 50 output tokens at $10/MTok.
    await vi.waitFor(async () => expect((await spendFor(deviceId)).todayMicroDollars).toBe(700));
  });

  it("reads usage even when an event is split across chunks", async () => {
    const whole =
      'data: {"type":"message_start","message":{"usage":{"input_tokens":100}}}\n\ndata: {"type":"message_delta","usage":{"output_tokens":50}}\n\n';
    upstreamFetch.mockResolvedValue(
      new Response(sseStream(whole.match(/.{1,7}/gs)!), { headers: { "content-type": "text/event-stream" } }),
    );
    const deviceId = uniqueDeviceId();
    const response = await callWorker("/chat", { token: await mintToken(deviceId), ...jsonBody(VALID_CHAT_BODY) });
    await response.text();
    await vi.waitFor(async () => expect((await spendFor(deviceId)).todayMicroDollars).toBe(700));
  });

  it.each([
    ["tools", { ...VALID_CHAT_BODY, tools: [] }],
    ["a thinking override", { ...VALID_CHAT_BODY, thinking: { type: "adaptive" } }],
    ["non-streaming", { ...VALID_CHAT_BODY, stream: false }],
    ["no messages", { system: "x", messages: [] }],
    ["a system role", { messages: [{ role: "system", content: "x" }] }],
    ["ending on assistant", { messages: [{ role: "assistant", content: "x" }] }],
    ["a tool_use block", { messages: [{ role: "user", content: [{ type: "tool_use", id: "x", name: "y", input: {} }] }] }],
    ["a remote image", { messages: [{ role: "user", content: [{ type: "image", source: { type: "url", url: "https://x" } }] }] }],
    ["a gif", { messages: [{ role: "user", content: [{ type: "image", source: { type: "base64", media_type: "image/gif", data: "AAAA" } }] }] }],
    ["an oversized image", { messages: [{ role: "user", content: [{ type: "image", source: { type: "base64", media_type: "image/png", data: "A".repeat(7_000_001) } }] }] }],
    ["too many images", { messages: [{ role: "user", content: Array.from({ length: 7 }, () => ({ type: "image", source: { type: "base64", media_type: "image/png", data: "AAAA" } })) }] }],
    ["an oversized system prompt", { system: "x".repeat(32_001), messages: VALID_CHAT_BODY.messages }],
    ["too many messages", { messages: Array.from({ length: 42 }, () => ({ role: "user", content: "x" })) }],
    ["an extra block field", { messages: [{ role: "user", content: [{ type: "text", text: "x", cache_control: { type: "ephemeral" } }] }] }],
    ["an array body", []],
  ])("rejects %s without calling upstream", async (_name, body) => {
    const response = await callWorker("/chat", { token: await mintToken(), ...jsonBody(body) });
    expect(response.status).toBe(400);
    expect(((await response.json()) as { error: { code: string } }).error.code).toBe("invalid_request");
    expect(upstreamFetch).not.toHaveBeenCalled();
  });

  it("rejects a declared oversized body before reading it", async () => {
    const response = await callWorker("/chat", {
      token: await mintToken(),
      body: "{}",
      headers: { "content-type": "application/json", "content-length": "99999999" },
    });
    expect(response.status).toBe(413);
  });

  it("rejects an oversized body that doesn't declare its length", async () => {
    const oneMegabyte = new Uint8Array(1024 * 1024);
    let chunksSent = 0;
    const body = new ReadableStream({
      pull(controller) {
        chunksSent += 1;
        if (chunksSent > 40) controller.close();
        else controller.enqueue(oneMegabyte);
      },
    });
    const response = await callWorker("/chat", {
      token: await mintToken(),
      body,
      headers: { "content-type": "application/json" },
    });
    expect(response.status).toBe(413);
    expect(chunksSent).toBeLessThan(40);
  });

  it("rejects non-JSON and malformed JSON", async () => {
    const token = await mintToken();
    expect((await callWorker("/chat", { token, body: "x", headers: { "content-type": "text/plain" } })).status).toBe(415);
    expect((await callWorker("/chat", { token, body: "{", headers: { "content-type": "application/json" } })).status).toBe(400);
  });

  it.each([
    [401, 502],
    [400, 502],
    [500, 502],
    [429, 503],
    [529, 503],
  ])("hides a vendor %i behind a %i, logs no body, and refunds", async (vendorStatus, ourStatus) => {
    const logSpy = vi.spyOn(console, "log");
    upstreamFetch.mockResolvedValue(new Response('{"error":"VENDOR-SECRET-DETAIL"}', { status: vendorStatus }));
    const deviceId = uniqueDeviceId();
    const response = await callWorker("/chat", { token: await mintToken(deviceId), ...jsonBody(VALID_CHAT_BODY) });
    expect(response.status).toBe(ourStatus);
    const text = await response.text();
    expect(text).not.toContain("VENDOR-SECRET-DETAIL");
    expect(JSON.stringify(logSpy.mock.calls)).not.toContain("VENDOR-SECRET-DETAIL");
    expect((await spendFor(deviceId)).todayMicroDollars).toBe(0);
  });

  it("never logs the message, the token, or the full device ID", async () => {
    const logSpy = vi.spyOn(console, "log");
    upstreamFetch.mockResolvedValue(successfulStream());
    const deviceId = uniqueDeviceId();
    const token = await mintToken(deviceId);
    const response = await callWorker("/chat", {
      token,
      ...jsonBody({ messages: [{ role: "user", content: "PRIVATE-QUESTION" }] }),
    });
    await response.text();
    const logged = JSON.stringify(logSpy.mock.calls);
    expect(logged).not.toContain("PRIVATE-QUESTION");
    expect(logged).not.toContain(token);
    expect(logged).not.toContain(deviceId);
  });

  it("aborts the upstream call when the client cancels the stream", async () => {
    let upstreamSignal: AbortSignal | undefined;
    upstreamFetch.mockImplementation(async (_url, init) => {
      upstreamSignal = init!.signal!;
      return new Response(new ReadableStream({ pull: () => new Promise(() => {}) }), {
        headers: { "content-type": "text/event-stream" },
      });
    });
    const response = await callWorker("/chat", { token: await mintToken(), ...jsonBody(VALID_CHAT_BODY) });
    await response.body!.cancel();
    expect(upstreamSignal!.aborted).toBe(true);
  });

  it("times out when upstream never answers, and refunds", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    upstreamFetch.mockImplementation(
      (_url, init) =>
        new Promise((_resolve, reject) => {
          init!.signal!.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
        }),
    );
    const deviceId = uniqueDeviceId();
    const pending = callWorker("/chat", { token: await mintToken(deviceId), ...jsonBody(VALID_CHAT_BODY) });
    await vi.waitFor(() => expect(upstreamFetch).toHaveBeenCalled());
    await vi.advanceTimersByTimeAsync(30_001);
    const response = await pending;
    expect(response.status).toBe(504);
    vi.useRealTimers();
    expect((await spendFor(deviceId)).todayMicroDollars).toBe(0);
  });
});

describe("rate and spend caps", () => {
  it("returns 429 with retry-after past the per-minute limit, and doesn't call upstream", async () => {
    const token = await mintToken();
    const limiter = env.DEVICE_LIMITER.getByName(token.split(".")[1]!);
    const nowMs = Date.now();
    for (let requestNumber = 0; requestNumber < REQUESTS_PER_MINUTE.chat; requestNumber += 1) {
      await limiter.reserveSpend("chat", 0, nowMs);
    }
    const response = await callWorker("/chat", { token, ...jsonBody(VALID_CHAT_BODY) });
    expect(response.status).toBe(429);
    expect(((await response.json()) as { error: { code: string } }).error.code).toBe("rate_limited");
    expect(Number(response.headers.get("retry-after"))).toBeGreaterThan(0);
    expect(upstreamFetch).not.toHaveBeenCalled();
  });

  it("keeps each device's limits separate", async () => {
    upstreamFetch.mockImplementation(async () => successfulStream());
    const deviceId = uniqueDeviceId();
    const limiter = env.DEVICE_LIMITER.getByName(deviceId);
    await limiter.reserveSpend("chat", DAILY_SPEND_CAP_MICRO_DOLLARS, Date.now());
    const capped = await callWorker("/chat", { token: await mintToken(deviceId), ...jsonBody(VALID_CHAT_BODY) });
    expect(capped.status).toBe(429);
    const other = await callWorker("/chat", { token: await mintToken(), ...jsonBody(VALID_CHAT_BODY) });
    expect(other.status).toBe(200);
    await other.text();
  });

  it("returns spend_limit_reached when the daily cap would be passed", async () => {
    const deviceId = uniqueDeviceId();
    await env.DEVICE_LIMITER.getByName(deviceId).reserveSpend("chat", DAILY_SPEND_CAP_MICRO_DOLLARS - 1, Date.now());
    const response = await callWorker("/chat", { token: await mintToken(deviceId), ...jsonBody(VALID_CHAT_BODY) });
    expect(response.status).toBe(429);
    expect(((await response.json()) as { error: { code: string } }).error.code).toBe("spend_limit_reached");
    expect(upstreamFetch).not.toHaveBeenCalled();
  });

  it("can't be raced past the cap by parallel requests", async () => {
    const limiter = env.DEVICE_LIMITER.getByName(uniqueDeviceId());
    const costOfEachRequest = Math.floor(DAILY_SPEND_CAP_MICRO_DOLLARS / 5);
    const nowMs = Date.now();
    const results = await Promise.all(
      Array.from({ length: 20 }, () => limiter.reserveSpend("tts", costOfEachRequest, nowMs)),
    );
    expect(results.filter((result) => result.allowed)).toHaveLength(5);
  });

  it("opens the rate window again after a minute, but not the spend cap", async () => {
    const limiter = env.DEVICE_LIMITER.getByName(uniqueDeviceId());
    const startMs = Date.UTC(2026, 10, 5, 12, 0, 0);
    for (let requestNumber = 0; requestNumber < REQUESTS_PER_MINUTE.chat; requestNumber += 1) {
      await limiter.reserveSpend("chat", 0, startMs);
    }
    expect((await limiter.reserveSpend("chat", 0, startMs)).allowed).toBe(false);
    expect((await limiter.reserveSpend("chat", 0, startMs + 60_000)).allowed).toBe(true);
    await limiter.reserveSpend("tts", DAILY_SPEND_CAP_MICRO_DOLLARS, startMs + 60_000);
    expect((await limiter.reserveSpend("tts", 1, startMs + 120_000)).allowed).toBe(false);
    const nextDayMs = Date.UTC(2026, 10, 6, 0, 0, 1);
    expect((await limiter.reserveSpend("tts", 1, nextDayMs)).allowed).toBe(true);
  });

  it("enforces the monthly cap even with room left today", async () => {
    const limiter = env.DEVICE_LIMITER.getByName(uniqueDeviceId());
    for (let day = 1; day <= 6; day += 1) {
      const reservation = await limiter.reserveSpend("tts", DAILY_SPEND_CAP_MICRO_DOLLARS, Date.UTC(2026, 10, day, 12));
      expect(reservation.allowed).toBe(true);
    }
    expect((await limiter.reserveSpend("tts", 1, Date.UTC(2026, 10, 7, 12))).allowed).toBe(false);
  });
});

describe("/tts", () => {
  it("forces the voice and model, and returns audio", async () => {
    upstreamFetch.mockResolvedValue(new Response("audio", { headers: { "content-type": "audio/mpeg" } }));
    const response = await callWorker("/tts", {
      token: await mintToken(),
      ...jsonBody({ text: "hi", model_id: "eleven_multilingual_v2", voice_settings: { stability: 0.5, similarity_boost: 0.75 } }),
    });
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("audio");
    const [url, init] = upstreamFetch.mock.calls[0]!;
    expect(url).toBe("https://api.elevenlabs.io/v1/text-to-speech/test-voice-id");
    const sentBody = JSON.parse(init!.body as string);
    expect(sentBody.model_id).toBe("eleven_flash_v2_5");
    expect(sentBody.text).toBe("hi");
  });

  it.each([
    ["no text", {}],
    ["empty text", { text: "" }],
    ["too much text", { text: "x".repeat(5001) }],
    ["a caller-chosen voice", { text: "x", voice_id: "other" }],
    ["unknown voice settings", { text: "x", voice_settings: { style: 1 } }],
    ["out-of-range settings", { text: "x", voice_settings: { stability: 5 } }],
  ])("rejects %s", async (_name, body) => {
    const response = await callWorker("/tts", { token: await mintToken(), ...jsonBody(body) });
    expect(response.status).toBe(400);
    expect(upstreamFetch).not.toHaveBeenCalled();
  });

  it("charges per character, and refunds a vendor failure", async () => {
    upstreamFetch.mockResolvedValueOnce(new Response("audio"));
    const deviceId = uniqueDeviceId();
    const token = await mintToken(deviceId);
    await (await callWorker("/tts", { token, ...jsonBody({ text: "x".repeat(1000) }) })).text();
    await vi.waitFor(async () => expect((await spendFor(deviceId)).todayMicroDollars).toBe(50_000));
    upstreamFetch.mockResolvedValueOnce(new Response("VENDOR", { status: 500 }));
    const failed = await callWorker("/tts", { token, ...jsonBody({ text: "x".repeat(1000) }) });
    expect(failed.status).toBe(502);
    expect(await failed.text()).not.toContain("VENDOR");
    expect((await spendFor(deviceId)).todayMicroDollars).toBe(50_000);
  });
});

describe("/transcribe-token", () => {
  it("asks for a short-lived, short-session token and returns only the token", async () => {
    upstreamFetch.mockResolvedValue(Response.json({ token: "temporary", expires_in_seconds: 60, extra: "x" }));
    const response = await callWorker("/transcribe-token", { token: await mintToken() });
    expect(await response.json()).toEqual({ token: "temporary" });
    const [url, init] = upstreamFetch.mock.calls[0]!;
    const upstreamUrl = new URL(String(url));
    expect(upstreamUrl.origin + upstreamUrl.pathname).toBe("https://streaming.assemblyai.com/v3/token");
    expect(upstreamUrl.searchParams.get("expires_in_seconds")).toBe("60");
    expect(upstreamUrl.searchParams.get("max_session_duration_seconds")).toBe("300");
    expect(new Headers(init!.headers).get("authorization")).toBe("test-assemblyai-key");
  });

  it("hides a vendor error and refunds", async () => {
    upstreamFetch.mockResolvedValue(new Response("VENDOR", { status: 401 }));
    const deviceId = uniqueDeviceId();
    const response = await callWorker("/transcribe-token", { token: await mintToken(deviceId) });
    expect(response.status).toBe(502);
    expect(await response.text()).not.toContain("VENDOR");
    expect((await spendFor(deviceId)).todayMicroDollars).toBe(0);
  });

  it("rejects an upstream reply with no token", async () => {
    upstreamFetch.mockResolvedValue(Response.json({ nope: true }));
    expect((await callWorker("/transcribe-token", { token: await mintToken() })).status).toBe(502);
  });
});

describe("/voice", () => {
  function fakeVendorSocket(): { vendorSide: WebSocket; received: string[]; closed: () => boolean } {
    const pair = new WebSocketPair();
    const workerSide = pair[0];
    const vendorSide = pair[1];
    vendorSide.accept();
    const received: string[] = [];
    let wasClosed = false;
    vendorSide.addEventListener("message", (event) => received.push(event.data as string));
    vendorSide.addEventListener("close", () => {
      wasClosed = true;
    });
    upstreamFetch.mockImplementation(async () => new Response(null, { status: 101, webSocket: workerSide }));
    return { vendorSide, received, closed: () => wasClosed };
  }

  async function openVoice(token: string): Promise<WebSocket> {
    const response = await callWorker("/voice", { token, method: "GET", headers: { upgrade: "websocket" } });
    expect(response.status).toBe(101);
    const clientSide = response.webSocket!;
    clientSide.accept();
    return clientSide;
  }

  it("requires a WebSocket upgrade", async () => {
    const response = await callWorker("/voice", { token: await mintToken(), method: "GET" });
    expect(response.status).toBe(426);
  });

  it("requires a token before opening anything", async () => {
    const response = await callWorker("/voice", { method: "GET", headers: { upgrade: "websocket" } });
    expect(response.status).toBe(401);
    expect(upstreamFetch).not.toHaveBeenCalled();
  });

  it("fixes the voice, format and timing options on the vendor URL", async () => {
    fakeVendorSocket();
    await openVoice(await mintToken());
    const [url, init] = upstreamFetch.mock.calls[0]!;
    const upstreamUrl = new URL(String(url));
    expect(upstreamUrl.origin + upstreamUrl.pathname).toBe(
      "https://api.elevenlabs.io/v1/text-to-speech/test-voice-id/stream-input",
    );
    expect(upstreamUrl.searchParams.get("model_id")).toBe("eleven_flash_v2_5");
    expect(upstreamUrl.searchParams.get("output_format")).toBe("pcm_24000");
    expect(upstreamUrl.searchParams.get("sync_alignment")).toBe("true");
    expect(new Headers(init!.headers).get("xi-api-key")).toBe("test-elevenlabs-key");
  });

  it("relays text both ways, timing data intact", async () => {
    const vendor = fakeVendorSocket();
    const client = await openVoice(await mintToken());
    const fromVendor: string[] = [];
    client.addEventListener("message", (event) => fromVendor.push(event.data as string));
    client.send(JSON.stringify({ text: "hello " }));
    await vi.waitFor(() => expect(vendor.received).toEqual([JSON.stringify({ text: "hello " })]));
    const audioFrame = JSON.stringify({ audio: "AAAA", alignment: { chars: ["h"], charStartTimesMs: [0] } });
    vendor.vendorSide.send(audioFrame);
    await vi.waitFor(() => expect(fromVendor).toEqual([audioFrame]));
  });

  it("closes the vendor side when the client closes", async () => {
    const vendor = fakeVendorSocket();
    const client = await openVoice(await mintToken());
    client.close(1000);
    await vi.waitFor(() => expect(vendor.closed()).toBe(true));
  });

  it("closes the client when the vendor closes", async () => {
    const vendor = fakeVendorSocket();
    const client = await openVoice(await mintToken());
    let clientClosed = false;
    client.addEventListener("close", () => {
      clientClosed = true;
    });
    vendor.vendorSide.close(1000);
    await vi.waitFor(() => expect(clientClosed).toBe(true));
  });

  it.each([
    ["a smuggled vendor key", JSON.stringify({ text: "x", xi_api_key: "other" })],
    ["non-JSON", "not json"],
    ["a non-string text", JSON.stringify({ text: 5 })],
    ["a JSON array", "[]"],
  ])("closes the connection on %s, without forwarding it", async (_name, frame) => {
    const vendor = fakeVendorSocket();
    const client = await openVoice(await mintToken());
    client.send(frame);
    await vi.waitFor(() => expect(vendor.closed()).toBe(true));
    expect(vendor.received).toEqual([]);
  });

  it("closes the connection on binary frames", async () => {
    const vendor = fakeVendorSocket();
    const client = await openVoice(await mintToken());
    client.send(new Uint8Array([1, 2, 3]));
    await vi.waitFor(() => expect(vendor.closed()).toBe(true));
    expect(vendor.received).toEqual([]);
  });

  it("charges for characters sent past the first block, up to the connection limit", async () => {
    const vendor = fakeVendorSocket();
    const deviceId = uniqueDeviceId();
    const client = await openVoice(await mintToken(deviceId));
    for (let frameNumber = 0; frameNumber < 3; frameNumber += 1) {
      client.send(JSON.stringify({ text: "x".repeat(500) }));
    }
    await vi.waitFor(() => expect(vendor.received).toHaveLength(3));
    client.close(1000);
    await vi.waitFor(async () => expect((await spendFor(deviceId)).todayMicroDollars).toBe(75_000));
  });

  it("closes the connection when the spend cap runs out mid-lesson", async () => {
    const vendor = fakeVendorSocket();
    const deviceId = uniqueDeviceId();
    const client = await openVoice(await mintToken(deviceId));
    await env.DEVICE_LIMITER.getByName(deviceId).reserveSpend("tts", DAILY_SPEND_CAP_MICRO_DOLLARS - 26_000, Date.now());
    client.send(JSON.stringify({ text: "x".repeat(1000) }));
    await vi.waitFor(() => expect(vendor.closed()).toBe(true));
    expect(vendor.received).toEqual([]);
  });

  it("refunds when the vendor refuses the connection", async () => {
    upstreamFetch.mockResolvedValue(new Response("VENDOR", { status: 403 }));
    const deviceId = uniqueDeviceId();
    const response = await callWorker("/voice", {
      token: await mintToken(deviceId),
      method: "GET",
      headers: { upgrade: "websocket" },
    });
    expect(response.status).toBe(502);
    expect(await response.text()).not.toContain("VENDOR");
    expect((await spendFor(deviceId)).todayMicroDollars).toBe(0);
  });
});
