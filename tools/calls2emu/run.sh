#!/usr/bin/env bash
# calls-2emu — TWO emulators on ONE runner, two app instances calling each other.
#   emulator-5554 = A: the flow driver (flutter drive, flows 18w_*)
#   emulator-5556 = B: the call peer (integration_test/call_peer_app.dart)
# Both: API 33 x86_64, 2 GB RAM, 2 cores, swiftshader (no GPU on hosted
# runners), emulated front + back camera, backend at 10.0.2.2:8700, control
# channel (tools/calls2emu/control.py) at 10.0.2.2:8710.
#
# Retries ONLY for emulator boot (a hosted emulator sometimes never finishes
# booting); the flows themselves run once — an assertion is never retried.
# The step never fails itself: the verdict comes from the flow results
# (summarize.py + relgate verdict.py) so the evidence always uploads.
#
# Needs: REALITY_OUT, A_APK, B_APK, ANDROID_HOME. Optional: C2E_IDS.
set -u
OUT="${REALITY_OUT:?}"
C2E="$OUT/calls2emu"
PKG=com.assisto.assisto
DEV=/sdcard/Android/data/$PKG/files/reality
IMG="system-images;android-33;default;x86_64"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
export PATH="$SDK/cmdline-tools/latest/bin:$SDK/emulator:$SDK/platform-tools:$PATH"
mkdir -p "$OUT/shots" "$OUT/device" "$C2E"
SA=emulator-5554 SB=emulator-5556

log() { echo "== $* ($(date +%T))" | tee -a "$C2E/run.log"; }
on() { local s=$1; shift; timeout "${T:-60}" adb -s "$s" "$@"; }
alive() { [ "$(T=10 on "$1" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; }

log "SDK packages"
yes | timeout 300 sdkmanager --licenses >/dev/null 2>&1 || true
timeout 900 sdkmanager --install emulator platform-tools "$IMG" > "$C2E/sdkmanager.log" 2>&1 \
  || { log "sdkmanager failed"; tail -20 "$C2E/sdkmanager.log"; }

# calls-quality: RAM per emulator (MB) — 2 GB A vs 4 GB B proves the 480p
# (≤ 3 GB phone) and 720p camera paths side by side. Default 2 GB both.
RAM_A="${C2E_RAM_A:-2048}" RAM_B="${C2E_RAM_B:-2048}"
ram_of() { [ "$1" = c2eB ] && echo "$RAM_B" || echo "$RAM_A"; }

make_avd() {  # $1 = name
  # avdmanager first; when it makes nothing (run 44165707378: the runner's old
  # cmdline-tools vs SDK XML v4) the AVD is written by hand (same keys).
  export ANDROID_AVD_HOME="$HOME/.android/avd"
  mkdir -p "$ANDROID_AVD_HOME"
  echo no | timeout 120 avdmanager create avd -n "$1" -k "$IMG" -d pixel_5 --force \
    >> "$C2E/avdmanager.log" 2>&1 || true
  local c="$ANDROID_AVD_HOME/$1.avd/config.ini"
  if [ ! -f "$c" ]; then
    log "avdmanager made no AVD $1 (calls2emu/avdmanager.log) - writing it by hand"
    mkdir -p "$ANDROID_AVD_HOME/$1.avd"
    printf 'avd.ini.encoding=UTF-8\npath=%s\npath.rel=avd/%s.avd\ntarget=android-33\n' \
      "$ANDROID_AVD_HOME/$1.avd" "$1" > "$ANDROID_AVD_HOME/$1.ini"
    printf '%s\n' "AvdId=$1" "avd.ini.displayname=$1" "abi.type=x86_64" "hw.cpu.arch=x86_64" \
      "image.sysdir.1=system-images/android-33/default/x86_64/" "tag.id=default" \
      "tag.display=Default Android System Image" "PlayStore.enabled=false" \
      "hw.lcd.width=1080" "hw.lcd.height=2340" "hw.lcd.density=440" "hw.mainKeys=no" \
      "hw.accelerometer=yes" "hw.sdCard=no" > "$c"
  fi
  [ -f "$SDK/system-images/android-33/default/x86_64/system.img" ] \
    || { log "system image missing under $SDK"; return 1; }
  sed -i -E '/^(hw\.ramSize|hw\.keyboard|hw\.camera\.front|hw\.camera\.back|disk\.dataPartition\.size|hw\.gpu\.enabled|hw\.gpu\.mode|hw\.cpu\.ncore|vm\.heapSize)=/d' "$c"
  cat >> "$c" <<EOF
hw.ramSize=$(ram_of "$1")
hw.keyboard=yes
hw.camera.front=emulated
hw.camera.back=emulated
disk.dataPartition.size=6G
hw.gpu.enabled=yes
hw.gpu.mode=swiftshader_indirect
hw.cpu.ncore=2
vm.heapSize=384
EOF
}

# calls-quality (lead 18 Nov: b330 gate 18w_b/18w_d went C — the 4-vCPU host
# was overloaded, A's bandwidth estimate fell to 118 kbit/s): each emulator
# gets its OWN two vCPUs (A 0-1, B 2-3) so neither starves the other's
# software VP8 encoder; host tools (flutter drive, Django, coturn) float.
pin_of() {  # $1 = avd
  [ "$(nproc)" -ge 4 ] || { echo ""; return; }
  [ "$1" = c2eB ] && echo "taskset -c 2,3" || echo "taskset -c 0,1"
}

start_emu() {  # $1 = avd, $2 = port, $3 = extra opts
  nohup $(pin_of "$1") emulator -avd "$1" -port "$2" -no-snapshot -no-window -no-audio -no-boot-anim \
    -gpu swiftshader_indirect -memory "$(ram_of "$1")" -cores 2 \
    -camera-front emulated -camera-back emulated $3 \
    > "$C2E/emulator_$1.log" 2>&1 &
  echo $! > "$C2E/emu_$1.pid"
}

kill_emu() {  # $1 = avd, $2 = serial
  timeout 20 adb -s "$2" emu kill >/dev/null 2>&1 || true
  sleep 3
  kill -9 "$(cat "$C2E/emu_$1.pid" 2>/dev/null)" 2>/dev/null || true
}

wait_boot() {  # $1 = serial, $2 = seconds
  local end=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    alive "$1" && return 0
    sleep 5
  done
  return 1
}

boot_both() {
  local attempt extra=""
  for attempt in 1 2 3; do
    log "boot attempt $attempt (both emulators)"
    for p in "c2eA 5554 $SA" "c2eB 5556 $SB"; do
      set -- $p
      alive "$3" || start_emu "$1" "$2" "$extra"
    done
    timeout 60 adb start-server >/dev/null 2>&1 || true
    local okA=0 okB=0
    wait_boot $SA 480 && okA=1
    wait_boot $SB 120 && okB=1
    if [ $okA = 1 ] && [ $okB = 1 ]; then log "both emulators booted"; return 0; fi
    log "boot attempt $attempt: A=$okA B=$okB — restarting the one(s) that did not boot (wiped)"
    [ $okA = 1 ] || kill_emu c2eA $SA
    [ $okB = 1 ] || kill_emu c2eB $SB
    free -m >> "$C2E/run.log"
    extra="-wipe-data"
  done
  return 1
}

prep() {  # $1 = serial
  local s=$1 ime
  for ime in $(T=10 on "$s" shell ime list -s 2>/dev/null | tr -d '\r'); do
    T=10 on "$s" shell ime disable "$ime" >/dev/null 2>&1 || true
  done
  T=10 on "$s" shell pm disable-user --user 0 com.android.inputmethod.latin >/dev/null 2>&1 || true
  for k in window_animation_scale transition_animation_scale animator_duration_scale; do
    T=10 on "$s" shell settings put global $k 0 >/dev/null 2>&1 || true
  done
  T=10 on "$s" shell svc power stayon true >/dev/null 2>&1 || true
  T=10 on "$s" shell input keyevent 82 >/dev/null 2>&1 || true
}

grant() {  # $1 = serial — runtime permissions once the app is installed
  for _ in $(seq 1 150); do
    if timeout 10 adb -s "$1" shell pm list packages 2>/dev/null | grep -q "$PKG"; then
      for p in POST_NOTIFICATIONS RECORD_AUDIO CAMERA ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION READ_MEDIA_IMAGES READ_MEDIA_VIDEO READ_CONTACTS; do
        timeout 10 adb -s "$1" shell pm grant $PKG android.permission.$p >/dev/null 2>&1 || true
      done
      return 0
    fi
    sleep 2
  done
}

finish() {
  log "pull evidence"
  if alive $SA; then
    T=180 on $SA pull "$DEV" "$OUT/device/" >/dev/null 2>&1 || true
  fi
  pkill -f "adb -s $SA logcat" 2>/dev/null || true
  pkill -f "adb -s $SB logcat" 2>/dev/null || true
  pkill -f "tail -n +1 -F $OUT/live_logcat.txt" 2>/dev/null || true
  jobs -p | xargs -r kill 2>/dev/null || true
  cp "$OUT/live_logcat.txt" "$OUT/logcat.txt" 2>/dev/null || true
  grep -E "FATAL|AndroidRuntime|ANR in" "$C2E/logcat_B.txt" 2>/dev/null | tail -20 > "$C2E/peer_crashes.txt" || true
  kill_emu c2eA $SA; kill_emu c2eB $SB
  pkill -9 -f qemu-system 2>/dev/null || true
  pkill -9 -f netsimd 2>/dev/null || true
  exit 0
}

make_avd c2eA && make_avd c2eB || { log "AVD creation failed"; finish; }
if ! boot_both; then
  log "EMULATOR BOOT FAILED after 3 attempts — no case ran (infrastructure, not a call bug)"
  echo "C2E_BOOT_FAILED" > "$C2E/boot_failed"
  finish
fi
prep $SA; prep $SB
T=10 on $SA logcat -c >/dev/null 2>&1 || true
T=10 on $SB logcat -c >/dev/null 2>&1 || true
: > "$OUT/live_logcat.txt"
( timeout 3600 adb -s $SA logcat -v time >> "$OUT/live_logcat.txt" 2>&1 ) &
( timeout 3600 adb -s $SB logcat -v time >> "$C2E/logcat_B.txt" 2>&1 ) &

# Host-side screenshots of A (harness: REALITY_SHOT <file> -> screencap + ack)
( timeout 3600 tail -n +1 -F "$OUT/live_logcat.txt" 2>/dev/null \
    | grep --line-buffered -oE 'REALITY_SHOT [A-Za-z0-9_.-]+\.png' \
    | while read -r _ f; do
        timeout 20 adb -s $SA exec-out screencap -p > "$OUT/shots/$f" 2>/dev/null || true
        timeout 20 adb -s $SB exec-out screencap -p > "$OUT/shots/B_$f" 2>/dev/null || true
        [ -s "$OUT/shots/$f" ] || rm -f "$OUT/shots/$f"
        [ -s "$OUT/shots/B_$f" ] || rm -f "$OUT/shots/B_$f"
        timeout 10 adb -s $SA shell "mkdir -p $DEV/acks && touch $DEV/acks/$f" >/dev/null 2>&1 || true
      done ) &

log "install + start peer B on $SB"
T=300 on $SB install -r -g "$B_APK" > "$C2E/install_B.log" 2>&1 || { log "peer install failed"; cat "$C2E/install_B.log"; }
grant $SB
T=30 on $SB shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
end=$(( $(date +%s) + 240 ))
until curl -fsS -m 5 http://127.0.0.1:8710/state 2>/dev/null | grep -q '"side": "B"'; do
  if [ "$(date +%s)" -gt "$end" ]; then
    log "PEER B NEVER SIGNED IN (4 min) — see calls2emu/peer_B.log + logcat_B.txt"
    break
  fi
  sleep 5
done
curl -fsS -m 5 http://127.0.0.1:8710/state >> "$C2E/run.log" 2>&1; echo >> "$C2E/run.log"

log "flutter drive A on $SA"
grant $SA &
cd app
log "RAM A=${RAM_A} MB B=${RAM_B} MB; CPU pinning A='$(pin_of c2eA)' B='$(pin_of c2eB)'"
IDS="${C2E_IDS:-01_language,02_login,03_onboarding,18w_a,18w_b,18w_c,18w_d}"
ANDROID_SERIAL=$SA REALITY_OUT="$OUT" timeout "${C2E_DRIVE_SECONDS:-2400}" flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/reality_all_test.dart \
  -d $SA \
  --use-application-binary "$A_APK" \
  --dart-define=REALITY_API_BASE=http://10.0.2.2:8700 \
  --dart-define=REALITY_ONLY=start,calls2emu \
  --dart-define=REALITY_FLOW_IDS="$IDS" \
  --keep-app-running \
  > "$OUT/drive.log" 2>&1
log "drive exit=$? (A alive: $(alive $SA && echo yes || echo NO), B alive: $(alive $SB && echo yes || echo NO))"
cd ..
tail -30 "$OUT/drive.log"
finish
