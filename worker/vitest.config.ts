import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        // These override worker/.dev.vars, so tests can never reach a real key.
        bindings: {
          ANTHROPIC_API_KEY: "test-anthropic-key",
          ASSEMBLYAI_API_KEY: "test-assemblyai-key",
          ELEVENLABS_API_KEY: "test-elevenlabs-key",
          ELEVENLABS_VOICE_ID: "test-voice-id",
          DEVICE_TOKEN_SIGNING_KEY: "test-signing-key-that-is-long-enough-to-use",
          REVOKED_DEVICE_IDS: "revokedDeviceId0000000",
        },
      },
    }),
  ],
});
