#!/usr/bin/env bash
# perf2gb — runs INSIDE reactivecircus/android-emulator-runner (emulator up,
# CI Django on 10.0.2.2:8700). Every adb call is time-boxed. Never fails the
# step: tools/perf2gb/collect.py turns the evidence into perf2gb.json/.md.
#
#  1. device facts (RAM, cores, heap limits, screen) -> device.txt
#  2. the real app (profile APK, ASSISTO_PERF marks): fresh-install cold
#     starts (language picker) x3
#  3. the perf test APK (same package, `install -r` keeps data): the Start
#     flows log in, then every perf flow; PERF_MEM handshakes -> dumpsys
#     meminfo; RSS sampler; app-death watcher (+1 resume attempt)
#  4. the real app again over the signed-in data: cold starts to home x5,
#     idle-home meminfo
#  5. 5 min in the background: batterystats (CPU, wakelocks, alarms)
#  6. exit-info (LMK?), logcat, perf.json
set -u
OUT="${PERF_OUT:-$PWD/perf_out}"
PKG=com.assisto.assisto
DEV=/sdcard/Android/data/$PKG/files/reality
APP_APK="${PERF_APP_APK:?}"
TEST_APK="${PERF_TEST_APK:?}"
TOTAL="${PERF_TOTAL_SECONDS:-2700}"
mkdir -p "$OUT/mem" "$OUT/cold" "$OUT/device"
LOG="$OUT/live_logcat.txt"

A() { timeout "${T:-60}" adb "$@"; }
alive() { [ "$(T=10 A shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; }
say() { echo "== $(date +%T) $*" | tee -a "$OUT/run.log"; }
app_pid() { T=10 A shell pidof "$PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}'; }

grant() {
  for p in POST_NOTIFICATIONS RECORD_AUDIO CAMERA ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION READ_MEDIA_IMAGES READ_MEDIA_VIDEO READ_CONTACTS; do
    T=10 A shell pm grant $PKG android.permission.$p >/dev/null 2>&1 || true
  done
}

install_apk() {  # $1 = apk, keeps app data (-r); falls back to a clean install
  local r
  r=$(T=240 A install -r -t "$1" 2>&1 | tail -2)
  echo "install $(basename "$1"): $r" >> "$OUT/run.log"
  if ! echo "$r" | grep -q Success; then
    say "install -r failed ($r) — clean install (sign-in will be lost)"
    T=60 A uninstall "$PKG" >/dev/null 2>&1 || true
    T=240 A install -t "$1" >> "$OUT/run.log" 2>&1 || true
    echo "CLEAN_REINSTALL $(basename "$1")" >> "$OUT/run.log"
  fi
  grant
}

launcher() {
  T=20 A shell cmd package resolve-activity --brief "$PKG" 2>/dev/null | tr -d '\r' | tail -1
}

cold_starts() {  # $1 label, $2 count
  local cmp i
  cmp=$(launcher)
  for i in $(seq 1 "$2"); do
    T=20 A shell am force-stop "$PKG" >/dev/null 2>&1 || true
    sleep 4
    echo "COLD_BEGIN $1 $i $(date +%s%3N)" >> "$OUT/cold/markers.txt"
    T=60 A shell am start -W -n "$cmp" > "$OUT/cold/${1}_$i.txt" 2>&1 || true
    sleep 12   # first frame + home + deferred init marks land in logcat
    echo "COLD_END $1 $i $(date +%s%3N)" >> "$OUT/cold/markers.txt"
  done
}

meminfo() {  # $1 tag
  T=40 A shell dumpsys meminfo "$PKG" > "$OUT/mem/$1.txt" 2>&1 || true
}

# ------------------------------------------------------------ 1. device
say "device"
{
  for p in ro.build.version.sdk ro.product.model ro.config.low_ram dalvik.vm.heapgrowthlimit \
           dalvik.vm.heapsize dalvik.vm.heapstartsize ro.lmk.use_minfree_levels sys.use_memfd \
           debug.hwui.renderer ro.hardware.egl; do
    echo "$p=$(T=10 A shell getprop $p | tr -d '\r')"
  done
  echo "nproc=$(T=10 A shell nproc | tr -d '\r')"
  echo "wm_size=$(T=10 A shell wm size | tr -d '\r' | tail -1)"
  echo "wm_density=$(T=10 A shell wm density | tr -d '\r' | tail -1)"
  T=10 A shell cat /proc/meminfo | head -4
  echo "window_animation_scale=$(T=10 A shell settings get global window_animation_scale | tr -d '\r')"
} > "$OUT/device.txt" 2>&1
cat "$OUT/device.txt"

# no soft keyboard (run_flows.sh rf1: the IME window crashed the swiftshader
# emulator); animations stay ON like a real phone
for ime in $(T=10 A shell ime list -s 2>/dev/null | tr -d '\r'); do T=10 A shell ime disable "$ime" >/dev/null 2>&1 || true; done
T=10 A shell pm disable-user --user 0 com.android.inputmethod.latin >/dev/null 2>&1 || true
for s in window_animation_scale transition_animation_scale animator_duration_scale; do
  T=10 A shell settings put global $s 1 >/dev/null 2>&1 || true
done

A logcat -c || true
: > "$LOG"
( timeout $((TOTAL + 1500)) adb logcat -v epoch >> "$LOG" 2>&1 ) &

say "settle 45 s after boot"; sleep 45

# ------------------------------------------------------------ 2. fresh cold starts
install_apk "$APP_APK"
say "cold starts: fresh install (language picker)"
cold_starts fresh 3
meminfo cold_fresh_idle

# ------------------------------------------------------------ 3. perf flows
install_apk "$TEST_APK"
# PERF_MEM handshake: dumpsys meminfo, then the ack the app waits for
( timeout "$TOTAL" tail -n +1 -F "$LOG" 2>/dev/null \
    | grep --line-buffered -oE 'PERF_MEM [A-Za-z0-9_]+' \
    | while read -r _ tag; do
        meminfo "$tag"
        T=10 A shell "mkdir -p $DEV/acks && touch $DEV/acks/$tag.mem" >/dev/null 2>&1 || true
      done ) &
# screenshots requested by the Start flows (host-side, like run_flows.sh)
mkdir -p "$OUT/shots"
( timeout "$TOTAL" tail -n +1 -F "$LOG" 2>/dev/null \
    | grep --line-buffered -oE 'REALITY_SHOT [A-Za-z0-9_.-]+\.png' \
    | while read -r _ f; do
        T=20 A exec-out screencap -p > "$OUT/shots/$f" 2>/dev/null || true
        T=10 A shell "mkdir -p $DEV/acks && touch $DEV/acks/$f" >/dev/null 2>&1 || true
      done ) &
# RSS sampler (cheap /proc read every 3 s; dumpsys only at handshakes)
( end=$(( $(date +%s) + TOTAL )); while [ "$(date +%s)" -lt "$end" ]; do
    pid=$(app_pid)
    if [ -n "$pid" ]; then
      echo "$(date +%s%3N) $pid $(T=5 A shell "grep -E 'VmRSS|VmHWM' /proc/$pid/status" 2>/dev/null | tr -s ' \r\n' ' ')" >> "$OUT/rss_samples.txt"
    fi
    sleep 3
  done ) &
SAMPLER=$!

done_ids() { grep -oE 'PERF_RESULT [A-Za-z0-9_]+ [0-9]+/[0-9]+' "$LOG" | awk '{split($3,a,"/"); if (a[1]==a[2]) print $2}' | sort -u; }
deadline=$(( $(date +%s) + TOTAL - 600 ))
attempt=1
while :; do
  say "perf flows: launch attempt $attempt"
  T=20 A shell am force-stop "$PKG" >/dev/null 2>&1 || true
  T=20 A shell am start -n "$(launcher)" >/dev/null 2>&1 || true
  missing=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    grep -q "PERF_ALL_DONE" "$LOG" && break
    if [ -z "$(app_pid)" ]; then missing=$((missing + 1)); else missing=0; fi
    [ "$missing" -ge 4 ] && break
    sleep 5
  done
  grep -q "PERF_ALL_DONE" "$LOG" && { say "perf flows done"; break; }
  [ "$(date +%s)" -ge "$deadline" ] && { say "perf flows: out of time"; break; }
  alive || { say "emulator gone"; break; }
  # the app process died during a flow: record it (LMK or crash), resume once
  running=$(grep -oE 'REALITY_FLOW_START [A-Za-z0-9_]+' "$LOG" | tail -1 | awk '{print $2}')
  echo "APP_DIED attempt=$attempt during=${running:-?} at=$(date +%s%3N)" | tee -a "$OUT/deaths.txt"
  [ "$attempt" -ge 2 ] && break
  attempt=$((attempt + 1))
  { done_ids | grep -vE '^(0[123]_|p00_)'; [ -n "$running" ] && echo "$running"; } | sort -u > "$OUT/skip_ids.txt"
  T=10 A shell "mkdir -p $DEV" >/dev/null 2>&1
  T=10 A push "$OUT/skip_ids.txt" "$DEV/skip_ids.txt" >/dev/null 2>&1 || true
done
T=120 A pull "$DEV/perf.json" "$OUT/device/perf.json" >/dev/null 2>&1 || true
T=60 A pull "$DEV/results.json" "$OUT/device/results.json" >/dev/null 2>&1 || true
kill "$SAMPLER" 2>/dev/null || true
T=30 A shell dumpsys activity exit-info "$PKG" > "$OUT/exit_info_after_flows.txt" 2>&1 || true

# ------------------------------------------------------------ 4. signed-in cold starts
install_apk "$APP_APK"
say "cold starts: signed in (home)"
cold_starts home 5
sleep 5
meminfo cold_home_idle

# ------------------------------------------------------------ 5. background battery
say "background: 5 min, unplugged, screen off"
T=10 A shell dumpsys battery unplug >/dev/null 2>&1 || true
T=10 A shell dumpsys batterystats --reset >/dev/null 2>&1 || true
T=10 A shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
sleep 2
T=10 A shell input keyevent KEYCODE_SLEEP >/dev/null 2>&1 || true
sleep "${PERF_BG_SECONDS:-300}"
T=60 A shell dumpsys batterystats "$PKG" > "$OUT/batterystats.txt" 2>&1 || true
T=60 A shell dumpsys batterystats --checkin > "$OUT/batterystats_checkin.txt" 2>&1 || true
T=10 A shell dumpsys battery reset >/dev/null 2>&1 || true
T=10 A shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true

# ------------------------------------------------------------ 6. evidence
T=30 A shell dumpsys activity exit-info "$PKG" > "$OUT/exit_info.txt" 2>&1 || true
T=60 A logcat -d -b events -t 20000 > "$OUT/events_logcat.txt" 2>/dev/null || true
grep -E "FATAL|AndroidRuntime|has died|ANR in|lowmemorykiller|lmkd" "$LOG" | tail -60 > "$OUT/problems.txt" || true
say "done"
pkill -f "tail -n +1 -F $LOG" 2>/dev/null || true
pkill -f "adb logcat -v epoch" 2>/dev/null || true
jobs -p | xargs -r kill 2>/dev/null || true
timeout 20 adb emu kill >/dev/null 2>&1 || true
sleep 5
pkill -9 -f qemu-system 2>/dev/null || true
pkill -9 -f netsimd 2>/dev/null || true
exit 0
