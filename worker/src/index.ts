/**
 * The Ivy API proxy. It holds the vendor keys, so the app never has to.
 *
 * Every request must carry a device token before anything else happens, including
 * learning which routes exist. See `.github/SECURITY.md` for the threat model and
 * `scripts/mint-device-token.mjs` for how tokens are issued.
 */
import { authenticateDevice } from "./auth";
import { handleChat } from "./chat";
import { errorResponse, RequestRejectedError } from "./http";
import { handleTextToSpeech, handleVoice } from "./speech";
import { DeviceSpend } from "./spend";
import { handleTranscribeToken } from "./transcribe";

export { DeviceLimiter } from "./device-limiter";

type RouteHandler = (request: Request, env: Env, spend: DeviceSpend) => Promise<Response>;

const ROUTES: Record<string, { method: string; logName: string; handle: RouteHandler }> = {
  "/chat": { method: "POST", logName: "chat", handle: handleChat },
  "/tts": { method: "POST", logName: "tts", handle: handleTextToSpeech },
  "/voice": { method: "GET", logName: "voice", handle: handleVoice },
  "/transcribe-token": { method: "POST", logName: "transcribe", handle: handleTranscribeToken },
};

async function routeRequest(
  request: Request,
  env: Env,
  executionContext: ExecutionContext,
  logFields: Record<string, unknown>,
): Promise<Response> {
  const deviceId = await authenticateDevice(request, env);
  if (!deviceId) {
    return errorResponse("unauthorized", { "www-authenticate": "Bearer" });
  }
  // Enough to tell devices apart in the logs, without logging a whole identifier.
  logFields.device = deviceId.slice(0, 6);

  const route = ROUTES[new URL(request.url).pathname];
  if (!route) return errorResponse("not_found");
  logFields.route = route.logName;
  if (request.method !== route.method) {
    return errorResponse("method_not_allowed", { allow: route.method });
  }

  return route.handle(request, env, new DeviceSpend(deviceId, env, executionContext));
}

export default {
  async fetch(request, env, executionContext): Promise<Response> {
    const startedAtMs = Date.now();
    const logFields: Record<string, unknown> = { event: "request" };
    let response: Response;
    try {
      response = await routeRequest(request, env, executionContext, logFields);
    } catch (error) {
      if (error instanceof RequestRejectedError) {
        response = errorResponse(error.code, error.extraHeaders);
      } else {
        // The error's name only. A message could contain request or vendor data.
        logFields.failure = error instanceof Error ? error.name : "unknown";
        response = errorResponse("internal_error");
      }
    }
    // Never the URL's query, headers, or body: those can carry tokens and what people say.
    console.log(JSON.stringify({ ...logFields, status: response.status, durationMs: Date.now() - startedAtMs }));
    return response;
  },
} satisfies ExportedHandler<Env>;
