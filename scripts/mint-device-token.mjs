#!/usr/bin/env node
// Issues a device token and stores it in this Mac's Keychain, where the app reads it.
// The token is never printed. Only the device ID and expiry are, for revoking it later.
//
//   scripts/mint-device-token.mjs                      Store a token for this Mac's app
//   scripts/mint-device-token.mjs --days 30            Choose how long it lasts (default 180)
//   scripts/mint-device-token.mjs --output-file PATH   Write it to a new private file instead
import { spawnSync } from "node:child_process";
import { createHmac, randomBytes } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

const KEYCHAIN_SERVICE = "me.ivyx.ivy.worker-device-token";
const KEYCHAIN_ACCOUNT = "device";
const SECONDS_PER_DAY = 86_400;

const { values: options } = parseArgs({
  options: {
    days: { type: "string", default: "180" },
    "output-file": { type: "string" },
  },
});

const validDays = Number(options.days);
if (!Number.isInteger(validDays) || validDays < 1 || validDays > 365) {
  console.error("--days must be a whole number from 1 to 365.");
  process.exit(1);
}

const environmentFile = join(dirname(fileURLToPath(import.meta.url)), "..", ".env");
const signingKey = readFileSync(environmentFile, "utf8")
  .split("\n")
  .find((line) => line.startsWith("DEVICE_TOKEN_SIGNING_KEY="))
  ?.slice("DEVICE_TOKEN_SIGNING_KEY=".length)
  .trim();
if (!signingKey) {
  console.error("DEVICE_TOKEN_SIGNING_KEY is missing from .env.");
  process.exit(1);
}

const deviceId = randomBytes(16).toString("base64url");
const expiresAtSeconds = Math.floor(Date.now() / 1000) + validDays * SECONDS_PER_DAY;
const signedPart = `ivy1.${deviceId}.${expiresAtSeconds}`;
const signature = createHmac("sha256", signingKey).update(signedPart).digest("base64url");
const deviceToken = `${signedPart}.${signature}`;

if (options["output-file"]) {
  // flag "wx" refuses to overwrite, and mode 600 keeps the file private to this user.
  writeFileSync(options["output-file"], deviceToken, { mode: 0o600, flag: "wx" });
} else {
  // Sent over stdin, because command-line arguments are visible to other processes.
  const keychainCommand = `add-generic-password -U -s ${KEYCHAIN_SERVICE} -a ${KEYCHAIN_ACCOUNT} -w ${deviceToken}\n`;
  const keychainResult = spawnSync("security", ["-i"], { input: keychainCommand, stdio: ["pipe", "ignore", "pipe"] });
  if (keychainResult.status !== 0) {
    console.error("Couldn't save the token to the Keychain.");
    process.exit(1);
  }
}

console.log(`Device ID: ${deviceId}`);
console.log(`Expires:   ${new Date(expiresAtSeconds * 1000).toISOString().slice(0, 10)}`);
console.log("To revoke it, add the device ID to REVOKED_DEVICE_IDS in worker/wrangler.jsonc and deploy.");
