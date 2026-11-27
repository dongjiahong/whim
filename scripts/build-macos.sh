#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT_DIR/scripts/build-core-macos.sh"

MAC_DIR="$ROOT_DIR/macos"
APP="$ROOT_DIR/dist/Whim.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Building macOS SwiftUI app (Release WMO) via swiftc..."
swiftc -O -whole-module-optimization -parse-as-library \
  -target arm64-apple-macosx14.0 \
  -I "$MAC_DIR/Sources/CWhimCore" \
  -L "$MAC_DIR/Sources/CWhimCore" \
  -lwhimcore \
  -framework AppKit \
  -framework SwiftUI \
  -framework CoreImage \
  -framework Carbon \
  -framework UserNotifications \
  -framework Security \
  -framework SystemConfiguration \
  -lresolv \
  "$MAC_DIR/Sources/Whim/CoreBridge.swift" \
  "$MAC_DIR/Sources/Whim/DesignTokens.swift" \
  "$MAC_DIR/Sources/Whim/QRCodeHelper.swift" \
  "$MAC_DIR/Sources/Whim/ImageLightboxView.swift" \
  "$MAC_DIR/Sources/Whim/NoteThreadSheet.swift" \
  "$MAC_DIR/Sources/Whim/TagRenameSheet.swift" \
  "$MAC_DIR/Sources/Whim/InlineRichEditor.swift" \
  "$MAC_DIR/Sources/Whim/MarkdownBlockView.swift" \
  "$MAC_DIR/Sources/Whim/Updater.swift" \
  "$MAC_DIR/Sources/Whim/SettingsView.swift" \
  "$MAC_DIR/Sources/Whim/HotKeyManager.swift" \
  "$MAC_DIR/Sources/Whim/StatusBarPopoverView.swift" \
  "$MAC_DIR/Sources/Whim/WhimApp.swift" \
  -o "$APP/Contents/MacOS/Whim"

cp "$MAC_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$MAC_DIR/Resources/AppIcon.icns" ]; then
  cp "$MAC_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
if [ -f "$MAC_DIR/Resources/MenuBarIcon@2x.png" ]; then
  cp "$MAC_DIR/Resources/MenuBarIcon@2x.png" "$APP/Contents/Resources/MenuBarIcon@2x.png"
fi
if [ -d "$MAC_DIR/Resources/Fonts" ]; then
  cp -R "$MAC_DIR/Resources/Fonts" "$APP/Contents/Resources/Fonts"
fi

echo "==> Ad-hoc signing Whim.app (required for macOS Notification Center)..."
codesign --force --deep --sign - "$APP"

echo "Built and signed $APP"
