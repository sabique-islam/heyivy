# Setup

This gets the skills, Worker, and macOS app running on your machine.

## What you need

- macOS 14.2 or later
- Full Xcode 15 or later, not just the Command Line Tools
- Node.js 18 or later
- Python 3.11 or later
- A Cloudflare account, and API keys for Anthropic, AssemblyAI, and ElevenLabs

## 1. Get the code

```bash
git clone --recurse-submodules git@github.com:sabique-islam/heyivy.git
cd heyivy
```

If you cloned without submodules, run `git submodule update --init`. If Jazz fails to clone, run `gh auth setup-git` and try again.

## 2. Set up the skills

```bash
scripts/export-skills.sh
python3 -m venv .venv
.venv/bin/pip install -r skills/jazz/skills/jazz/scripts/requirements.txt
```

The [README](../README.md#skills) explains how to use and update them.

## 3. Run the Worker locally

The Worker holds the API keys, so they never ship in the app.

```bash
cd worker
npm ci
```

Create `worker/.dev.vars` with your keys. Git ignores this file, so never copy it anywhere that's tracked.

```text
ANTHROPIC_API_KEY=your-key
ASSEMBLYAI_API_KEY=your-key
ELEVENLABS_API_KEY=your-key
ELEVENLABS_VOICE_ID=your-voice-id
```

Then start it. It usually runs at `http://localhost:8787`.

```bash
npx wrangler dev
```

## 4. Point the app at your Worker

Find the Worker URLs in the Swift code, and replace them with your local URL:

```bash
grep -rnE "clicky-proxy|your-worker-name" leanring-buddy/
```

## 5. Build the app

```bash
open leanring-buddy.xcodeproj
```

In Xcode:

1. Select the `leanring-buddy` scheme. The typo is intentional.
2. Set your signing team under Signing & Capabilities.
3. Press Cmd + R.

The app appears in your menu bar, not the Dock. Click its icon and grant the permissions it asks for: Microphone, Accessibility, Screen Recording, and Screen Content.

Build from Xcode. Running `xcodebuild` in the terminal invalidates these macOS permissions, and you'd have to grant them again.

## Before you deploy or share a build

Read [Known risks](SECURITY.md#known-risks) first. Don't run `npx wrangler deploy` or use `scripts/release.sh` until those are fixed.

## If something goes wrong

- **No skills found:** run `git submodule update --init`, then export again.
- **The hotkey or screen capture stops working:** you probably ran `xcodebuild` from the terminal. Grant the permissions again in System Settings, under Privacy & Security.
- **Xcode isn't found from the terminal:** run `xcode-select -p` to see which tools are active. Building from the Xcode app still works.
