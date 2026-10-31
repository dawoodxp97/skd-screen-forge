#!/bin/bash
# Runs the core test suite.
#
# With only Command Line Tools installed, SwiftPM does not find the Swift Testing
# macro plugin (`TestingMacros`) on its own, so this script points the compiler at
# the plugin directory that ships with the toolchain. With a full Xcode install the
# plugin is discovered normally and the extra flag is harmless.
set -euo pipefail

cd "$(dirname "$0")/.."

FLAGS=()

# Command Line Tools ships `libTestingMacros.dylib` in a nested `testing` folder
# that is not on the default plugin search path.
TESTING_PLUGIN_DIR="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [ -d "$TESTING_PLUGIN_DIR" ]; then
  FLAGS+=(-Xswiftc -plugin-path -Xswiftc "$TESTING_PLUGIN_DIR")
fi

exec swift test "$@" "${FLAGS[@]}"
