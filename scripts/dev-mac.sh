#!/usr/bin/env bash
# macOS dev loop for xChup (snip)
set -euo pipefail
cd "$(dirname "$0")/.."

ACTION="${1:-run}"

case "$ACTION" in
  build)
    echo "==> Building snip-core, snip-darwin, snip-daemon, snip-cli..."
    cargo build
    echo "==> Building native Swift AppKit UI (snip-ui)..."
    swiftc -O -framework AppKit app-mac/main.swift -o target/debug/snip-ui
    echo "Build complete in target/debug/"
    ;;

  run | start)
    "$0" build
    "$0" stop 2>/dev/null || true
    echo "==> Starting snipd in background..."
    nohup target/debug/snipd >/tmp/snipd.log 2>&1 &
    PID=$!
    for _ in $(seq 30); do
      if target/debug/snip ping >/dev/null 2>&1; then
        echo "snipd is running (PID $PID)!"
        echo "Try: target/debug/snip fullscreen"
        echo "Try: target/debug/snip area"
        echo "Try: target/debug/snip pin"
        exit 0
      fi
      sleep 0.1
    done
    echo "Failed to start snipd; check /tmp/snipd.log" >&2
    exit 1
    ;;

  stop)
    if pgrep -x snipd >/dev/null 2>&1; then
      echo "Stopping snipd..."
      target/debug/snip quit 2>/dev/null || pkill -x snipd || true
      echo "snipd stopped."
    else
      echo "snipd is not running."
    fi
    ;;

  status)
    if pgrep -x snipd >/dev/null 2>&1; then
      target/debug/snip status
    else
      echo "snipd is stopped."
    fi
    ;;

  log)
    exec tail -f /tmp/snipd.log
    ;;

  *)
    echo "Usage: $0 {build|run|stop|status|log}"
    exit 2
    ;;
esac
