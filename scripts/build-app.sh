#!/bin/bash
# Builds ScreenForge.app with Xcode and copies it to ./build.
#
# Ad-hoc signing is used so the sandbox entitlements (microphone, camera, speech,
# user-selected files) take effect on a development machine without a team ID.
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
  echo "Xcode not found. Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
}

select_xcode

command -v xcodegen >/dev/null 2>&1 || {
  echo "xcodegen is required: brew install xcodegen" >&2
  exit 1
}

CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED=".build/xcode"

xcodegen generate >/dev/null
xcodebuild \
  -project ScreenForge.xcodeproj \
  -scheme ScreenForge \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=YES \
  build

APP="$DERIVED/Build/Products/$CONFIGURATION/ScreenForge.app"
rm -rf build/ScreenForge.app
mkdir -p build
ditto "$APP" build/ScreenForge.app

echo "Built build/ScreenForge.app"
