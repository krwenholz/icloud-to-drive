#!/usr/bin/env bash
# Runs the package tests, then generates and builds the app.
# Builds unsigned when Config/Local.xcconfig has no DEVELOPMENT_TEAM, so the
# build still verifies on CI and on a fresh checkout.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> swift test"
swift test --package-path Packages/MirrorCore

echo "==> xcodegen generate"
mise exec -- xcodegen generate --quiet

signing_args=()
if ! grep -Eq '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]+' Config/Local.xcconfig 2>/dev/null; then
  echo "==> no DEVELOPMENT_TEAM in Config/Local.xcconfig; building unsigned"
  signing_args=(CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="")
fi

echo "==> xcodebuild build"
xcodebuild \
  -project DriveMirror.xcodeproj \
  -scheme DriveMirror \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  -quiet \
  build ${signing_args[@]+"${signing_args[@]}"}
