# Commit convention

```text
[type] what changed and why
```

For example:

```text
[fix] stop retrying TTS after a 4xx so a bad key doesn't burn credits
[feat] add device auth to the Worker so a leaked URL can't spend credits
[docs] explain how to review skill updates before accepting them
```

## Types

| Type | Use it for |
|------|------------|
| `feat` | New behavior |
| `fix` | A bug fix |
| `docs` | Documentation only |
| `test` | Tests only |
| `chore` | Dependencies, CI, skill updates, and upkeep |

## Rules

- Use a lowercase type in square brackets, then one space.
- Start the summary with a lowercase verb, such as `add`, `fix`, or `stop`.
- Say why when it isn't obvious. "update code" tells a reader nothing.
- Keep the first line to about 72 characters. Put longer explanations in the body, after a blank line.
- Make one logical change per commit.
- Never commit secrets, `.env` files, or `.dev.vars`.

## Pull request titles

Pull request titles follow the same format, and CI checks them. Use the title as the commit message when you squash and merge.

## Skill updates

Update packs in their own commit, and name the pack:

```text
[chore] update jazz skills to 498e4df for the pre-launch checks
```
