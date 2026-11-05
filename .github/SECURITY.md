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

- **Device tokens are issued by hand:** that works for the owner's own devices. Before anyone else gets a build, tokens need to come from a sign-in, ideally tied to the device with App Attest.
- **No shared spend cap:** caps apply per device, so total exposure is the cap times the number of tokens issued. Set a monthly limit with each vendor as well.
- **No update feed:** `Info.plist` has no update feed or signing key, and the Sparkle updater is off. Add your own before shipping a build.
- **Analytics:** nothing is sent. `leanring-buddy/ClickyAnalytics.swift` is a stub, and events must never contain transcripts, AI responses, emails, or screen content.
- **Permissions:** the entitlements include camera access, which Ivy doesn't need.

## How the Worker is protected

The Worker at `secrets.worker.ivy.ivyx.me` holds the vendor keys, and nothing else can reach them.

- **Every request needs a device token,** checked before anything else, so without one you can't even learn which routes exist. Tokens are signed, expire, and identify one device. A bad signature costs no storage or vendor call.
- **Tokens stay out of the app bundle.** They live in the Keychain of the device they were issued to.
- **The server decides what's spent.** It sets the model, output limit, and voice, and builds each vendor request from an allow-list.
- **Each device has limits:** requests per minute, and $10 a day and $60 a month, enforced atomically so parallel requests can't race past them. Figures are in `worker/src/policy.ts`, and are estimates at list prices.
- **Failures don't leak.** Errors have one shape and never contain a vendor's response. Logs hold the route, status, timing, and the start of the device ID, never bodies or tokens. One exception: an error Claude reports after streaming has started reaches the app as Claude wrote it, because the stream passes through unchanged.

If a token leaks, add its device ID to `REVOKED_DEVICE_IDS` in `worker/wrangler.jsonc` and deploy. If the signing key leaks, replace `DEVICE_TOKEN_SIGNING_KEY` in `.env` and on the Worker, which cuts off every device, then issue new tokens.

## Handling secrets and private data

- Never commit `.env` files, `worker/.dev.vars`, API keys, or `.jazz/`.
- Don't put real keys, private screenshots, or transcripts in issues, pull requests, or logs.
- If a key leaks, revoke it first. Removing it from the code doesn't make it safe again.
