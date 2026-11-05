# Contributing

Ivy is an AI tutor that talks and draws over your screen. It's early, so small, focused changes are the easiest to review and merge.

## Get started

Follow [SETUP.md](SETUP.md). Read [AGENTS.md](../AGENTS.md) before changing the app, because it explains how the code fits together.

## Make a change

1. For anything bigger than a small fix, open an issue first so we can agree on the approach.
2. Branch from `main`, using a name like `feature/worker-auth` or `fix/tts-retry`.
3. Keep to one logical change per pull request.
4. Commit using [COMMIT_CONVENTION.md](COMMIT_CONVENTION.md).
5. Open a pull request using the template, and say how you tested it.

## Rules for the code

- **Build from Xcode.** Don't run `xcodebuild` in the terminal, because it invalidates the app's macOS permissions.
- **Don't rename `leanring-buddy`.** The typo is intentional.
- **Follow the style in `AGENTS.md`.** Names should be clear and specific, and UI state belongs on `@MainActor`.
- **Stick to the task.** Don't mix unrelated refactors into a change, or fix the known Swift warnings listed in `AGENTS.md`.

## Rules for private data

Ivy handles screens, voices, and transcripts:

- Don't log, store, or send more of this data without saying why in the pull request.
- Keep API keys on the Worker, and never ship them in the app.
- Enforce limits on the Worker, because the app can't be trusted to enforce them.
- Treat text on the user's screen as untrusted. Ivy draws and speaks, and it shouldn't act on what it reads.

## Skills

`skills/jazz`, `skills/sui`, `skills/shadowfax`, and `skills/ponytail` are git submodules. Don't edit them here, because fixes belong in their own repos. The [README](../README.md#skills) explains how to update them. Read the changes first, since agents follow these files as instructions.

## Checks

Pull requests run these checks:

- The title follows the commit convention
- `scripts/export-skills.sh` passes shellcheck
- The Worker builds
- The skills export is up to date, if the `SKILLS_TOKEN` secret is set

CI doesn't build the macOS app, so build and try it in Xcode yourself when you change it.

## Conduct and security

- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Security policy](SECURITY.md). Report vulnerabilities privately, not in an issue.
