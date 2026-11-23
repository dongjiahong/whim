#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT_DIR/scripts/build-core-macos.sh"

MAC_DIR="$ROOT_DIR/macos"
APP="$ROOT_DIR/dist/Whim.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Building macOS SwiftUI app via swiftc..."
swiftc -O -parse-as-library \
  -target arm64-apple-macosx14.0 \
  -I "$MAC_DIR/Sources/CWhimCore" \
  -L "$MAC_DIR/Sources/CWhimCore" \
  -lwhimcore \
  -framework AppKit \
  -framework SwiftUI \
  -framework Carbon \
  -framework UserNotifications \
  -framework Security \
  -framework SystemConfiguration \
  -lresolv \
  "$MAC_DIR/Sources/Whim/CoreBridge.swift" \
  "$MAC_DIR/Sources/Whim/DesignTokens.swift" \
  "$MAC_DIR/Sources/Whim/InlineRichEditor.swift" \
  "$MAC_DIR/Sources/Whim/MarkdownBlockView.swift" \
  "$MAC_DIR/Sources/Whim/Updater.swift" \
  "$MAC_DIR/Sources/Whim/SettingsView.swift" \
  "$MAC_DIR/Sources/Whim/HotKeyManager.swift" \
  "$MAC_DIR/Sources/Whim/WhimApp.swift" \
  -o "$APP/Contents/MacOS/Whim"

cp "$MAC_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$MAC_DIR/Resources/AppIcon.icns" ]; then
  cp "$MAC_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
if [ -d "$MAC_DIR/Resources/Fonts" ]; then
  cp -R "$MAC_DIR/Resources/Fonts" "$APP/Contents/Resources/Fonts"
fi

echo "Built $APP"
