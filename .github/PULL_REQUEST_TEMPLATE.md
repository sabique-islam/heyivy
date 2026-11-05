<!-- Title format: [type] what changed and why. See .github/COMMIT_CONVENTION.md. -->

## Summary

<!-- What changed and why. A reviewer should get the point without reading the diff. -->

Closes #

## Type

- [ ] `feat`: new behavior
- [ ] `fix`: bug fix
- [ ] `docs`: documentation only
- [ ] `test`: tests only
- [ ] `chore`: dependencies, CI, skill updates, or upkeep

## How you tested it

<!-- What you ran and what you saw. For app changes, say what you tried in the running app. -->

## Checklist

- [ ] One logical change
- [ ] Docs updated if setup or behavior changed
- [ ] No secrets, `.env` files, or `.dev.vars`
- [ ] Screen, audio, and transcript data is not newly logged, stored, or sent anywhere
- [ ] If the Worker changed: endpoints still need auth, and limits are enforced on the server
- [ ] If skills changed: I read the upstream diff and ran `scripts/export-skills.sh`

## Screenshots

<!-- For overlay or UI changes. Don't show private screen content. -->
