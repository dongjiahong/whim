#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT_DIR/scripts/build-macos.sh"
"$ROOT_DIR/scripts/build-mcp.sh"

SRC_APP="$ROOT_DIR/dist/Whim.app"
DST_APP="/Applications/Whim.app"

if [ "${1:-}" = "--no-install" ]; then
  echo "Built without installing to /Applications: $SRC_APP"
  exit 0
fi

echo "==> Installing Whim.app to $DST_APP..."
pkill -x Whim 2>/dev/null || true
sleep 0.5
rm -rf "$DST_APP"
cp -R "$SRC_APP" "$DST_APP"

echo "==> Launching Whim..."
open "$DST_APP"
echo "Installed $DST_APP (MCP binary: $ROOT_DIR/dist/whim-mcp)"
