#!/usr/bin/env bash
# Create (and optionally boot) a ROOTABLE Android emulator for traffic capture.
#
# Why google_apis (not google_apis_playstore): the former is a userdebug build, so `adb root`
# works, which system-CA installation needs. Play Store images are `user` builds without root.
#
# Usage:
#   AVD_NAME=capture_api36 ./scripts/create_avd.sh            # create only
#   AVD_NAME=capture_api36 BOOT=1 ./scripts/create_avd.sh     # create and boot
#
# Env:
#   AVD_NAME      name of the AVD                      (default: capture_api36)
#   API_LEVEL     Android API level                    (default: 36)
#   ABI           system image ABI                     (default: x86_64)
#   RAM_MB        guest RAM                            (default: 4096)
#   ANDROID_SDK_ROOT  SDK location                     (default: $HOME/Android/Sdk)
#   BOOT=1        launch the emulator after creation
#   EXTRA_EMU_ARGS  extra emulator flags (e.g. "-no-window" on CI)
set -euo pipefail

AVD_NAME="${AVD_NAME:-capture_api36}"
API_LEVEL="${API_LEVEL:-36}"
ABI="${ABI:-x86_64}"
RAM_MB="${RAM_MB:-4096}"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
IMAGE="system-images;android-${API_LEVEL};google_apis;${ABI}"

SDKMANAGER="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager"
AVDMANAGER="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/avdmanager"
EMULATOR="$ANDROID_SDK_ROOT/emulator/emulator"

for t in "$SDKMANAGER" "$AVDMANAGER"; do
  [ -x "$t" ] || { echo "Missing $t - install the Android SDK command-line tools first." >&2; exit 1; }
done
[ -r /dev/kvm ] || echo "WARN: /dev/kvm not readable; the emulator will be very slow without hardware acceleration." >&2

echo "[*] Installing system image: $IMAGE"
yes | "$SDKMANAGER" --licenses >/dev/null 2>&1 || true
"$SDKMANAGER" "$IMAGE" "emulator" "platform-tools"

if "$AVDMANAGER" list avd -c | grep -qx "$AVD_NAME"; then
  echo "[*] AVD '$AVD_NAME' already exists - leaving it untouched."
else
  echo "[*] Creating AVD '$AVD_NAME'"
  echo no | "$AVDMANAGER" create avd -n "$AVD_NAME" -k "$IMAGE" -d pixel_6
  CFG="$HOME/.android/avd/${AVD_NAME}.avd/config.ini"
  if [ -f "$CFG" ]; then
    sed -i '/^hw.ramSize=/d' "$CFG"
    echo "hw.ramSize=${RAM_MB}" >> "$CFG"
  fi
fi

if [ "${BOOT:-0}" = "1" ]; then
  echo "[*] Booting (writable system partition is required for CA installation)"
  # shellcheck disable=SC2086
  setsid "$EMULATOR" -avd "$AVD_NAME" -writable-system -no-snapshot -no-boot-anim \
    -gpu swiftshader_indirect -no-metrics ${EXTRA_EMU_ARGS:-} </dev/null >/tmp/emulator-"$AVD_NAME".log 2>&1 &
  echo "    log: /tmp/emulator-$AVD_NAME.log"
  "$ANDROID_SDK_ROOT/platform-tools/adb" wait-for-device
  echo "    device is up. Next: scripts/start_mitm.sh, then scripts/inject_ca.sh"
else
  echo "Created. Boot it with:"
  echo "  $EMULATOR -avd $AVD_NAME -writable-system -no-snapshot -gpu swiftshader_indirect"
fi
