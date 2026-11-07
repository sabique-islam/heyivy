#!/usr/bin/env bash
# Builds LessonLab and wraps it in a small app,
# runs one real lesson, and prints the result. It calls the Worker, so it needs a device
# token and costs a few cents. Arguments go to the lab, for example:
#
#   scripts/lesson-lab.sh
#   scripts/lesson-lab.sh --question "What does line 3 do?"
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_dir="$root/IvyCore"
app="$package_dir/.build/LessonLab.app"
result_file="$package_dir/.build/lesson-lab-result.json"

# The macOS SDK and Swift Testing come with Xcode. This only affects these commands.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

cd "$package_dir"
swift build -c release --product lesson-lab
binary="$(swift build -c release --show-bin-path)/lesson-lab"

mkdir -p "$app/Contents/MacOS"
cp "$binary" "$app/Contents/MacOS/lesson-lab"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>me.ivyx.ivy.lesson-lab</string>
  <key>CFBundleName</key><string>LessonLab</string>
  <key>CFBundleExecutable</key><string>lesson-lab</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.2</string>
</dict>
</plist>
PLIST
# Signing with your Apple Development certificate, when you have one, keeps the lab's
# permissions across rebuilds. Ad hoc signing changes identity with every build.
if security find-identity -p codesigning -v 2>/dev/null | grep -q "Apple Development"; then
  codesign --force --sign "Apple Development" "$app" >/dev/null 2>&1
else
  codesign --force --sign - "$app" >/dev/null 2>&1
fi

rm -f "$result_file"
# open gives the lab its own identity for permissions, and -W waits for it to quit.
open -W -n "$app" --args "$@" --result "$result_file"
cat "$result_file"
