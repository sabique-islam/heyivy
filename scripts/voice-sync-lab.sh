#!/usr/bin/env bash
# Builds VoiceSyncLab, wraps it in a small app so macOS asks for the microphone in its
# own name, runs it, and prints the result. Arguments go to the lab, for example:
#
#   scripts/voice-sync-lab.sh --mode clicks --output speakers
#   scripts/voice-sync-lab.sh --mode clicks --output bluetooth
#   scripts/voice-sync-lab.sh --mode speech --stall
#
# Speech mode calls the Worker, so it needs a device token and costs about a cent.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_dir="$root/IvyCore"
app="$package_dir/.build/VoiceSyncLab.app"
result_file="$package_dir/.build/voice-sync-lab-result.json"

# Swift Testing and the macOS SDK come with Xcode. This only affects these commands.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

cd "$package_dir"
swift build -c release --product voice-sync-lab
binary="$(swift build -c release --show-bin-path)/voice-sync-lab"

mkdir -p "$app/Contents/MacOS"
cp "$binary" "$app/Contents/MacOS/voice-sync-lab"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>me.ivyx.ivy.voice-sync-lab</string>
  <key>CFBundleName</key><string>VoiceSyncLab</string>
  <key>CFBundleExecutable</key><string>voice-sync-lab</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.2</string>
  <key>NSMicrophoneUsageDescription</key><string>Records the test clicks to measure how well marks line up with the voice.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app" >/dev/null 2>&1

rm -f "$result_file"
# open gives the lab its own identity for permissions, and -W waits for it to quit.
open -W -n "$app" --args "$@" --result "$result_file"
cat "$result_file"
