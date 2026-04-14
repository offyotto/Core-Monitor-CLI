#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

"$REPO_ROOT/Scripts/render-smjobbless-plists.sh"
swift build

echo
echo "== doctor =="
./.build/debug/core-monitor doctor || true

echo
echo "== helper status =="
./.build/debug/core-monitor helper status || true

echo
echo "== helper read FNum via local helper binary =="
./.build/debug/core-monitor-helper read FNum || true

echo
echo "== helper read F0Mn via local helper binary =="
./.build/debug/core-monitor-helper read F0Mn || true
