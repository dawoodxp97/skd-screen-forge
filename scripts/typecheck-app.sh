#!/bin/bash
# Type-checks the SwiftUI app layer without a full Xcode install.
#
# Requires Xcode's SwiftUI itoolchain macros (libSwiftUIMacros.dylib). Without a full
# Xcode install, this script explains what is missing instead of emitting hundreds of
# "plugin for module 'SwiftUIMacros' not found" errors.
set -euo pipefail

cd "$(dirname "$0")/.."

SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macos14.0"

PLUGIN_DIR="$(xcode-select -p)/usr/lib/swift/host/plugins"
if [ ! -f "$PLUGIN_DIR/libSwiftUIMacros.dylib" ]; then
  echo "SwiftUI macro plugin not found at $PLUGIN_DIR/libSwiftUIMacros.dylib"
  echo "The SwiftUI layer needs a full Xcode install (xcode-select -s /Applications/Xcode.app)."
  echo "Core targets still build and test with: swift build && scripts/test.sh"
  exit 2
fi

FILES=$(find ScreenForge -name '*.swift')

# UI files are listed first so a missing symbol is attributed to its declaration site.
swiftc -typecheck \
  -swift-version 6 \
  -strict-concurrency=complete \
  -sdk "$SDK" \
  -target "$TARGET" \
  -plugin-path "$PLUGIN_DIR" \
  -F "$(xcode-select -p)/Library/Developer/Frameworks" \
  $FILES
