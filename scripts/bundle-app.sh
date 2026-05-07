#!/usr/bin/env bash
# Bundle the SwiftPM binary into a proper Ouroburn.app so AppKit + UserNotifications
# can resolve a CFBundleIdentifier. Required because SwiftPM produces a loose Mach-O.
set -euo pipefail

BUILD_CONFIG=${1:-release}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$ROOT/.build/$BUILD_CONFIG"
APP_DIR="$ROOT/.build/Ouroburn.app"
BUNDLE_ID="dev.sheldonhull.ouroburn"
DISPLAY_NAME="ouroburn"
VERSION="0.1.0"

# Trigger a SwiftPM build for the chosen configuration when the binary is missing.
if [[ ! -x "$BIN_DIR/ouroburn" ]]; then
    if [[ "$BUILD_CONFIG" == "release" ]]; then
        (cd "$ROOT" && swift build -c release)
    else
        (cd "$ROOT" && swift build)
    fi
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/ouroburn" "$APP_DIR/Contents/MacOS/ouroburn"

cat >"$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>      <string>en</string>
    <key>CFBundleExecutable</key>             <string>ouroburn</string>
    <key>CFBundleIdentifier</key>             <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>  <string>6.0</string>
    <key>CFBundleName</key>                   <string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key>            <string>ouroburn</string>
    <key>CFBundlePackageType</key>            <string>APPL</string>
    <key>CFBundleShortVersionString</key>     <string>$VERSION</string>
    <key>CFBundleVersion</key>                <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>         <string>14.0</string>
    <key>LSUIElement</key>                    <true/>
    <key>NSHighResolutionCapable</key>        <true/>
    <key>NSPrincipalClass</key>               <string>NSApplication</string>
    <key>NSUserNotificationAlertStyle</key>   <string>banner</string>
</dict>
</plist>
PLIST

# Adhoc-sign so macOS allows the app to launch and request notification authorization.
codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "Built $APP_DIR"
