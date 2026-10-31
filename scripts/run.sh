#!/bin/bash
# Builds (unless --no-build) and launches ScreenForge.
#
#   ./scripts/run.sh              build + launch
#   ./scripts/run.sh --no-build   launch the existing build/ScreenForge.app
#   ./scripts/run.sh --logs       build + launch, streaming logs to build/logs/screenforge.log
set -euo pipefail

cd "$(dirname "$0")/.."

BUILD=1
LOGS=0
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    --logs) LOGS=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [ "$BUILD" = "1" ]; then
  ./scripts/build-app.sh
fi

if [ "$LOGS" = "1" ]; then
  mkdir -p build/logs
  LOG="$PWD/build/logs/screenforge.log"
  : > "$LOG"
  # Launch the binary directly so stdout/stderr land in the log; `open --stdout` is
  # unreliable when LaunchServices has a stale registration for an ad-hoc signed build.
  nohup "$PWD/build/ScreenForge.app/Contents/MacOS/ScreenForge" > "$LOG" 2>&1 &
  echo $! > build/logs/pid
  echo "Launching with logs: build/logs/screenforge.log"
  echo "Follow with: tail -f build/logs/screenforge.log"
  exit 0
fi

open build/ScreenForge.app
