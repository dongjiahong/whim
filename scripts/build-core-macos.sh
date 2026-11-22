#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/usr/local/go/bin:/opt/homebrew/bin:$PATH"

OUT_DIR="$ROOT_DIR/macos/Sources/CWhimCore"
mkdir -p "$OUT_DIR"

cd "$ROOT_DIR/core"
CGO_ENABLED=1 go build -buildmode=c-archive -trimpath -o "$OUT_DIR/libwhimcore.a" ./cbridge

cat > "$OUT_DIR/module.modulemap" <<'EOF'
module CWhimCore {
    header "libwhimcore.h"
    link "whimcore"
    export *
}
EOF

echo "Built $OUT_DIR/libwhimcore.a and libwhimcore.h"
