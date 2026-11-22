#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/usr/local/go/bin:/opt/homebrew/bin:$PATH"

mkdir -p "$ROOT_DIR/dist"
cd "$ROOT_DIR/core"
go build -trimpath -ldflags="-s -w" -o "$ROOT_DIR/dist/whim-mcp" ./cmd/whim-mcp
echo "Built $ROOT_DIR/dist/whim-mcp"
