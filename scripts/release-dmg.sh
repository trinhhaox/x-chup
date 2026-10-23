#!/usr/bin/env bash
# Build release packages (.dmg & .zip) for xChup macOS
set -euo pipefail
cd "$(dirname "$0")/.."

APP_DIR="/Applications/xChup.app"
DIST_DIR="dist"

echo "==> Ensuring /Applications/xChup.app is built and up to date..."
./scripts/bundle-mac.sh

mkdir -p "$DIST_DIR"
DMG_PATH="$DIST_DIR/xChup.dmg"
ZIP_PATH="$DIST_DIR/xChup-macOS-arm64.zip"

echo "==> Packaging DMG..."
STAGING="/tmp/xchup_dmg_staging"
rm -rf "$STAGING" "$DMG_PATH" "$ZIP_PATH"
mkdir -p "$STAGING"

cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "xChup" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGING"

echo "==> Packaging ZIP..."
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

echo ""
echo "=========================================================="
echo "  Release packages ready in ${DIST_DIR}/:"
ls -lh "$DIST_DIR"
echo "=========================================================="
