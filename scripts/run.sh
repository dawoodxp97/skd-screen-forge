#!/bin/bash
# Builds (if needed) and launches ScreenForge.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ "${1:-}" != "--no-build" ]; then
  ./scripts/build-app.sh
fi

open build/ScreenForge.app
