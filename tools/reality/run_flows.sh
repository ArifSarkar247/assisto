#!/usr/bin/env bash
# Reality audit — runs INSIDE the android-emulator-runner (emulator already
# booted, Django already serving on the runner at :8700 = 10.0.2.2:8700 from
# the emulator). Every adb call is wrapped in `timeout` (a hung `adb logcat -d`
# once held a run for 6h). Never fails the step itself: the verdict comes from
# results.json (tools/reality/summarize.py), so the evidence always uploads.
set -u
OUT="${REALITY_OUT:-$PWD/reality_out}"
PKG=com.assisto.assisto
mkdir -p "$OUT/shots" "$OUT/device"
cd app

A() { timeout "${T:-60}" adb "$@"; }

echo "== device"; A shell getprop ro.build.version.sdk || true
A shell settings put global window_animation_scale 0 || true
A shell settings put global transition_animation_scale 0 || true
A shell settings put global animator_duration_scale 0 || true
A logcat -c || true

# LIVE logcat for the whole run (a post-run `logcat -d` hung and captured
# nothing on 21 Oct, when the app died seconds into flow 01).
( timeout 3600 adb logcat -v time > "$OUT/live_logcat.txt" 2>&1 ) &

# Host-side screenshots. The app prints `REALITY_SHOT <file>` (harness.dart
# shot()); we grab the real screen with screencap and touch an ack file in the
# app's external dir so the flow continues at once (the app gives up after 6 s
# if the ack never lands, so a broken ack path only slows the run down).
# 22 Oct root cause of "NO RESULTS": the old in-app RenderRepaintBoundary.toImage
# (GPU read-back, Impeller/GLES on swiftshader) killed the whole emulator at the
# first screenshot of flow 01, on every run, AOSP and google_apis images alike.
DEV=/sdcard/Android/data/$PKG/files/reality
( timeout 3600 tail -n +1 -F "$OUT/live_logcat.txt" 2>/dev/null \
    | grep --line-buffered -oE 'REALITY_SHOT [A-Za-z0-9_.-]+\.png' \
    | while read -r _ f; do
        timeout 20 adb exec-out screencap -p > "$OUT/shots/$f" 2>/dev/null || true
        [ -s "$OUT/shots/$f" ] || rm -f "$OUT/shots/$f"
        timeout 10 adb shell "mkdir -p $DEV/acks && touch $DEV/acks/$f" >/dev/null 2>&1 || true
        echo "$(date +%T) $f $( [ -s "$OUT/shots/$f" ] && echo ok || echo MISSING)" >> "$OUT/shots.log"
      done ) &

# Background screen recording (OFF by default: on the 2-core software-GPU
# emulator it competes with the app; every flow step already takes a
# screenshot). REALITY_RECORD=1 turns it back on.
if [ "${REALITY_RECORD:-0}" = "1" ]; then
  ( i=0; while [ -f "$OUT/.recording" ]; do
      i=$((i+1)); timeout 185 adb shell screenrecord --time-limit 170 --bit-rate 2000000 "/sdcard/reality_$i.mp4" >/dev/null 2>&1 || true
    done ) &
  touch "$OUT/.recording"
fi

# Pre-grant runtime permissions so no system dialog blocks a flow (the app is
# installed by flutter drive; grant again right after install via a poller).
( for _ in $(seq 1 120); do
    if timeout 10 adb shell pm list packages 2>/dev/null | grep -q "$PKG"; then
      for p in POST_NOTIFICATIONS RECORD_AUDIO CAMERA ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION READ_MEDIA_IMAGES READ_MEDIA_VIDEO READ_CONTACTS; do
        timeout 10 adb shell pm grant $PKG android.permission.$p >/dev/null 2>&1 || true
      done
      break
    fi; sleep 2; done ) &

# Let the freshly booted emulator finish its BOOT_COMPLETED broadcast storm first
# (21 Oct: the app died seconds into flow 01 while Maps/Calendar/NFC were still
# starting, and adb wedged; the APK smoke saw the same).
echo "== settle 60 s after boot"; sleep 60
echo "== flutter drive (all flows)"
REALITY_OUT="$OUT" timeout "${REALITY_DRIVE_TIMEOUT:-3300}" flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/reality_all_test.dart \
  -d emulator-5554 \
  --dart-define=REALITY_API_BASE=http://10.0.2.2:8700 \
  --dart-define=REALITY_ONLY="${REALITY_ONLY:-}" \
  --keep-app-running \
  > "$OUT/drive.log" 2>&1
echo "drive exit=$?" | tee -a "$OUT/drive.log"
tail -60 "$OUT/drive.log" || true

rm -f "$OUT/.recording"
sleep 3
T=30 A shell pkill -INT screenrecord || true
sleep 3

echo "== pull evidence"
T=180 A pull "$DEV" "$OUT/device/" >/dev/null 2>&1 \
  || { echo "external pull failed; trying run-as"; T=180 A exec-out run-as $PKG sh -c 'cd files 2>/dev/null && tar c reality' 2>/dev/null | tar x -C "$OUT/device" 2>/dev/null || true; }
for f in $(T=20 A shell ls /sdcard/ 2>/dev/null | tr -d '\r' | grep '^reality_.*\.mp4$'); do
  T=120 A pull "/sdcard/$f" "$OUT/" >/dev/null 2>&1 || true
done
T=120 A logcat -d -t 20000 > "$OUT/logcat.txt" 2>/dev/null || echo "logcat timed out" >> "$OUT/drive.log"
[ -s "$OUT/logcat.txt" ] || cp "$OUT/live_logcat.txt" "$OUT/logcat.txt" 2>/dev/null || true
grep -E "FATAL|AndroidRuntime|has died|Killing .*assisto|ANR in|ASSISTO_PREFS_FAIL|signal [0-9]+ \\(SIG" "$OUT/live_logcat.txt" 2>/dev/null | tail -40 || true
find "$OUT" -maxdepth 3 -type f | head -50
exit 0
