#!/usr/bin/env bash
# Runs the Worker locally with the keys from the root .env file.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="$root/.env"
required_keys="ANTHROPIC_API_KEY ASSEMBLYAI_API_KEY ELEVENLABS_API_KEY ELEVENLABS_VOICE_ID DEVICE_TOKEN_SIGNING_KEY"

if [ ! -f "$env_file" ]; then
  echo "No .env found. Copy .env.example to .env and fill it in." >&2
  exit 1
fi

for key in $required_keys; do
  if ! grep -Eq "^(export )?$key=.+" "$env_file"; then
    echo "$key is missing or empty in .env." >&2
    exit 1
  fi
done

# Wrangler reads worker/.dev.vars, so link it to .env to keep one copy of the keys.
ln -sfn ../.env "$root/worker/.dev.vars"

# Wrangler sends usage data to Cloudflare by default.
export WRANGLER_SEND_METRICS=false

cd "$root/worker"
[ -d node_modules ] || npm ci
exec npx wrangler dev "$@"
