#!/usr/bin/env bash
# Block QUIC / HTTP-3 (UDP 443) on a rootable emulator so apps fall back to TCP (HTTP/2),
# which mitmproxy can intercept. Without this you typically see only SDK/analytics traffic
# and blank WebViews, because HTTP/3 bypasses a TCP proxy entirely.
#
# Not persistent: re-run after every emulator reboot, then force-stop and reopen the app.
#
# Usage:  ANDROID_SERIAL=emulator-5554 ./scripts/block_quic.sh [on|off|status]
set -euo pipefail

ADB="${ADB:-adb}"
[ -n "${ANDROID_SERIAL:-}" ] && ADB="$ADB -s $ANDROID_SERIAL"
ACTION="${1:-on}"

$ADB root >/dev/null 2>&1 || true
$ADB wait-for-device
sleep 1

# Run iptables/ip6tables as root, adb root already gives uid 0.
ipt() { $ADB shell "$1" -w "${@:2}"; }

rule=(OUTPUT -p udp --dport 443 -j REJECT)
for bin in iptables ip6tables; do
  case "$ACTION" in
    on)
      if ipt "$bin" -C "${rule[@]}" 2>/dev/null; then
        echo "$bin: rule already present"
      else
        ipt "$bin" -I "${rule[@]}"; echo "$bin: UDP 443 now rejected"
      fi ;;
    off)
      ipt "$bin" -D "${rule[@]}" 2>/dev/null && echo "$bin: rule removed" || echo "$bin: no rule to remove" ;;
    status)
      echo "--- $bin"; $ADB shell "$bin -w -S OUTPUT" | grep -E 'dport 443' || echo "(no QUIC rule)" ;;
    *) echo "usage: $0 [on|off|status]" >&2; exit 2 ;;
  esac
done
[ "$ACTION" = "on" ] && echo "Force-stop and reopen the app so it re-negotiates over TCP."
exit 0
