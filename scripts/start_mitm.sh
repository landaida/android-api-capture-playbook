#!/usr/bin/env bash
# Start mitmdump with the WebSocket realtime addon and point the emulator at it.
#
# Usage:  ANDROID_SERIAL=emulator-5554 MITM_PORT=8080 ./scripts/start_mitm.sh [extra mitmdump args]
#   e.g.  ./scripts/start_mitm.sh --view-filter '~d api.example.com'
#
# Output (in captures/<timestamp>/):
#   flows.mitm          full flow dump; read with `mitmproxy -nr flows.mitm`
#   ws_realtime.jsonl   WebSocket frames, written the moment they arrive
#   mitmdump.log
# Stop with Ctrl-C; the emulator proxy setting is removed on exit.
#
# Env:
#   MITM_PORT       listen port                       (default: 8080)
#   MITM_CONFDIR    CA / config directory             (default: ./mitmconf)
#   ANDROID_SERIAL  adb serial; leave empty to skip proxy setup
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MITM_PORT="${MITM_PORT:-8080}"
MITM_CONFDIR="${MITM_CONFDIR:-$ROOT/mitmconf}"
OUT="$ROOT/captures/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT" "$MITM_CONFDIR"

command -v mitmdump >/dev/null || { echo "mitmdump not found: pip install mitmproxy" >&2; exit 1; }

set_proxy() {
  [ -n "${ANDROID_SERIAL:-}" ] || return 0
  # 10.0.2.2 is the host machine as seen from the Android emulator.
  adb -s "$ANDROID_SERIAL" shell settings put global http_proxy "$1"
}
cleanup() { set_proxy ":0" || true; echo "proxy removed"; }
trap cleanup EXIT

set_proxy "10.0.2.2:${MITM_PORT}"
echo "[*] proxy -> 10.0.2.2:${MITM_PORT}; capture dir: $OUT"

WS_REALTIME_LOG="$OUT/ws_realtime.jsonl" mitmdump \
  --listen-port "$MITM_PORT" \
  --set confdir="$MITM_CONFDIR" \
  --set stream_large_bodies=5m \
  -w "$OUT/flows.mitm" \
  -s "$ROOT/addons/ws_realtime_addon.py" \
  "$@" 2>&1 | tee "$OUT/mitmdump.log"
