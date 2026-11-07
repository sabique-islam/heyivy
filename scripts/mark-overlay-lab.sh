#!/usr/bin/env bash
# Builds MarkOverlayLab, wraps it in a small app so macOS asks for Screen Recording in its
# own name, runs it, and prints the result. It covers every screen with a test card for
# about 15 seconds. Arguments go to the lab, for example:
#
#   scripts/mark-overlay-lab.sh
#   scripts/mark-overlay-lab.sh --check-capture
#   scripts/mark-overlay-lab.sh --reduce-motion --no-full-screen
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_dir="$root/IvyCore"
app="$package_dir/.build/MarkOverlayLab.app"
result_file="$package_dir/.build/mark-overlay-lab-result.json"

# The macOS SDK and Swift Testing come with Xcode. This only affects these commands.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

cd "$package_dir"
swift build -c release --product mark-overlay-lab
binary="$(swift build -c release --show-bin-path)/mark-overlay-lab"

mkdir -p "$app/Contents/MacOS"
cp "$binary" "$app/Contents/MacOS/mark-overlay-lab"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>me.ivyx.ivy.mark-overlay-lab</string>
  <key>CFBundleName</key><string>MarkOverlayLab</string>
  <key>CFBundleExecutable</key><string>mark-overlay-lab</string>
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
open -W -n "$app" --args --script "$package_dir/Examples/overlay-demo.json" "$@" --result "$result_file"
cat "$result_file"
