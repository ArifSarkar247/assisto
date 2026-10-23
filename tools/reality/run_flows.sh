#!/usr/bin/env bash
# Reality audit — runs INSIDE the android-emulator-runner (emulator already
# booted, Django already serving on the runner at :8700 = 10.0.2.2:8700 from
# the emulator). Every adb call is wrapped in `timeout` (a hung `adb logcat -d`
# once held a run for 6h). Never fails the step itself: the verdict comes from
# the per-flow results (tools/reality/summarize.py), so the evidence always uploads.
#
# 22 Oct (qa1) root causes of "NO RESULTS":
#  1. the in-app screenshot (RenderRepaintBoundary.toImage = GPU read-back under
#     Impeller/GLES) killed the whole swiftshader emulator at the first shot of
#     flow 01, on every run -> screenshots are now host-side `adb screencap`
#     (see harness.dart shot() and the watcher below);
#  2. the hosted emulator still dies after a few minutes of UI work (run
#     39849437970: 10 flows ran, then the emulator process exited during flow
#     11) -> flows run in GROUPS, one `flutter drive` per group, and a dead
#     emulator is restarted before the next group, so one crash costs one group
#     instead of every flow after it. App data survives (same AVD, no wipe):
#     later groups stay logged in.
set -u
OUT="${REALITY_OUT:-$PWD/reality_out}"
PKG=com.assisto.assisto
DEV=/sdcard/Android/data/$PKG/files/reality
EMU_OPTS="-no-snapshot -no-window -gpu swiftshader_indirect -noaudio -no-boot-anim"
mkdir -p "$OUT/shots" "$OUT/device"
cd app

A() { timeout "${T:-60}" adb "$@"; }
alive() { [ "$(T=10 A shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; }

prep_device() {
  A shell settings put global window_animation_scale 0 || true
  A shell settings put global transition_animation_scale 0 || true
  A shell settings put global animator_duration_scale 0 || true
  # live logcat (APPENDS across emulator restarts; the shot watcher and
  # summarize.py read it)
  ( timeout 3000 adb logcat -v time >> "$OUT/live_logcat.txt" 2>&1 ) &
  # pre-grant runtime permissions once the app is installed
  ( for _ in $(seq 1 120); do
      if timeout 10 adb shell pm list packages 2>/dev/null | grep -q "$PKG"; then
        for p in POST_NOTIFICATIONS RECORD_AUDIO CAMERA ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION READ_MEDIA_IMAGES READ_MEDIA_VIDEO READ_CONTACTS; do
          timeout 10 adb shell pm grant $PKG android.permission.$p >/dev/null 2>&1 || true
        done
        break
      fi; sleep 2; done ) &
}

restart_emulator() {
  echo "== emulator is gone — restarting it ($(date +%T))" | tee -a "$OUT/drive.log"
  timeout 20 adb -s emulator-5554 emu kill >/dev/null 2>&1 || true
  pkill -f "qemu-system" 2>/dev/null || true
  sleep 3
  nohup "$ANDROID_HOME/emulator/emulator" -port 5554 -avd test $EMU_OPTS \
    > "$OUT/emulator_restart.log" 2>&1 &
  timeout 60 adb wait-for-device || true
  for _ in $(seq 1 90); do alive && break; sleep 5; done
  alive || { echo "restart failed" | tee -a "$OUT/drive.log"; return 1; }
  sleep 30   # let the boot broadcast storm settle
  prep_device
  return 0
}

echo "== device"; A shell getprop ro.build.version.sdk || true
A logcat -c || true
: > "$OUT/live_logcat.txt"
prep_device

# Host-side screenshots: the app prints `REALITY_SHOT <file>`; grab the real
# screen and touch an ack in the app's external dir so the flow continues at
# once (the app gives up after 6 s if the ack never lands).
( timeout 3000 tail -n +1 -F "$OUT/live_logcat.txt" 2>/dev/null \
    | grep --line-buffered -oE 'REALITY_SHOT [A-Za-z0-9_.-]+\.png' \
    | while read -r _ f; do
        timeout 20 adb exec-out screencap -p > "$OUT/shots/$f" 2>/dev/null || true
        [ -s "$OUT/shots/$f" ] || rm -f "$OUT/shots/$f"
        timeout 10 adb shell "mkdir -p $DEV/acks && touch $DEV/acks/$f" >/dev/null 2>&1 || true
        echo "$(date +%T) $f $( [ -s "$OUT/shots/$f" ] && echo ok || echo MISSING)" >> "$OUT/shots.log"
      done ) &

echo "== settle 60 s after boot"; sleep 60
GROUPS_ALL="start home personal family business docs sweep"
GROUPS_RUN="${REALITY_ONLY:-$GROUPS_ALL}"
GROUPS_RUN="${GROUPS_RUN//,/ }"
DEADLINE=$(( $(date +%s) + ${REALITY_TOTAL_SECONDS:-4200} ))
run_group() {  # $1 = group, $2 = attempt label
  local g=$1 left
  left=$(( DEADLINE - $(date +%s) ))
  [ "$left" -gt 120 ] || { echo "== out of time before group $g" | tee -a "$OUT/drive.log"; return 2; }
  if ! alive; then restart_emulator || return 2; fi
  echo "== flutter drive group=$g$2 ($(date +%T), ${left}s left)" | tee -a "$OUT/drive.log"
  REALITY_OUT="$OUT" timeout "$(( left < 1500 ? left : 1500 ))" flutter drive \
    --driver=test_driver/integration_test.dart \
    --target=integration_test/reality_all_test.dart \
    -d emulator-5554 \
    --dart-define=REALITY_API_BASE=http://10.0.2.2:8700 \
    --dart-define=REALITY_ONLY="$g" \
    --keep-app-running \
    >> "$OUT/drive.log" 2>&1
  local rc=$?
  echo "group $g$2 drive exit=$rc" | tee -a "$OUT/drive.log"
  return $rc
}

for g in $GROUPS_RUN; do
  run_group "$g" ""
  rc=$?
  [ "$rc" -eq 2 ] && break
  # rt1: the hosted emulator sometimes dies mid-group (run 39859999833: the
  # business group, "Service has disappeared"). That is the device, not the
  # app — restart it and give the group ONE more run (verdicts of the retry
  # replace the first attempt's per flow id in summarize.py).
  if [ "$rc" -ne 0 ] && ! alive; then
    echo "== emulator died during group $g — one retry" | tee -a "$OUT/drive.log"
    run_group "$g" " (retry)"
    [ $? -eq 2 ] && break
  fi
done
tail -40 "$OUT/drive.log" || true

echo "== pull evidence"
if alive; then
  T=180 A pull "$DEV" "$OUT/device/" >/dev/null 2>&1 || true
  T=60 A logcat -d -t 20000 > "$OUT/logcat.txt" 2>/dev/null || true
fi
[ -s "$OUT/logcat.txt" ] || cp "$OUT/live_logcat.txt" "$OUT/logcat.txt" 2>/dev/null || true
grep -E "FATAL|AndroidRuntime|has died|ANR in|signal [0-9]+ \\(SIG" "$OUT/live_logcat.txt" 2>/dev/null | tail -40 || true
grep -c "REALITY_RESULT" "$OUT/live_logcat.txt" 2>/dev/null || true
# The step must END: background logcat/tail/watchers would otherwise hold it
# open until their own timeouts (run 39849437970 idled 50 min here).
pkill -f "tail -n +1 -F $OUT/live_logcat.txt" 2>/dev/null || true
pkill -f "adb logcat -v time" 2>/dev/null || true
jobs -p | xargs -r kill 2>/dev/null || true
exit 0
