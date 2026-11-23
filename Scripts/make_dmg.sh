#!/bin/bash
# Build CloudFerry.app (if needed) and package it into a drag-to-install DMG.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/CloudFerry.app"
[ -d "$APP" ] || ./Scripts/build_app.sh release
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/CloudFerry-${VERSION}-arm64.dmg"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/CloudFerry.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/First launch – read me.txt" <<'TXT'
CloudFerry is free and open source, but it is not notarized by Apple
(that needs a paid Apple Developer account). macOS will block it the
first time you open it. To allow it:

  1. Drag CloudFerry into Applications and open it once.
     When macOS says it can't verify the app, click "Done".
  2. Open System Settings → Privacy & Security, scroll down to
     "CloudFerry was blocked…", click "Open Anyway" and confirm.

Or, in Terminal:
  xattr -dr com.apple.quarantine /Applications/CloudFerry.app

Source code and help: https://github.com/brendanc321/CloudFerry
TXT

rm -f "$DMG"
hdiutil create -volname "CloudFerry ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "==> $DMG"
