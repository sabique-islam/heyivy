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
  ANTHROPIC_API_VERSION,
  CHAT_ALLOWED_IMAGE_TYPES,
  CHAT_EFFORT,
  CHAT_FIRST_RESPONSE_TIMEOUT_MS,
  CHAT_INPUT_MICRO_DOLLARS_PER_TOKEN,
  CHAT_MAX_BODY_BYTES,
  CHAT_MAX_IMAGE_BASE64_CHARACTERS,
  CHAT_MAX_IMAGES,
  CHAT_MAX_MESSAGES,
  CHAT_MAX_OUTPUT_TOKENS,
  CHAT_MAX_SYSTEM_CHARACTERS,
  CHAT_MAX_TEXT_CHARACTERS_PER_BLOCK,
  CHAT_MODEL,
  CHAT_OUTPUT_MICRO_DOLLARS_PER_TOKEN,
  CHAT_RESERVED_TOKENS_PER_IMAGE,
  CHAT_RESERVED_TOKENS_PER_TEXT_CHARACTER,
  CHAT_STREAM_IDLE_TIMEOUT_MS,
  CHAT_STREAM_TOTAL_TIMEOUT_MS,
} from "./policy";
import { DeviceSpend } from "./spend";

interface ValidatedChatRequest {
  system?: string;
  messages: unknown[];
  textCharacterCount: number;
  imageCount: number;
}

function rejectInvalid(): never {
  throw new RequestRejectedError("invalid_request");
}

/**
 * Builds the request from an allow-list rather than forwarding the body. Anything that
 * could change the model, enable tools or raise the cost simply has nowhere to go.
 *
 * The app still sends `model`, `max_tokens` and `stream`, so those are accepted and
 * ignored. Non-streaming is refused, because the Worker always streams.
 */
function validateChatRequest(body: unknown): ValidatedChatRequest {
  if (!isPlainObject(body)) rejectInvalid();
  if (!hasOnlyKeys(body, ["system", "messages", "model", "max_tokens", "stream"])) rejectInvalid();
  if (body.stream !== undefined && body.stream !== true) rejectInvalid();

  const { system, messages } = body;
  if (system !== undefined && (typeof system !== "string" || system.length > CHAT_MAX_SYSTEM_CHARACTERS)) {
    rejectInvalid();
  }
  if (!Array.isArray(messages) || messages.length === 0 || messages.length > CHAT_MAX_MESSAGES) rejectInvalid();

  let textCharacterCount = typeof system === "string" ? system.length : 0;
  let imageCount = 0;

  function countText(text: unknown): void {
    if (typeof text !== "string" || text.length > CHAT_MAX_TEXT_CHARACTERS_PER_BLOCK) rejectInvalid();
    textCharacterCount += text.length;
  }

  function checkContentBlock(block: unknown, role: string): void {
    if (!isPlainObject(block)) rejectInvalid();
    if (block.type === "text") {
      if (!hasOnlyKeys(block, ["type", "text"])) rejectInvalid();
      countText(block.text);
    } else if (block.type === "image" && role === "user") {
      const source = block.source;
      if (!hasOnlyKeys(block, ["type", "source"]) || !isPlainObject(source)) rejectInvalid();
      if (!hasOnlyKeys(source, ["type", "media_type", "data"]) || source.type !== "base64") rejectInvalid();
      if (!CHAT_ALLOWED_IMAGE_TYPES.includes(source.media_type as string)) rejectInvalid();
      if (typeof source.data !== "string" || source.data.length > CHAT_MAX_IMAGE_BASE64_CHARACTERS) rejectInvalid();
      imageCount += 1;
      if (imageCount > CHAT_MAX_IMAGES) rejectInvalid();
    } else {
      rejectInvalid();
    }
  }

  for (const message of messages) {
    if (!isPlainObject(message) || !hasOnlyKeys(message, ["role", "content"])) rejectInvalid();
    const { role, content } = message;
    if (role !== "user" && role !== "assistant") rejectInvalid();
    if (Array.isArray(content)) {
      if (content.length === 0) rejectInvalid();
      for (const block of content) checkContentBlock(block, role);
    } else {
      countText(content);
    }
  }

  const lastMessage = messages[messages.length - 1] as { role: string };
  if (lastMessage.role !== "user") rejectInvalid();

  return {
    ...(typeof system === "string" ? { system } : {}),
    messages,
    textCharacterCount,
    imageCount,
  };
}

/** Reads token usage out of the stream without changing a byte of what the client gets. */
class ChatUsageReader {
  private readonly decoder = new TextDecoder();
  private unfinishedLine = "";
  private inputMicroDollars = 0;
  private outputTokens = 0;
  private sawFinalUsage = false;

  observe(chunk: Uint8Array): void {
    this.unfinishedLine += this.decoder.decode(chunk, { stream: true });
    const lines = this.unfinishedLine.split("\n");
    this.unfinishedLine = lines.pop() ?? "";
    for (const line of lines) {
      if (line.startsWith("data: ") && line.includes('"usage"')) this.readUsageLine(line.slice(6));
    }
  }

  private readUsageLine(json: string): void {
    let event: {
      type?: string;
      message?: { usage?: Record<string, number> };
      usage?: Record<string, number>;
    };
    try {
      event = JSON.parse(json);
    } catch {
      return;
    }
    if (event.type === "message_start" && event.message?.usage) {
      const usage = event.message.usage;
      this.inputMicroDollars =
        (usage.input_tokens ?? 0) * CHAT_INPUT_MICRO_DOLLARS_PER_TOKEN +
        Math.ceil((usage.cache_creation_input_tokens ?? 0) * CHAT_INPUT_MICRO_DOLLARS_PER_TOKEN * 1.25) +
        Math.ceil((usage.cache_read_input_tokens ?? 0) * CHAT_INPUT_MICRO_DOLLARS_PER_TOKEN * 0.1);
    } else if (event.type === "message_delta" && event.usage) {
      this.outputTokens = event.usage.output_tokens ?? this.outputTokens;
      this.sawFinalUsage = true;
    }
  }

  /** Null when the stream ended early and the true cost isn't known. */
  actualMicroDollars(): number | null {
    if (!this.sawFinalUsage) return null;
    return this.inputMicroDollars + this.outputTokens * CHAT_OUTPUT_MICRO_DOLLARS_PER_TOKEN;
  }
}

export async function handleChat(request: Request, env: Env, spend: DeviceSpend): Promise<Response> {
  const chatRequest = validateChatRequest(await readBoundedJson(request, CHAT_MAX_BODY_BYTES));

  const reservedInputTokens =
    chatRequest.textCharacterCount * CHAT_RESERVED_TOKENS_PER_TEXT_CHARACTER +
    chatRequest.imageCount * CHAT_RESERVED_TOKENS_PER_IMAGE;
  await spend.reserveOrReject(
    "chat",
    Math.ceil(
      reservedInputTokens * CHAT_INPUT_MICRO_DOLLARS_PER_TOKEN +
        CHAT_MAX_OUTPUT_TOKENS * CHAT_OUTPUT_MICRO_DOLLARS_PER_TOKEN,
    ),
  );

  // One controller, so a client disconnect, a stall and the total deadline all stop the spend.
  const upstreamAbort = new AbortController();
  const abortUpstream = (): void => upstreamAbort.abort();
  request.signal?.addEventListener("abort", abortUpstream);
  const totalDeadline = setTimeout(abortUpstream, CHAT_STREAM_TOTAL_TIMEOUT_MS);
  let stallTimer = setTimeout(abortUpstream, CHAT_FIRST_RESPONSE_TIMEOUT_MS);
  const stopTimers = (): void => {
    clearTimeout(totalDeadline);
    clearTimeout(stallTimer);
    request.signal?.removeEventListener("abort", abortUpstream);
  };

  let upstreamResponse: Response;
  try {
    upstreamResponse = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": env.ANTHROPIC_API_KEY,
        "anthropic-version": ANTHROPIC_API_VERSION,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: CHAT_MODEL,
        max_tokens: CHAT_MAX_OUTPUT_TOKENS,
        stream: true,
        output_config: { effort: CHAT_EFFORT },
        thinking: { type: "between_tools" },
        ...(chatRequest.system !== undefined ? { system: chatRequest.system } : {}),
        messages: chatRequest.messages,
      }),
      signal: upstreamAbort.signal,
    });
  } catch (error) {
    stopTimers();
    spend.refund();
    if (isAbortError(error)) return errorResponse("upstream_timeout");
    console.log(JSON.stringify({ event: "vendor_unreachable", route: "chat" }));
    return errorResponse("upstream_error");
  }

  if (!upstreamResponse.ok || !upstreamResponse.body) {
    stopTimers();
    upstreamAbort.abort();
    spend.refund();
    throw rejectVendorFailure("chat", upstreamResponse.status);
  }

  const upstreamReader = upstreamResponse.body.getReader();
  const usageReader = new ChatUsageReader();

  // pull() runs only when the client is ready for more, so nothing buffers here,
  // and each chunk reaches the client as soon as Claude produces it.
  const clientStream = new ReadableStream<Uint8Array>(
    {
      async pull(controller) {
        clearTimeout(stallTimer);
        stallTimer = setTimeout(abortUpstream, CHAT_STREAM_IDLE_TIMEOUT_MS);
        try {
          const { done, value } = await upstreamReader.read();
          if (done) {
            stopTimers();
            const actualMicroDollars = usageReader.actualMicroDollars();
            if (actualMicroDollars !== null) spend.settle(actualMicroDollars);
            controller.close();
            return;
          }
          usageReader.observe(value);
          controller.enqueue(value);
        } catch {
          // Headers are gone, so ending the stream early is the only signal left.
          // The reservation stands, because Claude may have billed for this.
          stopTimers();
          console.log(JSON.stringify({ event: "stream_interrupted", route: "chat" }));
          controller.error(new Error("stream interrupted"));
        }
      },
      cancel() {
        // The client left, usually an interrupt. Stop Claude now and keep the reservation,
        // since the true cost of a stopped stream isn't reported.
        stopTimers();
        upstreamAbort.abort();
        console.log(JSON.stringify({ event: "client_cancelled", route: "chat" }));
      },
    },
    { highWaterMark: 0 },
  );

  return new Response(clientStream, {
    headers: {
      "content-type": "text/event-stream",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    },
  });
}
