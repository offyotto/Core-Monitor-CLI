#!/usr/bin/env bash
set -euo pipefail

REPO_SLUG="${REPO_SLUG:-offyotto-sl3/Core-Monitor-CLI}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
SUPPORT_DIR="${SUPPORT_DIR:-$HOME/.local/share/core-monitor-cli}"
APP_DIR="$SUPPORT_DIR/CoreMonitorBlessHost.app"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

command -v curl >/dev/null 2>&1 || { echo "curl is required"; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "tar is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required"; exit 1; }

RELEASE_API="https://api.github.com/repos/${REPO_SLUG}/releases/latest"
ARCHIVE_URL="$(curl -fsSL "$RELEASE_API" | python3 -c '
import json, sys
release = json.load(sys.stdin)
for asset in release.get("assets", []):
    url = asset.get("browser_download_url", "")
    if url.endswith(".tar.gz") and "core-monitor-cli-" in url:
        print(url)
        raise SystemExit(0)
raise SystemExit("no .tar.gz release asset found")
')"

mkdir -p "$BIN_DIR" "$SUPPORT_DIR"

curl -fsSL "$ARCHIVE_URL" -o "$TMP_DIR/core-monitor-cli.tar.gz"
tar -xzf "$TMP_DIR/core-monitor-cli.tar.gz" -C "$TMP_DIR"

install -m 0755 "$TMP_DIR/bin/core-monitor" "$BIN_DIR/core-monitor"
rm -rf "$APP_DIR"
cp -R "$TMP_DIR/libexec/CoreMonitorBlessHost.app" "$APP_DIR"

echo "Installed core-monitor to $BIN_DIR/core-monitor"
echo "Installed bless host bundle to $APP_DIR"

"$BIN_DIR/core-monitor" helper install
"$BIN_DIR/core-monitor" helper status
