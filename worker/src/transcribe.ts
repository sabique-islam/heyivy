import { errorResponse, isAbortError, isPlainObject, rejectVendorFailure } from "./http";
import {
  TRANSCRIBE_MAX_SESSION_SECONDS,
  TRANSCRIBE_MICRO_DOLLARS_PER_TOKEN,
  TRANSCRIBE_TIMEOUT_MS,
  TRANSCRIBE_TOKEN_EXPIRES_IN_SECONDS,
} from "./policy";
import { DeviceSpend } from "./spend";

/** Hands the app a short-lived token, so the AssemblyAI key itself never leaves the Worker. */
export async function handleTranscribeToken(request: Request, env: Env, spend: DeviceSpend): Promise<Response> {
  await spend.reserveOrReject("transcribe", TRANSCRIBE_MICRO_DOLLARS_PER_TOKEN);

  const tokenUrl = new URL("https://streaming.assemblyai.com/v3/token");
  tokenUrl.searchParams.set("expires_in_seconds", String(TRANSCRIBE_TOKEN_EXPIRES_IN_SECONDS));
  tokenUrl.searchParams.set("max_session_duration_seconds", String(TRANSCRIBE_MAX_SESSION_SECONDS));

  let upstreamResponse: Response;
  try {
    upstreamResponse = await fetch(tokenUrl.toString(), {
      headers: { authorization: env.ASSEMBLYAI_API_KEY },
      signal: AbortSignal.any([request.signal, AbortSignal.timeout(TRANSCRIBE_TIMEOUT_MS)]),
    });
  } catch (error) {
    spend.refund();
    return errorResponse(isAbortError(error) ? "upstream_timeout" : "upstream_error");
  }

  if (!upstreamResponse.ok) {
    spend.refund();
    throw rejectVendorFailure("transcribe", upstreamResponse.status);
  }

  const upstreamBody: unknown = await upstreamResponse.json().catch(() => null);
  if (!isPlainObject(upstreamBody) || typeof upstreamBody.token !== "string") {
    spend.refund();
    return errorResponse("upstream_error");
  }

  return Response.json(
    { token: upstreamBody.token },
    { headers: { "cache-control": "no-store", "x-content-type-options": "nosniff" } },
  );
}
