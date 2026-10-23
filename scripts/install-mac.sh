#!/usr/bin/env bash
# Install / Uninstall xChup on macOS
set -euo pipefail
cd "$(dirname "$0")/.."

APP_DIR="/Applications/xChup.app"
INSTALL_DIR="${HOME}/.local/bin"
PLIST_DIR="${HOME}/Library/LaunchAgents"
PLIST_NAME="com.trinhhaox.xchup.plist"

case "${1:-install}" in
  install)
    chmod +x scripts/bundle-mac.sh
    ./scripts/bundle-mac.sh
    ;;

  remove | uninstall)
    echo "==> Uninstalling xChup..."
    killall xChup 2>/dev/null || true
    killall snip-ui 2>/dev/null || true
    killall snipd 2>/dev/null || true

    launchctl unload "$PLIST_DIR/$PLIST_NAME" 2>/dev/null || true
    launchctl unload "$PLIST_DIR/com.trinhhaox.xchup.daemon.plist" 2>/dev/null || true
    launchctl unload "$PLIST_DIR/com.trinhhaox.xchup.tray.plist" 2>/dev/null || true

    rm -f "$PLIST_DIR/$PLIST_NAME" "$PLIST_DIR/com.trinhhaox.xchup.daemon.plist" "$PLIST_DIR/com.trinhhaox.xchup.tray.plist"
    rm -rf "$APP_DIR"
    rm -f "$INSTALL_DIR/snip" "$INSTALL_DIR/snipd" "$INSTALL_DIR/snip-ui" "$INSTALL_DIR/xchup"
    echo "xChup completely removed."
    ;;

  *)
    echo "Usage: $0 {install|remove}"
    exit 2
    ;;
esac
