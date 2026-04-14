#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TEAM_ID="${TEAM_ID:-TEAMIDPLACEHOLDER}"
CLI_BUNDLE_ID="${CLI_BUNDLE_ID:-CoreTools.Core-Monitor-CLI}"
BLESS_HOST_BUNDLE_ID="${BLESS_HOST_BUNDLE_ID:-CoreTools.Core-Monitor-CLI.BlessHost}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M%S)}"
ARCHS="${ARCHS:-arm64}"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
OUTPUT_ROOT="${OUTPUT_ROOT:-$REPO_ROOT/dist}"
STAGE_DIR="$OUTPUT_ROOT/stage"
ARTIFACT_NAME="core-monitor-cli-${VERSION}"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/bin" "$STAGE_DIR/libexec"

TEAM_ID="$TEAM_ID" \
CLI_BUNDLE_ID="$CLI_BUNDLE_ID" \
BLESS_HOST_BUNDLE_ID="$BLESS_HOST_BUNDLE_ID" \
VERSION="$VERSION" \
BUILD_NUMBER="$BUILD_NUMBER" \
  "$REPO_ROOT/Scripts/render-smjobbless-plists.sh"

build_one() {
  local arch="$1"
  local product="$2"
  local build_path="$REPO_ROOT/.build/${BUILD_CONFIGURATION}-${arch}"

  swift build \
    -c "$BUILD_CONFIGURATION" \
    --arch "$arch" \
    --product "$product" \
    --build-path "$build_path" >&2

  echo "$build_path/${arch}-apple-macosx/${BUILD_CONFIGURATION}"
}

merge_product() {
  local product_name="$1"
  local output_path="$2"
  local first=1
  local inputs=()

  for arch in $ARCHS; do
    local build_dir
    build_dir="$(build_one "$arch" "$product_name")"
    inputs+=("$build_dir/$product_name")
  done

  mkdir -p "$(dirname "$output_path")"
  if [[ "${#inputs[@]}" -eq 1 ]]; then
    cp "${inputs[0]}" "$output_path"
  else
    lipo -create "${inputs[@]}" -output "$output_path"
  fi
  chmod +x "$output_path"
}

merge_product "core-monitor" "$STAGE_DIR/bin/core-monitor"
merge_product "core-monitor-helper" "$STAGE_DIR/libexec/ventaphobia.smc-helper"
merge_product "core-monitor-bless-host" "$STAGE_DIR/libexec/core-monitor-bless-host"

APP_DIR="$STAGE_DIR/libexec/CoreMonitorBlessHost.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Library/LaunchServices"
cp "$STAGE_DIR/libexec/core-monitor-bless-host" "$APP_DIR/Contents/MacOS/core-monitor-bless-host"
cp "$STAGE_DIR/libexec/ventaphobia.smc-helper" "$APP_DIR/Contents/Library/LaunchServices/ventaphobia.smc-helper"
cp "$REPO_ROOT/BuildSupport/Generated/CoreMonitorBlessHost-Info.plist" "$APP_DIR/Contents/Info.plist"

sign_path() {
  local identifier="$1"
  local entitlements="$2"
  local path="$3"

  codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$SIGNING_IDENTITY" \
    --identifier "$identifier" \
    --entitlements "$entitlements" \
    "$path"
}

sign_path "$CLI_BUNDLE_ID" "$REPO_ROOT/Support/CodeSign/CLI.entitlements" "$STAGE_DIR/bin/core-monitor"
sign_path "ventaphobia.smc-helper" "$REPO_ROOT/Support/CodeSign/Helper.entitlements" "$APP_DIR/Contents/Library/LaunchServices/ventaphobia.smc-helper"
codesign \
  --force \
  --options runtime \
  --timestamp \
  --sign "$SIGNING_IDENTITY" \
  --entitlements "$REPO_ROOT/Support/CodeSign/BlessHost.entitlements" \
  "$APP_DIR"

codesign --verify --strict --verbose=2 "$STAGE_DIR/bin/core-monitor"
codesign --verify --strict --verbose=2 "$APP_DIR/Contents/Library/LaunchServices/ventaphobia.smc-helper"
codesign --verify --strict --verbose=2 "$APP_DIR"

mkdir -p "$OUTPUT_ROOT"
TAR_PATH="$OUTPUT_ROOT/${ARTIFACT_NAME}.tar.gz"
ZIP_PATH="$OUTPUT_ROOT/${ARTIFACT_NAME}.zip"
rm -f "$TAR_PATH" "$ZIP_PATH"

tar -C "$STAGE_DIR" -czf "$TAR_PATH" .
ditto -c -k --keepParent "$STAGE_DIR" "$ZIP_PATH"

echo "Created:"
echo "  $TAR_PATH"
echo "  $ZIP_PATH"
