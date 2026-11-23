#!/bin/bash
# Build CloudFerry.app: compile with SwiftPM, then assemble a standard macOS app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

# Prefer the Command Line Tools toolchain (works even if Xcode's license hasn't been accepted).
if [ -d /Library/Developer/CommandLineTools ]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

CONFIG="${1:-release}"
APP="build/CloudFerry.app"
BIN_NAME="CloudFerry"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$BIN_NAME"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"
# SwiftPM stamps the binary with SDK 13.0, which makes macOS 26+ treat the app as legacy and turn off
# the Liquid Glass look. Stamp the real SDK version (the minimum OS stays 13.0).
SDK_VER="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo "")"
if [ -n "$SDK_VER" ] && command -v vtool >/dev/null; then
  vtool -set-build-version macos 13.0 "$SDK_VER" -replace -output "$APP/Contents/MacOS/$BIN_NAME.tmp" "$APP/Contents/MacOS/$BIN_NAME" \
    && mv "$APP/Contents/MacOS/$BIN_NAME.tmp" "$APP/Contents/MacOS/$BIN_NAME" && echo "  stamped SDK $SDK_VER (enables Liquid Glass)"
fi

# Bundle rclone so the app is self-contained (downloaded and checksum-verified on first build)
[ -x Vendor/rclone ] || ./Scripts/fetch_rclone.sh
if [ -f Vendor/rclone ]; then
  cp Vendor/rclone "$APP/Contents/Resources/rclone"
  chmod +x "$APP/Contents/Resources/rclone"
  echo "  bundled rclone ($(du -h Vendor/rclone | awk '{print $1}'))"
fi

echo "==> App icon"
ICONSET="build/CloudFerry.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
if [ -f Resources/AppIcon.png ]; then
  # Scale the 1024px artwork (Resources/AppIcon.png) to every iconset size
  for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x 128:icon_128x128 256:icon_128x128@2x \
              256:icon_256x256 512:icon_256x256@2x 512:icon_512x512 1024:icon_512x512@2x; do
    px="${spec%%:*}"; name="${spec#*:}"
    sips -z "$px" "$px" Resources/AppIcon.png --out "$ICONSET/$name.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/CloudFerry.icns" && echo "  icon OK (Resources/AppIcon.png)" || echo "  iconutil failed, skipping icon"
elif CLOUDFERRY_MAKEICON="$ICONSET" "$BIN_PATH" >/dev/null 2>&1 && ls "$ICONSET"/*.png >/dev/null 2>&1; then
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/CloudFerry.icns" 2>/dev/null && echo "  icon OK (drawn in code)" || echo "  iconutil failed, skipping icon"
else
  echo "  icon rendering failed, skipping"
fi
for f in LogoTile.png MenuGlyph.png; do [ -f "Resources/$f" ] && cp "Resources/$f" "$APP/Contents/Resources/$f"; done
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>CloudFerry</string>
  <key>CFBundleDisplayName</key><string>CloudFerry</string>
  <key>CFBundleIdentifier</key><string>com.cloudferry.app</string>
  <key>CFBundleExecutable</key><string>CloudFerry</string>
  <key>CFBundleIconFile</key><string>CloudFerry</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>14</string>
  <key>CFBundleShortVersionString</key><string>1.3.1</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Folder or file to back up</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.folder</string>
        <string>public.volume</string>
        <string>public.item</string>
      </array>
    </dict>
  </array>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>CloudFerry · MIT License · a front-end for rclone (MIT).</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Ad-hoc signing (bundled rclone first, then the app)"
if [ -f "$APP/Contents/Resources/rclone" ]; then
  codesign --force -s - "$APP/Contents/Resources/rclone" 2>/dev/null || true
fi
codesign --force -s - "$APP" 2>/dev/null || true

echo "==> Done: $APP"
echo "Run: open '$PWD/$APP'"
