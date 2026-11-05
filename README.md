# Ivy

Ivy is an AI tutor that sees your screen and explains things by talking and drawing over what you're looking at. It's built on [Clicky](https://github.com/farzaa/clicky) (from commit `e71105c`), and it hasn't launched.

## What's in this repo

| Path | What it is | How it's kept up to date |
|------|------------|--------------------------|
| `leanring-buddy/`, `worker/` | The macOS app and Cloudflare Worker, from Clicky | Part of this repo |
| `skills/jazz/` | [sabique-islam/jazz](https://github.com/sabique-islam/jazz): architecture, infrastructure, and cost | Git submodule |
| `skills/sui/` | [sabique-islam/sui](https://github.com/sabique-islam/sui): engineering, AI evals, testing, security, and review | Git submodule |
| `skills/shadowfax/` | [sabique-islam/shadowfax](https://github.com/sabique-islam/shadowfax): go-to-market | Git submodule |
| `.agents/skills/` | All the skills in one flat folder, built from `skills/` | Rebuilt by a script, not committed |

## Set up

The full guide, including the Worker and app, is in [SETUP.md](.github/SETUP.md). For just the skills, you need Git, Python 3.11 or later, and GitHub access to `sabique-islam/jazz`, which is private. If cloning Jazz fails, run `gh auth setup-git` and try again.

```bash
git clone --recurse-submodules git@github.com:sabique-islam/heyivy.git
cd heyivy
scripts/export-skills.sh
python3 -m venv .venv
.venv/bin/pip install -r skills/jazz/skills/jazz/scripts/requirements.txt
```

If you already cloned without submodules:

```bash
git submodule update --init
scripts/export-skills.sh
```

## Skills

Each pack is its own repo, and Ivy pins each one to an exact commit. Everyone gets the same skills until someone updates a pin on purpose.

### Use the skills with your agent

Tools that read `.agents/skills` can use the export as it is. According to the Jazz README, that includes Cursor and the `skills` CLI.

Claude Code doesn't read that folder. To load the skills as slash commands, export a local copy, which Git ignores:

```bash
scripts/export-skills.sh --dest .claude/skills
```

Otherwise, Claude can read a skill by path, as `CLAUDE.md` tells it to. Start a new session after exporting so the skills are picked up.

Run Jazz's scripts with `.venv/bin/python`, because they need the dependencies you installed during setup.

### Update the skills

To update every pack:

```bash
git submodule update --remote skills
```

To update one pack:

```bash
git submodule update --remote skills/jazz
```

Then review the changes before you accept them:

```bash
git diff --submodule=diff skills
```

Rebuild the export, and commit the new pins:

```bash
scripts/export-skills.sh
git add skills
git commit -m "Update skills"
```

After pulling someone else's update:

```bash
git submodule update --init
scripts/export-skills.sh
```

### Good habits

- **Read the changes before updating.** Skills are instructions your agent follows, so treat an update like a code change.
- **Update on purpose.** Update packs one at a time, and in their own commit, so a bad update is easy to find and undo.
- **Fix skills upstream.** Don't edit `skills/` or `.agents/`. Change the pack's own repo, then update the pin here. Edits to `.agents/` are lost on the next export.
- **Check before you rely on it.** `scripts/export-skills.sh --check` tells you if the export is out of date.
- **Keep secrets out.** Never commit `.env` files, `.dev.vars`, API keys, or `.jazz/`, which can hold approvals and reports.

### To undo an update

Check out the old commit in the pack, then rebuild:

```bash
git -C skills/jazz checkout <old-commit>
scripts/export-skills.sh
git add skills/jazz
git commit -m "Revert Jazz update"
```

### Add a pack

The repo needs a top-level `skills/` folder, with one folder per skill. Skill names must be unique across packs, and the export stops if two match.

```bash
git submodule add -b main https://github.com/<owner>/<repo>.git skills/<pack>
scripts/export-skills.sh
```

## The app

The app and Worker started as a copy of Clicky. Read `AGENTS.md`, and [Clicky's original README](docs/clicky-README.md) for setup, before working on them. To build it, you need:

- macOS 14.2 or later, and full Xcode 15 or later, not just the Command Line Tools
- Node.js 18 or later
- A Cloudflare account, and API keys for Anthropic, AssemblyAI, and ElevenLabs

Two of its rules are easy to break:

- Build from Xcode. Running `xcodebuild` in the terminal invalidates the app's macOS permissions.
- Don't rename the `leanring-buddy` folders. The typo is intentional.

### Don't ship it as it is

- The Worker has no authentication, so anyone with its URL can spend your API credits.
- `leanring-buddy/Info.plist` has an update feed and signing key that belong to another app.
- `leanring-buddy/ClickyAnalytics.swift` has a hardcoded PostHog key, and it sends full transcripts and AI responses.

## Licences

Clicky is MIT licensed, and its [licence notice](LICENSE) must stay with the code. Each pack has its own terms in its repo.

## Contributing

Read [CONTRIBUTING.md](.github/CONTRIBUTING.md) and the [commit convention](.github/COMMIT_CONVENTION.md). Report vulnerabilities using the [security policy](.github/SECURITY.md). Everyone here follows the [Code of Conduct](.github/CODE_OF_CONDUCT.md).
