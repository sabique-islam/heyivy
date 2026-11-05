// Every error leaves in one shape, and vendor responses never appear in it.

export type ErrorCode =
  | "unauthorized"
  | "not_found"
  | "method_not_allowed"
  | "invalid_request"
  | "unsupported_media_type"
  | "payload_too_large"
  | "upgrade_required"
  | "rate_limited"
  | "spend_limit_reached"
  | "upstream_error"
  | "upstream_busy"
  | "upstream_timeout"
  | "service_unavailable"
  | "internal_error";

const ERROR_MESSAGES: Record<ErrorCode, string> = {
  unauthorized: "A valid device token is required.",
  not_found: "No such route.",
  method_not_allowed: "That method isn't allowed on this route.",
  invalid_request: "The request isn't valid.",
  unsupported_media_type: "The request must be JSON.",
  payload_too_large: "The request is too large.",
  upgrade_required: "This route needs a WebSocket connection.",
  rate_limited: "Too many requests. Try again shortly.",
  spend_limit_reached: "This device has reached its spending limit.",
  upstream_error: "The AI service returned an error.",
  upstream_busy: "The AI service is busy. Try again shortly.",
  upstream_timeout: "The AI service took too long to respond.",
  service_unavailable: "The service isn't available right now.",
  internal_error: "Something went wrong.",
};

const ERROR_STATUS: Record<ErrorCode, number> = {
  unauthorized: 401,
  not_found: 404,
  method_not_allowed: 405,
  invalid_request: 400,
  unsupported_media_type: 415,
  payload_too_large: 413,
  upgrade_required: 426,
  rate_limited: 429,
  spend_limit_reached: 429,
  upstream_error: 502,
  upstream_busy: 503,
  upstream_timeout: 504,
  service_unavailable: 503,
  internal_error: 500,
};

export function errorResponse(code: ErrorCode, extraHeaders: Record<string, string> = {}): Response {
  return Response.json(
    { error: { code, message: ERROR_MESSAGES[code] } },
    {
      status: ERROR_STATUS[code],
      headers: { "cache-control": "no-store", "x-content-type-options": "nosniff", ...extraHeaders },
    },
  );
}

/** Thrown anywhere in a handler to end the request with that error. */
export class RequestRejectedError extends Error {
  constructor(
    readonly code: ErrorCode,
    readonly extraHeaders: Record<string, string> = {},
  ) {
    super(code);
  }
}

/**
 * Reads a JSON body without trusting the declared length. A body can omit or lie
 * about its size, so the count that matters is taken while reading.
 */
export async function readBoundedJson(request: Request, maximumBytes: number): Promise<unknown> {
  const contentType = request.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().startsWith("application/json")) {
    throw new RequestRejectedError("unsupported_media_type");
  }

  const declaredLength = Number(request.headers.get("content-length") ?? 0);
  if (declaredLength > maximumBytes) {
    throw new RequestRejectedError("payload_too_large");
  }

  if (!request.body) {
    throw new RequestRejectedError("invalid_request");
  }

  const reader = request.body.getReader();
  const decoder = new TextDecoder();
  const textParts: string[] = [];
  let bytesRead = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    bytesRead += value.byteLength;
    if (bytesRead > maximumBytes) {
      await reader.cancel();
      throw new RequestRejectedError("payload_too_large");
    }
    textParts.push(decoder.decode(value, { stream: true }));
  }
  textParts.push(decoder.decode());

  try {
    return JSON.parse(textParts.join(""));
  } catch {
    throw new RequestRejectedError("invalid_request");
  }
}

export function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function hasOnlyKeys(value: Record<string, unknown>, allowedKeys: readonly string[]): boolean {
  return Object.keys(value).every((key) => allowedKeys.includes(key));
}

/** Maps a vendor's failure to ours. The vendor's body is never read, so it can't leak. */
export function rejectVendorFailure(route: string, vendorStatus: number): RequestRejectedError {
  console.log(JSON.stringify({ event: "vendor_error", route, vendorStatus }));
  const vendorIsBusy = vendorStatus === 429 || vendorStatus === 503 || vendorStatus === 529;
  return new RequestRejectedError(vendorIsBusy ? "upstream_busy" : "upstream_error");
}

export function isAbortError(error: unknown): boolean {
  return error instanceof Error && (error.name === "AbortError" || error.name === "TimeoutError");
}
