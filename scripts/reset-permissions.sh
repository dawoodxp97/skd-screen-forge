#!/bin/bash
# Clears this app's privacy grants so the first-run permission flow can be tested again.
#
# macOS caches screen-recording approval per bundle ID; after resetting, quit and
# relaunch ScreenForge and it will ask again (Screen Recording may require a logout on
# some macOS versions).
set -euo pipefail

BUNDLE_ID="studio.screenforge.app"

pkill -f "ScreenForge.app/Contents/MacOS/ScreenForge" 2>/dev/null || true
sleep 0.5

for service in ScreenCapture Microphone Camera Accessibility SpeechRecognition; do
  echo "Resetting $service…"
  tccutil reset "$service" "$BUNDLE_ID" 2>/dev/null || true
done

echo "Done. Relaunch with: ./scripts/run.sh --no-build"
