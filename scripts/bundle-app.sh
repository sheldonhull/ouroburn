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

# Sign with stable dev cert when present so the designated requirement is pinned to
# the cert leaf instead of the cdhash; that lets TCC grants survive cdhash drift across
# rebuilds. Run `mise run cert:create` once to populate the keychain. Falls back to
# adhoc sign so first-time users (and CI) still get a launchable bundle.
CERT_NAME="${CERT_NAME:-Ouroburn Dev Signing}"
if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    codesign --force --deep --sign "$CERT_NAME" --timestamp=none "$APP_DIR" >/dev/null
    SIGN_MODE="cert: $CERT_NAME"
else
    codesign --force --deep --sign - "$APP_DIR" >/dev/null
    SIGN_MODE="adhoc (run 'mise run cert:create' to stop TCC re-prompts)"
fi

# Strip quarantine so Gatekeeper doesn't first-launch-prompt on a freshly built bundle.
xattr -cr "$APP_DIR" 2>/dev/null || true

echo "Built $APP_DIR"
echo "  signed: $SIGN_MODE"
