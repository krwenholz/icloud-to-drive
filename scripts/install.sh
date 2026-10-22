#!/usr/bin/env bash
# Builds the app and installs it to /Applications, replacing any running copy.
# Uses ditto rather than cp so an existing bundle is replaced without per-file prompts.
set -euo pipefail
cd "$(dirname "$0")/.."

app_name="Drive Mirror.app"
built="build/DerivedData/Build/Products/Debug/$app_name"
installed="/Applications/$app_name"

scripts/test.sh

if pgrep -xq "Drive Mirror"; then
  echo "==> quitting the running app"
  osascript -e 'tell application "Drive Mirror" to quit' || true
  for _ in {1..20}; do pgrep -xq "Drive Mirror" || break; sleep 0.25; done
fi

echo "==> installing to $installed"
/bin/rm -rf "$installed"
ditto "$built" "$installed"

echo "==> launching"
open "$installed"
