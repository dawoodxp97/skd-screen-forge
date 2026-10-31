#!/bin/bash
# Runs the full test suite inside Xcode (app-hosted, so Metal and SwiftUI are tested).
set -euo pipefail

cd "$(dirname "$0")/.."

select_xcode() {
  if xcodebuild -version >/dev/null 2>&1; then
    return
  fi
  for candidate in /Applications/Xcode*.app /Applications/Xcode.app; do
    if [ -d "$candidate/Contents/Developer" ]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      return
    fi
  done
  echo "Xcode not found." >&2
  exit 1
}

select_xcode

# A running copy would block the test host (LSMultipleInstancesProhibited).
pkill -f "ScreenForge.app/Contents/MacOS/ScreenForge" 2>/dev/null || true
sleep 0.5

xcodegen generate >/dev/null
xcodebuild test \
  -project ScreenForge.xcodeproj \
  -scheme ScreenForge \
  -destination 'platform=macOS' \
  -derivedDataPath .build/xcode \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=YES
