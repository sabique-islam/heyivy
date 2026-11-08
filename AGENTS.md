# Ivy - Agent Instructions

Ivy is an AI tutor that sees your screen and explains things by talking and drawing over what you're looking at. It's built on the open-source Clicky project (MIT). It hasn't launched.

## Which skills to use

- **Sui** (`sui`, `sui-*`): engineering work, including AI evals, testing, security, and code review.
- **Jazz** (`jazz`, `jazz-*`): architecture, infrastructure, and cost decisions. Only use it when asked by name, or for those decisions. It has no guidance on Swift or macOS.
- **Shadowfax** (`shadowfax` and its skills): go-to-market work only.
- **Ponytail** (`ponytail`, `ponytail-*`): use it to keep code changes small, when asked by name or when a change is growing. It doesn't override the clarity rules below, so never make code harder to read to make it shorter.

When these overlap, use Sui for code changes and reviews.

## Rules

- All keys live in the root `.env`, which is never committed. `scripts/dev-worker.sh` loads them, and `.env.example` lists the names. Never print or log their values.
- Ivy isn't live, so Jazz recommendations use `system_stage: pre_launch`.
- Run Jazz's scripts with `.venv/bin/python`.

## The app

The app and Worker are in this repo, based on `farzaa/clicky` at `e71105c`. The Clicky instructions below apply to them. It's a plain copy now, so upstream changes have to be brought in by hand.

## Where the skills live

`skills/jazz`, `skills/sui`, `skills/shadowfax` and `skills/ponytail` are git submodules of their GitHub repos, the first three under `sabique-islam` and Ponytail under `DietrichGebert`. Ivy pins each one to a commit. Don't edit them here, because fixes belong in their own repos.

Agents use `.agents/skills/<name>`, which is rebuilt and not committed. Read a skill's `SKILL.md` from there by path. Claude Code doesn't load this folder by itself.

After cloning:

```bash
git submodule update --init
scripts/export-skills.sh
```

To take upstream updates, review them first, as the README explains:

```bash
git submodule update --remote skills
git diff --submodule=diff skills
scripts/export-skills.sh
git add skills
git commit -m "Update skills"
```

---

# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it via AssemblyAI streaming, and sends the transcript + a screenshot of the user's screen to Claude. Claude responds with text (streamed via SSE) and voice (ElevenLabs TTS). A blue cursor overlay can fly to and point at UI elements Claude references on any connected monitor.

All API keys live on a Cloudflare Worker proxy — nothing sensitive ships in the app.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Claude (Sonnet 4.6 default, Opus 4.6 optional) via Cloudflare Worker proxy with SSE streaming
- **Speech-to-Text**: AssemblyAI real-time streaming (`u3-rt-pro` model) via websocket, with OpenAI and Apple Speech as fallbacks
- **Text-to-Speech**: ElevenLabs (`eleven_flash_v2_5` model) via Cloudflare Worker proxy
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap. It starts when ctrl and option are both down and ends only when both are up, because a finger slipping off one key mid-sentence registers as a key-up. The mic starts on key press, before transcription has connected, and `EarlyAudioRelay` in `BuddyDictationManager.swift` holds that audio and hands it over once connected, so first words aren't lost. Mic capture is `MicrophoneCapture` in `IvyLesson`, shared with the voice lab, which tests it with `scripts/voice-sync-lab.sh --mode mic-check`.
- **Audio devices**: when the default mic is a Bluetooth headset and the Mac has its own mic, recording uses the Mac's mic. Opening a headset's mic switches it from music mode into call mode, which lowers its quality and rebuilds audio devices under every app. Recording and Ivy's voice both carry on when the device changes mid-use: the voice resumes from what had been heard.
- **Lessons and marks**: a lesson runs through `LessonEngine` in the `IvyCore` package, which Xcode uses as a local package. Claude writes one script where marks wrap the words they belong to (`{{spoken words|kind|visible text|x,y}}`). The speech streams to ElevenLabs over the Worker's `/voice` socket, marks snap to text found by on-device recognition, and each mark draws as its words are heard. Clicky's `[POINT:...]` tags and blue-cursor pointing are no longer used for answers, and the model picker has no effect, since the Worker chooses the model.
- **Failures and interrupts**: `LessonStateMachine` in `LessonFlow.swift` owns each lesson's phase. `CompanionManager` sends it every press, release, failure, and lock, sleep or display change, and carries out the effects it returns. No failure is silent: each shows a message in a bubble beside the cursor (`UserMessage.text`), and nothing retries. If the voice fails, the answer carries on as text in the bubble. Recording and transcription failures reach it through `BuddyDictationManager.failurePublisher`. While marks show, `MarkStalenessWatcher` samples the screen and fades any mark whose content changed, as after a scroll, and fades them all when another app comes forward. The voice has a deadline: once asked to speak, it must reply within 8 seconds, so a connection that goes quiet becomes a voice failure rather than silence. An answer counts as complete only once Claude's `message_stop` arrives, because the Worker reports a broken stream by ending it early.
- **Evaluation**: `scripts/lesson-eval.sh` grades Ivy's marks on the 145 screens in `eval/cases`. Rerun it on the development split after any change to the prompt, the model or effort in `worker/src/policy.ts`, the resolver, or text recognition, and compare runs with `eval/compare.py`. The held-back split (`--split test`) is only for reporting a result, never for tuning. Look at the review images before trusting a failure, since some come from the labels.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: Nothing is sent. `ClickyAnalytics.swift` is a stub until Ivy has its own key, and events must never contain transcripts, AI responses, emails, or screen content.

### API Proxy (Cloudflare Worker)

The app never calls external APIs directly. All requests go through a Cloudflare Worker (`worker/src/index.ts`) that holds the real API keys as secrets.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `api.anthropic.com/v1/messages` | Claude vision + streaming chat |
| `POST /tts` | `api.elevenlabs.io/v1/text-to-speech/{voiceId}` | ElevenLabs TTS audio |
| `GET /voice` (WebSocket) | `api.elevenlabs.io/v1/text-to-speech/{voiceId}/stream-input` | Streams text in, and audio with character timings out. Not used by the app yet |
| `POST /transcribe-token` | `streaming.assemblyai.com/v3/token` | Fetches an AssemblyAI token that expires in 60s and limits its session to 300s |

The Worker runs at `https://secrets.worker.ivy.ivyx.me`. Every route needs `Authorization: Bearer <device token>`, read from the Keychain by `WorkerDeviceToken.swift`. The server sets the model and output limits, and ignores any the app sends, so the app's model picker has no effect. Each device has its own rate and spend limits, in `worker/src/policy.ts`, enforced by the `DeviceLimiter` Durable Object.

The Worker is pinned to Mumbai (`aws:ap-south-1`) in `wrangler.jsonc`. Unpinned, requests from India sometimes ran in Hong Kong, where Anthropic answers 403. Mumbai gave first audio in about 0.87 s, against 1.47 s from the US. Revisit this when users are elsewhere.

The older Worker `ivy-proxy` at `api.ivy.ivyx.me` is separate. Leave it alone: this repo's config and deploys don't touch it.

Worker secrets: `ANTHROPIC_API_KEY`, `ASSEMBLYAI_API_KEY`, `ELEVENLABS_API_KEY`, `ELEVENLABS_VOICE_ID`, `DEVICE_TOKEN_SIGNING_KEY`
Worker vars: `REVOKED_DEVICE_IDS`

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**WebSockets on Network framework**: Transcription and the voice both use `NWConnection` with `NWProtocolWebSocket`, one connection per session, cancelled when it ends. `URLSessionWebSocketTask` is not used, because URLSession never frees a finished WebSocket task, so every question left its connection, request and certificates behind. Clicky shared one URLSession across AssemblyAI sessions because creating one per session broke reconnections. That doesn't apply now.

**Transient Cursor Mode**: When "Show Clicky" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1090 | Central state machine. Owns dictation, shortcut monitoring, screen capture, Claude API, ElevenLabs TTS, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, and cursor visibility. Coordinates the full push-to-talk → screenshot → Claude → TTS → pointing pipeline. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~761 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, model picker (Sonnet/Opus), permissions UI, DM feedback button, and quit button. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~945 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `BuddyDictationManager.swift` | ~1000 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~100 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — AssemblyAI, OpenAI, or Apple Speech. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~520 | Streaming transcription provider. Fetches temp tokens from the Cloudflare Worker, opens an AssemblyAI v3 WebSocket on Network framework, streams PCM16 audio, tracks turn-based transcripts, and delivers finalized text on key-up. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `ClaudeAPI.swift` | ~291 | Claude vision API client with streaming (SSE) and non-streaming modes. TLS warmup optimization, image MIME detection, conversation history support. |
| `OpenAIAPI.swift` | ~142 | OpenAI GPT vision API client. |
| `ElevenLabsTTSClient.swift` | ~81 | ElevenLabs TTS client. Sends text to the Worker proxy, plays back audio via `AVAudioPlayer`. Exposes `isPlaying` for transient cursor scheduling. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `ClickyAnalytics.swift` | ~100 | Analytics event stub. Sends nothing yet. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `WorkerDeviceToken.swift` | ~46 | Reads the Worker device token from the Keychain and adds it to requests. |
| `worker/src/index.ts` | ~70 | Worker entry point. Authenticates, routes, and logs each request. |
| `worker/src/auth.ts` | ~60 | Verifies device tokens. Fails closed if the signing key is missing or weak. |
| `worker/src/policy.ts` | ~75 | Every limit, price, and model choice the Worker enforces. |
| `worker/src/device-limiter.ts` | ~125 | Durable Object holding one device's rate and spend counters. |
| `worker/src/spend.ts` | ~55 | Reserves spend for a request and corrects it once the true cost is known. |
| `worker/src/chat.ts` | ~265 | `/chat`: validates against an allow-list, streams Claude's reply, reads token usage, and handles timeouts and cancellation. |
| `worker/src/speech.ts` | ~245 | `/tts` and the `/voice` WebSocket relay to ElevenLabs. |
| `worker/src/transcribe.ts` | ~45 | `/transcribe-token`: short-lived AssemblyAI tokens. |
| `worker/src/http.ts` | ~135 | The one error shape and bounded JSON reading. |
| `worker/test/worker.test.ts` | ~560 | Security and behavior tests. Vendors are faked, so they cost nothing. |
| `IvyCore/Sources/IvyCore/SpeechTimeline.swift` | ~150 | Turns ElevenLabs character timings into word times, checking whether each chunk counts from the stream start or its own start. |
| `IvyCore/Sources/IvyCore/PlaybackClock.swift` | ~185 | The clock of what's actually been heard, the stall guard that pauses playback when audio runs low, and the scheduler that hands out due words. |
| `IvyCore/Sources/IvyCore/LessonScriptParser.swift` | ~440 | Splits Claude's streamed script into speech and marks (`{{spoken words|kind|visible text|x,y}}`), however the stream is chunked. Strips Markdown from speech and enforces the mark limits. |
| `IvyCore/Sources/IvyCore/TargetResolver.swift` | ~275 | Finds each mark's target among on-device text recognition results. Text that matches exactly and appears once on screen is trusted wherever it is, even over a nearer partial match. Otherwise a mark is dropped when text and position disagree. It tolerates text recognized without its spaces and misread punctuation in long code tokens, but not a short word standing in for a long one. Also converts screenshot pixels to screen points. |
| `IvyCore/Sources/IvyCore/MarkGrading.swift` | ~160 | How the D6 eval grades a mark: on the target, on what it names, unverified, or wrong. A wrong mark fails a case even beside a right one. |
| `IvyCore/Sources/IvyCore/LessonFlow.swift` | ~320 | Times marks to their words, with a limit of 5 on screen, and the lesson state machine with IDs, interrupts, the failure rules, and the message for each failure. |
| `IvyCore/Sources/IvyCore/ScreenChangeDetection.swift` | ~120 | Decides whether the screen under a mark still shows what it was drawn on. It compares structure rather than pixels, so a hover highlight doesn't count but a scroll does. |
| `IvyCore/Tests/IvyCoreTests/` | ~1290 | 135 tests, including every split point, random splits, and fuzzed input for the parser. |
| `IvyCore/Sources/IvyOverlay/MarkGeometry.swift` | ~150 | Where each mark kind goes around its target so it never covers it, and the mark style, which is a bright stroke with a dark outline so marks are readable on any background. |
| `IvyCore/Sources/IvyOverlay/MarkOverlay.swift` | ~270 | Mark layers, the click-through overlay window for each screen, and `MarkOverlayController`, which shows, fades, and clears marks. Its windows exist only while they hold marks. |
| `IvyCore/Sources/MarkOverlayLab/` | ~410 | Developer tool for drawing plan D3. Draws marks from `IvyCore/Examples/overlay-demo.json` over a full-screen test card, and checks screen capture and idle CPU. `--check-staleness` scrolls the card and times how fast marks fade. Run it with `scripts/mark-overlay-lab.sh`. |
| `IvyCore/Sources/IvyLesson/LessonEngine.swift` | ~435 | Runs one lesson: streams Claude's script, sends speech to the voice, resolves marks against text recognition, and shows each mark as its words are heard. Cancelling stops audio first. If the voice fails, the script keeps streaming so the answer can be shown as text. |
| `IvyCore/Sources/IvyLesson/MarkStalenessWatcher.swift` | ~215 | Samples the screen about 7 times a second while marks show, leaving out Ivy's windows and the pointer, and reports marks whose content changed. |
| `IvyCore/Sources/IvyLesson/LessonServices.swift` | ~370 | The `/chat` script stream, the `/voice` socket with its silence deadline (on Network framework, because URLSession never frees a finished WebSocket task), and the per-lesson timing log, which records stage times but never what was said or shown. |
| `IvyCore/Sources/IvyLesson/LessonPrompt.swift` | ~30 | The system prompt that teaches Claude the mark format, and to leave the screen alone when a question isn't about it. Rerun the eval after any change. |
| `IvyCore/Sources/IvyLesson/ScreenTextRecognizer.swift` | ~95 | On-device text recognition with Apple Vision, warmed up at launch because the first use in a new build is very slow. It detects the language, and can look again in a small area, which finds short text like chart values that it misses on the whole screen. |
| `IvyCore/Sources/IvyLesson/MicrophoneCapture.swift` | ~130 | Records from the mic that keeps Bluetooth headsets in music mode, and restarts if the device changes mid-recording. Used by push-to-talk. |
| `IvyCore/Sources/IvyLesson/StreamingSpeechPlayer.swift`, `AudioDevices.swift` | ~310 | Plays streamed speech and keeps the clock of what's been heard. Output delay comes from CoreAudio, because the engine's figure is wrong for devices that aren't the system default. |
| `IvyCore/Sources/LessonLab/` | ~460 | Developer tool for drawing plans D4, D5 and D7. Runs one real lesson about a code window, without needing Screen Recording, and reports timings and what each mark pointed at. `--force` makes one thing fail and reports what the user would be told, `--interrupts N` cancels N lessons at random moments and times how fast each goes quiet, and `--soak N` runs N lessons in a row, records memory, threads, open files and CPU after each, saves `heap` and `vmmap` at lesson 10 and the end for comparing, then runs `leaks`. `--worker URL` points it at another Worker. Run it with `scripts/lesson-lab.sh`. |
| `scripts/fake-worker.mjs` | ~165 | A local stand-in for the Worker whose `/chat` and `/voice` work, stall, drop, or refuse on purpose, for testing failures and free soaks with LessonLab's `--worker`. Calls nothing and costs nothing. |
| `IvyCore/Sources/VoiceSyncLab/` | ~900 | Developer tool for drawing plan D1. Plays real speech or test clicks, draws on each word, and measures sync with the mic. Run it with `scripts/voice-sync-lab.sh`. Not part of the app. |
| `IvyCore/Sources/LessonEval/` | ~590 | The D6 eval tool. Renders each screen in `eval/cases`, puts it through the app's prompt, Worker, text recognition and resolver, grades every mark, and writes a summary and a review image per case. Run it with `scripts/lesson-eval.sh`. Each case costs under a cent. |
| `eval/generate_cases.py` | ~595 | Writes the 145 evaluation screens and questions in `eval/cases`, across 13 screen types, with targets marked in the page. A third of each type is held back, and a case never changes split. |
| `eval/compare.py` | ~85 | Compares two eval runs case by case, for a prompt or model change. |
| `scripts/mint-device-token.mjs` | ~70 | Issues a device token and stores it in the Keychain, without printing it. |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

`IvyCore` is a Swift package for logic that needs no UI or permissions. Test it with `cd IvyCore && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. The variable is needed because Swift Testing ships with Xcode, not the Command Line Tools, and it changes nothing system-wide. This is not `xcodebuild`, and it doesn't affect the app's permissions.

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Cloudflare Worker

```bash
cd worker
npm install

# Test and type check. Run after any Worker change, and rerun `npm run types` if the config changes.
npm test
npm run typecheck

# Add secrets, one for each name listed under "API Proxy"
npx wrangler secret put ANTHROPIC_API_KEY

# Deploy
npx wrangler deploy

# Local dev, using the keys in the root .env
../scripts/dev-worker.sh
```

To issue a device token, run `scripts/mint-device-token.mjs`. To revoke one, add its device ID to `REVOKED_DEVICE_IDS` in `worker/wrangler.jsonc` and deploy.

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
