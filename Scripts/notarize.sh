#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION="${VERSION:-0.1.0}"
OUTPUT_ROOT="${OUTPUT_ROOT:-$REPO_ROOT/dist}"
APP_DIR="$OUTPUT_ROOT/stage/libexec/CoreMonitorBlessHost.app"
ZIP_PATH="$OUTPUT_ROOT/core-monitor-cli-${VERSION}.zip"
NOTARY_PROFILE="${NOTARY_PROFILE:?Set NOTARY_PROFILE to a stored notarytool profile name}"

[[ -f "$ZIP_PATH" ]] || { echo "Missing $ZIP_PATH. Run Scripts/build-dist.sh first."; exit 1; }

xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_DIR"
spctl --assess --type exec --verbose "$OUTPUT_ROOT/stage/bin/core-monitor"
spctl --assess --type execute --verbose "$APP_DIR"
