#!/bin/bash
# Collects the information needed to diagnose a ScreenForge problem.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/ScreenForge.app"

echo "== System"
sw_vers
uname -m

echo
echo "== Xcode"
xcode-select -p 2>&1 || true
xcodebuild -version 2>&1 | head -2 || true

echo
echo "== Build"
if [ -d "$APP" ]; then
  echo "app: $APP"
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || true
  codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|Format" || true
  echo "-- entitlements"
  codesign -d --entitlements :- "$APP" 2>/dev/null | tr '<' '\n' | grep -E "com.apple.security" || true
else
  echo "not built (run ./scripts/build-app.sh)"
fi

echo
echo "== Process"
pgrep -fl "ScreenForge.app/Contents/MacOS/ScreenForge" || echo "not running"

echo
echo "== Projects folder"
CONTAINER="$HOME/Library/Containers/studio.screenforge.app/Data/Library/Application Support/ScreenForge/Recordings"
echo "$CONTAINER"
ls -la "$CONTAINER" 2>/dev/null | head -15 || echo "(empty or not created yet)"

echo
echo "== Recent errors (last 5 minutes)"
log show --last 5m --predicate 'process == "ScreenForge"' 2>/dev/null \
  | grep -iE "error|fault|crash|denied" | tail -20 || true
