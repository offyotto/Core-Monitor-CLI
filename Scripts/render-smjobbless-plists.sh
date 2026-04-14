#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="$REPO_ROOT/Support/SMJobBless"
OUTPUT_DIR="$REPO_ROOT/BuildSupport/Generated"

TEAM_ID="${TEAM_ID:-TEAMIDPLACEHOLDER}"
CLI_BUNDLE_ID="${CLI_BUNDLE_ID:-CoreTools.Core-Monitor-CLI}"
BLESS_HOST_BUNDLE_ID="${BLESS_HOST_BUNDLE_ID:-CoreTools.Core-Monitor-CLI.BlessHost}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-0}"

mkdir -p "$OUTPUT_DIR"

render() {
  local input="$1"
  local output="$2"

  sed \
    -e "s/__TEAM_ID__/${TEAM_ID}/g" \
    -e "s/__CLI_BUNDLE_ID__/${CLI_BUNDLE_ID}/g" \
    -e "s/__BLESS_HOST_BUNDLE_ID__/${BLESS_HOST_BUNDLE_ID}/g" \
    -e "s/__VERSION__/${VERSION}/g" \
    -e "s/__BUILD_NUMBER__/${BUILD_NUMBER}/g" \
    "$input" > "$output"
}

render \
  "$TEMPLATE_DIR/CoreMonitorHelper-Info.plist.template" \
  "$OUTPUT_DIR/CoreMonitorHelper-Info.plist"

render \
  "$TEMPLATE_DIR/CoreMonitorHelper-Launchd.plist.template" \
  "$OUTPUT_DIR/CoreMonitorHelper-Launchd.plist"

render \
  "$TEMPLATE_DIR/CoreMonitorBlessHost-Info.plist.template" \
  "$OUTPUT_DIR/CoreMonitorBlessHost-Info.plist"

echo "Rendered SMJobBless plists into $OUTPUT_DIR"
