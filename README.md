# Android API Capture Playbook

A vendor-neutral toolkit for capturing the private HTTP and WebSocket API of an Android app, using a
rootable emulator and [mitmproxy](https://mitmproxy.org/), and then replaying those calls from plain Python.

It is written for **QA and automation engineers who must integrate with an app that has no public API**
(for example, your own product's mobile backend, or a partner app you are contractually allowed to test).
Everything here is a method plus small, readable scripts. No target-specific code is included.

## Architecture

```
 +-------------------------+      HTTP(S)/WS via proxy       +--------------------------+
 |  Android emulator       |  settings global http_proxy     |  Host                    |
 |  google_apis (userdebug)| ------------------------------> |  mitmdump :$MITM_PORT    |
 |  - mitm CA in system    |        10.0.2.2:$MITM_PORT     |   |-- flows.mitm         |
 |    store (APEX)         |                                 |   |-- ws_realtime.jsonl  |
 |  - UDP 443 rejected     | <------------------------------ |   '-- addons/*.py       |
 |    (no QUIC)            |                                 +------------+-------------+
 |  - target app ($PACKAGE)|                                              |
 +-------------------------+                                              v
                                                             examples/replay_request.py
                                                             (pure HTTP, no emulator)
```

## Repository layout

| Path | Purpose |
|---|---|
| `scripts/create_avd.sh` | Create a rootable `google_apis` AVD (boots with `-writable-system`) |
| `scripts/start_mitm.sh` | Run `mitmdump`, set the emulator proxy, log to `captures/<timestamp>/` |
| `scripts/inject_ca.sh` | Install the mitmproxy CA as a system CA (Android 14+ APEX, with pre-14 fallback) |
| `scripts/block_quic.sh` | Reject UDP 443 so HTTP/3 falls back to HTTP/2 over TCP |
| `addons/ws_realtime_addon.py` | Write WebSocket frames to JSONL as they arrive |
| `examples/replay_request.py` | Replay a captured call with `requests`, config from `.env` |
| `.env.example` | Placeholders for `PACKAGE`, `AVD_NAME`, `MITM_PORT`, token, base URL |

## Quick start

Prerequisites: Linux host with KVM, Android SDK command-line tools, `adb`, `openssl`, `pip install mitmproxy requests`.

```bash
cp .env.example .env && set -a && . ./.env && set +a   # PACKAGE, AVD_NAME, MITM_PORT, ANDROID_SERIAL

BOOT=1 ./scripts/create_avd.sh      # 1. rootable emulator, writable system
./scripts/start_mitm.sh             # 2. (separate terminal) generates the CA, sets the proxy
./scripts/inject_ca.sh              # 3. trust the CA system-wide
./scripts/block_quic.sh             # 4. force TCP
adb shell am force-stop "$PACKAGE"  # 5. restart the app, use it, watch captures/
```

## The playbook

### 1. A rootable emulator
Use a **`google_apis`** system image, not `google_apis_playstore`. The former is a `userdebug` build where
`adb root` works; Play Store images are `user` builds and cannot install system CAs. Start the emulator with
`-writable-system` and a software GPU (`-gpu swiftshader_indirect`) if the host is headless. Give it 3-4 GB RAM.
`scripts/create_avd.sh` does all of this.

If the app is not installable from an uncertified emulator's store, install it from an APK you are entitled to
use: `adb install-multiple base.apk split_config.*.apk`. ARM-only splits run on x86_64 images through binary translation.

### 2. Route traffic through mitmproxy
```bash
adb shell settings put global http_proxy 10.0.2.2:8080   # 10.0.2.2 = host as seen from the emulator
adb shell settings put global http_proxy :0              # remove
```
`start_mitm.sh` sets and removes this for you. Give each emulator its own `--set confdir=...` so CAs never mix.

### 3. Install the CA into the system store (Android 14+)
User-installed CAs are ignored by most apps (`networkSecurityConfig` defaults since API 24). The CA must be a
**system** CA. Since Android 14 the system store is served from the **conscrypt APEX**,
`/apex/com.android.conscrypt/cacerts/`, not `/system/etc/security/cacerts`. Copying into `/system` appears to
succeed but has no effect, so always verify at the APEX path.

`scripts/inject_ca.sh`:
1. computes the Android filename with `openssl x509 -subject_hash_old` -> `<hash>.0`;
2. mounts a tmpfs over the APEX directory, pre-filled with every stock certificate plus yours;
3. repeats the mount inside the mount namespace of every zygote (`nsenter --target <pid> --mount`), so apps that are
   already running and apps started later both see it;
4. sets SELinux permissive on the throwaway emulator, because the tmpfs label is unreadable by app domains on some builds;
5. falls back to a plain `/system` remount on pre-14 images.

The overlay is **not persistent**. Re-run after every emulator reboot, then force-stop and reopen the app.
`pm clear` wipes an app's data but leaves the CA and proxy intact, which makes it handy for clean per-account captures.

### 4. Block QUIC / HTTP-3
Modern HTTP stacks and Chromium WebViews prefer HTTP/3 over **UDP 443**, which a TCP proxy never sees. The classic symptom:
you capture only analytics/ad SDK traffic, none of the app's own hosts, and WebViews render blank.
`scripts/block_quic.sh` inserts `REJECT` rules for UDP 443 with `iptables` and `ip6tables`, so clients fall back to
HTTP/2 over TCP. Also not persistent; reapply after reboot, then relaunch the app.

### 5. Capture WebSocket frames in real time
`mitmdump -w` serializes a WebSocket flow only when the socket **closes**, and the console shows just the handshake.
`addons/ws_realtime_addon.py` hooks `websocket_message` and appends each frame as a JSON line, flushed immediately:

```bash
tail -f captures/*/ws_realtime.jsonl | jq -c '{direction, host, payload}'
```
Many chat and live-update backends authenticate the socket with a first frame (a login message), then return a session key
used by their REST endpoints. Reading both channels together shows how the two relate.

### 6. Find the auth material
- Read the `Authorization` header (or custom header/cookie) in decrypted requests.
- Tokens are often a short-lived access token plus a refresh token; note the lifetime so your replay handles expiry.
- Cross-platform frameworks usually store state in plain app storage on a rooted device
  (for example a SQLite database under `/data/data/$PACKAGE/databases/`). Native apps often use encrypted preferences,
  so capture from live traffic instead of reading disk.
- Find the minimal header set by replaying and removing headers one at a time.

### 7. Replay with pure HTTP
```bash
python3 examples/replay_request.py --param page=1
```
The example reads `API_BASE`, `API_PATH`, `AUTH_TOKEN` and `USER_AGENT` from `.env`, sends the call with `requests`, and
reports an expired token clearly. Once a call works here, it can be wrapped in a client library or test harness without
an emulator.

### 8. Exports and analysis
mitmproxy has built-in tooling; no extra addon is needed:
```bash
mitmproxy -nr captures/<ts>/flows.mitm                                   # browse
mitmdump -nr captures/<ts>/flows.mitm --set hardump=captures/out.har     # export HAR (mitmproxy 10+)
mitmdump -nr captures/<ts>/flows.mitm "~d api.example.com" -s my_filter.py
```
Filter to first-party hosts early; analytics and ad traffic is most of the volume.

### Certificate pinning
If a host fails with "client does not trust the proxy's certificate" even after the system CA is installed, the app
pins that host. Only for apps you own or are authorized to test, see the official documentation for
[Frida](https://frida.re/docs/android/) and [objection](https://github.com/sensepost/objection/wiki/Features).
Platform-level hosts (Google services) pin by design; ignore them.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Only ad/analytics hosts captured, WebViews blank | HTTP/3 (QUIC) bypasses the proxy | `scripts/block_quic.sh`, relaunch the app |
| `adb root` says "cannot run as root" | Play Store (`user`) image | Recreate on `google_apis` |
| TLS errors for every host | CA not trusted, or injected into `/system` on Android 14+ | Re-run `inject_ca.sh`; check `ls /apex/com.android.conscrypt/cacerts/<hash>.0` |
| Worked yesterday, now TLS errors | Emulator rebooted; tmpfs overlay lost | Re-run `inject_ca.sh` and `block_quic.sh` |
| Error for one first-party host only | Certificate pinning | See the pinning section |
| WebSocket frames missing from `.mitm` | Flow is written only on socket close | Use `ws_realtime_addon.py` or force-stop the app |
| `unauthorized` in `adb devices` | adb key mismatch after copying an AVD | Copy `~/.android/adbkey*` as well, or re-authorize |
| No traffic at all | Proxy unset, wrong port, firewall | `adb shell settings get global http_proxy`; open `MITM_PORT` on the host |
| 401 on replay | Token expired or rotated | Capture a fresh token; implement refresh |
| Whole adb server hangs | An `offline` wireless device entry | `pkill -9 -f 'adb.*fork-server'; adb start-server; adb disconnect` |
| App refuses to run on emulator | Device-integrity checks | Out of scope; test on a build that permits it |

## Responsible use

Use this toolkit only on apps you own, or where you have explicit written authorization to test. Respect the
applicable terms of service, privacy law and rate limits, and do not collect personal data you are not entitled to.
This project does not include, and will not accept, techniques for defeating device-integrity attestation or
anti-abuse systems. Captured traffic may contain credentials: keep `captures/` and `.env` out of version control
(both are in `.gitignore`).

## License

MIT, see [LICENSE](LICENSE).
