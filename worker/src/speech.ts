import {
  errorResponse,
  hasOnlyKeys,
  isAbortError,
  isPlainObject,
  readBoundedJson,
  rejectVendorFailure,
  RequestRejectedError,
} from "./http";
import {
  SPEECH_MICRO_DOLLARS_PER_CHARACTER,
  SPEECH_MODEL,
  TTS_MAX_BODY_BYTES,
  TTS_MAX_CHARACTERS,
  TTS_TIMEOUT_MS,
  VOICE_CONNECT_TIMEOUT_MS,
  VOICE_MAX_CHARACTERS_PER_CONNECTION,
  VOICE_MAX_CONNECTION_MS,
  VOICE_MAX_FRAME_BYTES,
  VOICE_RESERVED_CHARACTERS_PER_BLOCK,
  VOICE_VENDOR_INACTIVITY_TIMEOUT_SECONDS,
} from "./policy";
import { DeviceSpend } from "./spend";

const ALLOWED_VOICE_SETTINGS = ["stability", "similarity_boost"];

function voiceSettingsAreValid(voiceSettings: unknown): boolean {
  if (voiceSettings === undefined) return true;
  if (!isPlainObject(voiceSettings) || !hasOnlyKeys(voiceSettings, ALLOWED_VOICE_SETTINGS)) return false;
  return Object.values(voiceSettings).every(
    (setting) => typeof setting === "number" && setting >= 0 && setting <= 1,
  );
}

export async function handleTextToSpeech(request: Request, env: Env, spend: DeviceSpend): Promise<Response> {
  const body = await readBoundedJson(request, TTS_MAX_BODY_BYTES);
  // The app sends model_id, which is accepted and ignored. The server picks the model.
  if (!isPlainObject(body) || !hasOnlyKeys(body, ["text", "model_id", "voice_settings"])) {
    throw new RequestRejectedError("invalid_request");
  }
  const { text, voice_settings: voiceSettings } = body;
  if (typeof text !== "string" || text.length === 0 || text.length > TTS_MAX_CHARACTERS) {
    throw new RequestRejectedError("invalid_request");
  }
  if (!voiceSettingsAreValid(voiceSettings)) {
    throw new RequestRejectedError("invalid_request");
  }

  await spend.reserveOrReject("tts", text.length * SPEECH_MICRO_DOLLARS_PER_CHARACTER);

  let upstreamResponse: Response;
  try {
    upstreamResponse = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${env.ELEVENLABS_VOICE_ID}`, {
      method: "POST",
      headers: {
        "xi-api-key": env.ELEVENLABS_API_KEY,
        "content-type": "application/json",
        accept: "audio/mpeg",
      },
      body: JSON.stringify({
        text,
        model_id: SPEECH_MODEL,
        ...(voiceSettings !== undefined ? { voice_settings: voiceSettings } : {}),
      }),
      signal: AbortSignal.any([request.signal, AbortSignal.timeout(TTS_TIMEOUT_MS)]),
    });
  } catch (error) {
    spend.refund();
    return errorResponse(isAbortError(error) ? "upstream_timeout" : "upstream_error");
  }

  if (!upstreamResponse.ok) {
    spend.refund();
    throw rejectVendorFailure("tts", upstreamResponse.status);
  }

  return new Response(upstreamResponse.body, {
    headers: {
      "content-type": upstreamResponse.headers.get("content-type") ?? "audio/mpeg",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    },
  });
}

const ALLOWED_VOICE_FRAME_KEYS = ["text", "flush", "try_trigger_generation", "voice_settings", "generation_config"];

// Application-defined close codes, so the app can tell these apart.
const CLOSE_CODE_INVALID_FRAME = 4400;
const CLOSE_CODE_SPEND_LIMIT = 4429;
const CLOSE_CODE_CONNECTION_LIMIT = 4408;

/** Returns the frame's text if it's safe to forward, or null if it must end the connection. */
function readVoiceFrameText(frameData: string | ArrayBuffer): string | null {
  if (typeof frameData !== "string" || frameData.length > VOICE_MAX_FRAME_BYTES) return null;
  let frame: unknown;
  try {
    frame = JSON.parse(frameData);
  } catch {
    return null;
  }
  // The allow-list is what keeps a caller from setting their own vendor key.
  if (!isPlainObject(frame) || !hasOnlyKeys(frame, ALLOWED_VOICE_FRAME_KEYS)) return null;
  if (frame.text !== undefined && typeof frame.text !== "string") return null;
  return (frame.text as string | undefined) ?? "";
}

/** Close codes 1005 and 1006 describe a close but can't be sent, so they become a normal one. */
function sendableCloseCode(closeCode: number): number {
  return closeCode === 1000 || (closeCode >= 3000 && closeCode <= 4999) ? closeCode : 1000;
}

function closeQuietly(socket: WebSocket, closeCode: number): void {
  try {
    socket.close(closeCode);
  } catch {
    // It was already closed, which is the state we wanted.
  }
}

/**
 * Relays one lesson's speech to ElevenLabs over a WebSocket. Text streams in as Claude
 * writes it, and audio with character timings streams back, untouched.
 *
 * Audio frames aren't inspected, so ElevenLabs messages pass through as they arrive.
 */
export async function handleVoice(request: Request, env: Env, spend: DeviceSpend): Promise<Response> {
  if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
    throw new RequestRejectedError("upgrade_required", { upgrade: "websocket" });
  }

  const microDollarsPerBlock = VOICE_RESERVED_CHARACTERS_PER_BLOCK * SPEECH_MICRO_DOLLARS_PER_CHARACTER;
  await spend.reserveOrReject("voice", microDollarsPerBlock);

  const vendorUrl = new URL(`https://api.elevenlabs.io/v1/text-to-speech/${env.ELEVENLABS_VOICE_ID}/stream-input`);
  vendorUrl.searchParams.set("model_id", SPEECH_MODEL);
  vendorUrl.searchParams.set("output_format", "pcm_24000");
  vendorUrl.searchParams.set("sync_alignment", "true");
  vendorUrl.searchParams.set("inactivity_timeout", String(VOICE_VENDOR_INACTIVITY_TIMEOUT_SECONDS));

  const connectAbort = new AbortController();
  const connectTimer = setTimeout(() => connectAbort.abort(), VOICE_CONNECT_TIMEOUT_MS);
  let vendorResponse: Response;
  try {
    vendorResponse = await fetch(vendorUrl.toString(), {
      headers: { upgrade: "websocket", "xi-api-key": env.ELEVENLABS_API_KEY },
      signal: connectAbort.signal,
    });
  } catch (error) {
    spend.refund();
    return errorResponse(isAbortError(error) ? "upstream_timeout" : "upstream_error");
  } finally {
    clearTimeout(connectTimer);
  }

  const vendorSocket = vendorResponse.webSocket;
  if (!vendorSocket) {
    spend.refund();
    throw rejectVendorFailure("voice", vendorResponse.status);
  }

  const clientPair = new WebSocketPair();
  const clientSocket = clientPair[0];
  const workerSocket = clientPair[1];
  workerSocket.accept();
  vendorSocket.accept();

  let charactersSent = 0;
  let charactersReserved = VOICE_RESERVED_CHARACTERS_PER_BLOCK;
  let connectionIsOpen = true;

  const endConnection = (closeCode: number): void => {
    if (!connectionIsOpen) return;
    connectionIsOpen = false;
    clearTimeout(connectionLimitTimer);
    closeQuietly(vendorSocket, sendableCloseCode(closeCode));
    closeQuietly(workerSocket, sendableCloseCode(closeCode));
    spend.settle(charactersSent * SPEECH_MICRO_DOLLARS_PER_CHARACTER);
  };

  const connectionLimitTimer = setTimeout(() => endConnection(CLOSE_CODE_CONNECTION_LIMIT), VOICE_MAX_CONNECTION_MS);

  // Checking spend means waiting on the limiter, so frames queue up to keep their order.
  let frameQueue: Promise<void> = Promise.resolve();

  workerSocket.addEventListener("message", (event) => {
    frameQueue = frameQueue
      .then(async () => {
        if (!connectionIsOpen) return;
        const frameData = event.data as string | ArrayBuffer;
        const text = readVoiceFrameText(frameData);
        if (text === null) {
          endConnection(CLOSE_CODE_INVALID_FRAME);
          return;
        }

        const charactersAfterFrame = charactersSent + text.length;
        if (charactersAfterFrame > VOICE_MAX_CHARACTERS_PER_CONNECTION) {
          endConnection(CLOSE_CODE_CONNECTION_LIMIT);
          return;
        }
        if (charactersAfterFrame > charactersReserved) {
          const blocksNeeded = Math.ceil(
            (charactersAfterFrame - charactersReserved) / VOICE_RESERVED_CHARACTERS_PER_BLOCK,
          );
          const reservedMore = await spend.reserveMore(blocksNeeded * microDollarsPerBlock);
          if (!reservedMore) {
            endConnection(CLOSE_CODE_SPEND_LIMIT);
            return;
          }
          charactersReserved += blocksNeeded * VOICE_RESERVED_CHARACTERS_PER_BLOCK;
        }

        charactersSent = charactersAfterFrame;
        vendorSocket.send(frameData as string);
      })
      .catch(() => {
        // A limiter failure mustn't let text through unmetered, so it ends the connection.
        console.log(JSON.stringify({ event: "voice_frame_failed" }));
        endConnection(1011);
      });
  });

  vendorSocket.addEventListener("message", (event) => {
    if (!connectionIsOpen) return;
    workerSocket.send(event.data as string);
  });

  workerSocket.addEventListener("close", (event) => endConnection(event.code));
  vendorSocket.addEventListener("close", (event) => endConnection(event.code));
  workerSocket.addEventListener("error", () => endConnection(1011));
  vendorSocket.addEventListener("error", () => endConnection(1011));

  return new Response(null, { status: 101, webSocket: clientSocket });
}
