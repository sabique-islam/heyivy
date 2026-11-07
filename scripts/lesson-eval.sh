#!/usr/bin/env bash
# Grades Ivy's marks on the evaluation screens in eval/cases (drawing plan, D6). Arguments go
# to the eval tool, for example:
#
#   scripts/lesson-eval.sh --label baseline                  The development cases
#   scripts/lesson-eval.sh --only code-03,chart-02           Just these
#   scripts/lesson-eval.sh --split test --label prompt-v2     The held-back third, for a result
#                                                            to report, never for tuning
#
# It calls the live Worker, so it needs a device token, and each case costs under a cent.
# Results go to eval/results/, which isn't committed.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The macOS SDK comes with Xcode. This only affects these commands.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# The Worker picks the model, so its settings are read from its policy and kept with the results.
model="$(sed -n 's/^export const CHAT_MODEL = "\(.*\)";/\1/p' "$root/worker/src/policy.ts")"
effort="$(sed -n 's/^export const CHAT_EFFORT = "\(.*\)";/\1/p' "$root/worker/src/policy.ts")"

cd "$root/IvyCore"
swift build -c release --product lesson-eval
binary="$(swift build -c release --show-bin-path)/lesson-eval"

cd "$root"
"$binary" --model-note "$model, effort $effort" "$@"
