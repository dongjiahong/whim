#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/usr/local/go/bin:/opt/homebrew/bin:/opt/homebrew/opt/openjdk/bin:$(go env GOPATH)/bin:$PATH"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
if [ -z "${ANDROID_NDK_HOME:-}" ] && [ -d "$ANDROID_HOME/ndk" ]; then
  export ANDROID_NDK_HOME="$(ls -d "$ANDROID_HOME"/ndk/* 2>/dev/null | sort -V | tail -n 1)"
fi

if ! command -v gomobile >/dev/null 2>&1; then
  echo "gomobile not found. Install it once with:"
  echo "  go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init"
  exit 1
fi

mkdir -p "$ROOT_DIR/android/app/libs"
cd "$ROOT_DIR/core"
echo "==> Building whimcore.aar via gomobile bind..."
gomobile bind -target=android -androidapi 26 -o "$ROOT_DIR/android/app/libs/whimcore.aar" ./mobile

echo "==> Building Android Debug APK via Gradle CLI..."
cd "$ROOT_DIR/android"
if [ -x "./gradlew" ]; then
  ./gradlew assembleDebug
else
  gradle assembleDebug
fi

echo "APK ready at: $ROOT_DIR/android/app/build/outputs/apk/debug/app-debug.apk"
