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

# Background screen recording, in 170 s chunks (screenrecord's own cap is 180 s).
( i=0; while [ -f "$OUT/.recording" ]; do
    i=$((i+1)); timeout 185 adb shell screenrecord --time-limit 170 --bit-rate 2000000 "/sdcard/reality_$i.mp4" >/dev/null 2>&1 || true
  done ) &
touch "$OUT/.recording"

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
DEV=/sdcard/Android/data/$PKG/files/reality
T=180 A pull "$DEV" "$OUT/device/" >/dev/null 2>&1 \
  || { echo "external pull failed; trying run-as"; T=180 A exec-out run-as $PKG sh -c 'cd files 2>/dev/null && tar c reality' 2>/dev/null | tar x -C "$OUT/device" 2>/dev/null || true; }
for f in $(T=20 A shell ls /sdcard/ 2>/dev/null | tr -d '\r' | grep '^reality_.*\.mp4$'); do
  T=120 A pull "/sdcard/$f" "$OUT/" >/dev/null 2>&1 || true
done
T=120 A logcat -d -t 20000 > "$OUT/logcat.txt" 2>/dev/null || echo "logcat timed out" >> "$OUT/drive.log"
find "$OUT" -maxdepth 3 -type f | head -50
exit 0
