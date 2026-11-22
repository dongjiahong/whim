#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/usr/local/go/bin:/opt/homebrew/bin:$PATH"

echo "==> Running Go core tests..."
cd "$ROOT_DIR/core"
go test ./... -v
