// Every limit the Worker enforces lives here, so they can be read and changed in one place.

export type RateLimitedRoute = "chat" | "tts" | "transcribe" | "voice";

// A person talking to a tutor can't reach these. A stolen token running a script can.
export const REQUESTS_PER_MINUTE: Record<RateLimitedRoute, number> = {
  chat: 20,
  tts: 60,
  transcribe: 20,
  voice: 20,
};

// The most one device can spend. A lesson costs about 5 cents, so a day allows about 200.
export const DAILY_SPEND_CAP_MICRO_DOLLARS = 10_000_000;
export const MONTHLY_SPEND_CAP_MICRO_DOLLARS = 60_000_000;

// Claude. The app can't change any of these.
export const CHAT_MODEL = "claude-sonnet-5-5";
export const ANTHROPIC_API_VERSION = "2026-10-21";
export const CHAT_MAX_OUTPUT_TOKENS = 2048;
export const CHAT_EFFORT = "low";

// Sonnet 5.5 list prices, as whole micro-dollars per token ($2 and $10 per million).
// Cache writes cost 1.25x input and cache reads 0.1x, so those are computed where they're used.
export const CHAT_INPUT_MICRO_DOLLARS_PER_TOKEN = 2;
export const CHAT_OUTPUT_MICRO_DOLLARS_PER_TOKEN = 10;

// The spend check needs a figure before Claude reports its usage, so this overestimates.
// The reservation is corrected once the stream reports what it really used.
export const CHAT_RESERVED_TOKENS_PER_IMAGE = 8_000;
export const CHAT_RESERVED_TOKENS_PER_TEXT_CHARACTER = 0.5;

export const CHAT_MAX_BODY_BYTES = 16 * 1024 * 1024;
export const CHAT_MAX_SYSTEM_CHARACTERS = 32_000;
export const CHAT_MAX_MESSAGES = 41;
export const CHAT_MAX_TEXT_CHARACTERS_PER_BLOCK = 16_000;
export const CHAT_MAX_IMAGES = 6;
// Claude accepts images up to 5 MB, which is about this much once base64 encoded.
export const CHAT_MAX_IMAGE_BASE64_CHARACTERS = 7_000_000;
export const CHAT_ALLOWED_IMAGE_TYPES = ["image/jpeg", "image/png"];

export const CHAT_FIRST_RESPONSE_TIMEOUT_MS = 30_000;
// Claude sends ping events during long pauses, so this much silence means it's stuck.
export const CHAT_STREAM_IDLE_TIMEOUT_MS = 30_000;
export const CHAT_STREAM_TOTAL_TIMEOUT_MS = 180_000;

// ElevenLabs. Flash v2.5 costs $0.05 per 1,000 characters at API list price.
export const SPEECH_MODEL = "eleven_flash_v2_5";
export const SPEECH_MICRO_DOLLARS_PER_CHARACTER = 50;

export const TTS_MAX_BODY_BYTES = 64 * 1024;
export const TTS_MAX_CHARACTERS = 5_000;
export const TTS_TIMEOUT_MS = 30_000;

// Voice connections carry a whole lesson, so spend is reserved a block at a time.
export const VOICE_RESERVED_CHARACTERS_PER_BLOCK = 500;
export const VOICE_MAX_CHARACTERS_PER_CONNECTION = 20_000;
export const VOICE_MAX_FRAME_BYTES = 64 * 1024;
export const VOICE_CONNECT_TIMEOUT_MS = 10_000;
export const VOICE_MAX_CONNECTION_MS = 15 * 60 * 1000;
// The socket opens when the key goes down, so it has to survive a long question.
export const VOICE_VENDOR_INACTIVITY_TIMEOUT_SECONDS = 120;

// AssemblyAI. The token is used at once, and it limits how long its session can run.
export const TRANSCRIBE_TOKEN_EXPIRES_IN_SECONDS = 60;
export const TRANSCRIBE_MAX_SESSION_SECONDS = 300;
export const TRANSCRIBE_TIMEOUT_MS = 10_000;
// $0.45 an hour. A token could be used for its full session, and the Worker can't see
// how long it actually was, so every token is charged as a full session.
export const TRANSCRIBE_MICRO_DOLLARS_PER_TOKEN = Math.ceil((450_000 * TRANSCRIBE_MAX_SESSION_SECONDS) / 3600);

export const SIGNING_KEY_MINIMUM_LENGTH = 32;
