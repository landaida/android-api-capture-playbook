#!/usr/bin/env bash
# Install the mitmproxy CA into the emulator's SYSTEM trust store.
#
#  * Android 14+ : the system store lives in the conscrypt APEX (/apex/com.android.conscrypt/cacerts).
#                  We mount a tmpfs over it (pre-filled with all stock certs + ours) in the root mount
#                  namespace AND in every zygote namespace, so already-running and future apps see it.
#  * Android <14 : fall back to remounting /system read-write and copying into /system/etc/security/cacerts.
#
# Not persistent: re-run after every emulator reboot, then force-stop and reopen the app.
#
# Usage:  ANDROID_SERIAL=emulator-5554 [MITM_CONFDIR=./mitmconf] ./scripts/inject_ca.sh
# Prereq: mitmproxy has run once (scripts/start_mitm.sh) so the CA exists; emulator booted with
#         -writable-system from a google_apis (userdebug) image.
# Env:
#   ANDROID_SERIAL  adb serial                          (default: first device)
#   MITM_CONFDIR    mitmproxy confdir                   (default: ./mitmconf)
#   SELINUX_PERMISSIVE  1 = setenforce 0 on the throwaway emulator (default: 1; the tmpfs label
#                       is otherwise unreadable by app domains on some builds)
set -euo pipefail

ADB="${ADB:-adb}"
[ -n "${ANDROID_SERIAL:-}" ] && ADB="$ADB -s $ANDROID_SERIAL"
MITM_CONFDIR="${MITM_CONFDIR:-$(cd "$(dirname "$0")/.." && pwd)/mitmconf}"
CA="$MITM_CONFDIR/mitmproxy-ca-cert.pem"
SELINUX_PERMISSIVE="${SELINUX_PERMISSIVE:-1}"

[ -f "$CA" ] || { echo "CA not found: $CA - run scripts/start_mitm.sh once to generate it." >&2; exit 1; }

# Android names trust anchors <subject_hash_old>.0
HASH="$(openssl x509 -inform PEM -subject_hash_old -noout -in "$CA")"
CERT="$HASH.0"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
openssl x509 -inform PEM -in "$CA" -out "$TMP/$CERT"
echo "[*] CA subject hash: $HASH"

$ADB root >/dev/null 2>&1 || true
$ADB wait-for-device
sleep 2
[ "$($ADB shell id -u | tr -d '\r')" = "0" ] || { echo "adb root failed - need a google_apis (userdebug) image." >&2; exit 1; }

$ADB push "$TMP/$CERT" "/data/local/tmp/$CERT" >/dev/null

# Script executed on the device as root.
cat > "$TMP/device.sh" <<'DEV'
#!/system/bin/sh
CERT="$1"; PERMISSIVE="$2"
APEX=/apex/com.android.conscrypt/cacerts
LEGACY=/system/etc/security/cacerts
SRC=/data/local/tmp/ca-copy

if [ -d "$APEX" ]; then
  # --- Android 14+ ---
  rm -rf $SRC; mkdir -p $SRC
  cp $APEX/* $SRC/ 2>/dev/null
  cp /data/local/tmp/$CERT $SRC/
  chmod 644 $SRC/*
  echo "certs to install: $(ls $SRC | wc -l)"
  [ "$PERMISSIVE" = "1" ] && setenforce 0

  overlay() {  # $1 = command prefix to enter a namespace (may be empty)
    $1 sh -c "umount $APEX 2>/dev/null; mount -t tmpfs tmpfs $APEX && cp $SRC/* $APEX/ && chmod 644 $APEX/*"
  }
  overlay ""
  for z in $(pidof zygote64) $(pidof zygote) $(pidof webview_zygote); do
    echo "[*] namespace of pid $z"
    overlay "nsenter --target $z --mount --"
  done
  Z=$(pidof zygote64 || pidof zygote)
  nsenter --target "$Z" --mount -- ls "$APEX/$CERT"
else
  # --- Android < 14 ---
  mount -o rw,remount /system 2>/dev/null || mount -o rw,remount / 2>/dev/null
  cp /data/local/tmp/$CERT $LEGACY/$CERT
  chmod 644 $LEGACY/$CERT
  ls -l $LEGACY/$CERT
fi
DEV
$ADB push "$TMP/device.sh" /data/local/tmp/inject_ca_device.sh >/dev/null
$ADB shell "sh /data/local/tmp/inject_ca_device.sh $CERT $SELINUX_PERMISSIVE"
echo "[+] CA $CERT installed. Force-stop and reopen the target app."
