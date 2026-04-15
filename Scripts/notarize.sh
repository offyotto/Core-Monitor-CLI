#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION="${VERSION:-0.1.1}"
OUTPUT_ROOT="${OUTPUT_ROOT:-$REPO_ROOT/dist}"
APP_DIR="$OUTPUT_ROOT/stage/libexec/CoreMonitorBlessHost.app"
STAGE_DIR="$OUTPUT_ROOT/stage"
TAR_PATH="$OUTPUT_ROOT/core-monitor-cli-${VERSION}.tar.gz"
ZIP_PATH="$OUTPUT_ROOT/core-monitor-cli-${VERSION}.zip"
NOTARY_PROFILE="${NOTARY_PROFILE:?Set NOTARY_PROFILE to a stored notarytool profile name}"

[[ -f "$ZIP_PATH" ]] || { echo "Missing $ZIP_PATH. Run Scripts/build-dist.sh first."; exit 1; }

xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_DIR"

# Refresh the distributable archives so the shipped app bundle includes the stapled ticket.
rm -f "$TAR_PATH" "$ZIP_PATH"
tar -C "$STAGE_DIR" -czf "$TAR_PATH" .
ditto -c -k --keepParent "$STAGE_DIR" "$ZIP_PATH"

spctl --assess --type execute --verbose "$APP_DIR"
if ! spctl --assess --type exec --verbose "$OUTPUT_ROOT/stage/bin/core-monitor"; then
  echo "warning: spctl rejected the standalone CLI binary even though the notarization submission was accepted" >&2
fi
