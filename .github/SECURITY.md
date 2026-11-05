# Security policy

Ivy sees people's screens and hears their voices, so we treat a privacy leak as seriously as a security bug.

## Report a vulnerability

Don't open an issue or pull request for a vulnerability, and don't paste exploit details into a shared channel.

Contact [@sabique-islam](https://github.com/sabique-islam) directly. Share only that you have a report, and agree on a private way to send the details.

Include:

- What's affected
- How to reproduce it
- What an attacker could do with it

Ivy is pre-launch, so we can't promise a response time yet. Please give us a reasonable chance to fix a problem before you share it.

## What's supported

Only the `main` branch. There are no releases yet.

## What we care about most

- Screen captures, audio, or transcripts reaching anyone they shouldn't
- API keys being exposed, or someone spending them through the Worker
- Text on a user's screen making Ivy do something harmful (prompt injection)
- Anything that lets an update or a skill run untrusted code

## Known risks

These come from the original Clicky code, and they need fixing before any public release. There's no need to report them.

- **Open Worker:** `worker/src/index.ts` has no authentication, and it forwards any request body. Anyone with the URL can spend the API credits.
- **Another app's update feed:** `SUFeedURL` and `SUPublicEDKey` in `leanring-buddy/Info.plist` belong to another app. Replace both before shipping a build.
- **Analytics:** `leanring-buddy/ClickyAnalytics.swift` has a hardcoded PostHog key from the original project, and it sends full transcripts and AI responses.
- **Permissions:** the entitlements include camera access, which Ivy doesn't need.

## Handling secrets and private data

- Never commit `.env` files, `worker/.dev.vars`, API keys, or `.jazz/`.
- Don't put real keys, private screenshots, or transcripts in issues, pull requests, or logs.
- If a key leaks, revoke it first. Removing it from the code doesn't make it safe again.
