#!/bin/bash
# Download the official rclone binary that CloudFerry bundles, and verify its checksum.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="v1.74.3"
ZIP="rclone-${VERSION}-osx-arm64.zip"
URL="https://downloads.rclone.org/${VERSION}/${ZIP}"
# SHA-256 of the rclone binary inside the zip (osx-arm64, ${VERSION})
EXPECTED="9a156afbdd0a6ade42b0b40e7c30240119e2c82914bc8d7059a94dd9242ca2ed"

if [ -x Vendor/rclone ] && [ "$(shasum -a 256 Vendor/rclone | awk '{print $1}')" = "$EXPECTED" ]; then
  echo "rclone ${VERSION} already present"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "==> Downloading rclone ${VERSION} from ${URL}"
curl -fL --retry 3 -o "$TMP/$ZIP" "$URL"
unzip -q "$TMP/$ZIP" -d "$TMP"
BIN="$(find "$TMP" -type f -name rclone | head -1)"
GOT="$(shasum -a 256 "$BIN" | awk '{print $1}')"
if [ "$GOT" != "$EXPECTED" ]; then
  echo "Checksum mismatch for rclone: got $GOT, expected $EXPECTED" >&2
  exit 1
fi
mkdir -p Vendor
cp "$BIN" Vendor/rclone
chmod +x Vendor/rclone
echo "rclone ${VERSION} saved to Vendor/rclone (checksum OK)"
