#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/usr/local/go/bin:/opt/homebrew/bin:/opt/homebrew/opt/openjdk/bin:$(go env GOPATH)/bin:$PATH"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export PATH="$ANDROID_HOME/platform-tools:$PATH"

"$ROOT_DIR/scripts/build-android.sh"

APK="$ROOT_DIR/android/app/build/outputs/apk/debug/app-debug.apk"
if ! command -v adb >/dev/null 2>&1; then
  echo "adb not found. APK built at: $APK"
  exit 1
fi

echo "==> Installing APK to connected Android device (preserving data)..."
adb install -r "$APK"
adb shell am start -n com.whim.app/.MainActivity >/dev/null 2>&1 || true
echo "Installed and launched Whim on Android."
