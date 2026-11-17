#!/usr/bin/env bash
# relgate: the EXACT release APK (android.yml artifact assisto-apk-emu, same
# commit) - 3 cold starts, each must show MainActivity and stay alive 25 s,
# then no crash / ANR / tombstone for the app in logcat or dropbox.
# Runs inside android-emulator-runner (`script: bash .../cold_start.sh`).
set -u
API="${GATE_API:-?}"; PKG=com.assisto.assisto; ACT="$PKG/com.assisto.assisto.MainActivity"
OUT="${GATE_OUT:-smoke_out}"; mkdir -p "$OUT"
fail() { echo "::error::API $API: $*"; echo "FAIL $*" >> "$OUT/result.txt"; finish 1; }
finish() {
  cp /tmp/relgate_logcat.txt "$OUT/logcat.txt" 2>/dev/null || true
  pkill -f "adb logcat -v time" 2>/dev/null || true
  exit "$1"
}
APK=$(ls apk/*.apk | head -1)
echo "apk: $APK sha256 $(sha256sum "$APK" | cut -c1-16)" | tee "$OUT/result.txt"
sleep 30
timeout 300 adb install -r "$APK" > "$OUT/install.txt" 2>&1 || fail "install failed: $(tail -2 "$OUT/install.txt" | tr '\n' ' ')"
timeout 30 adb shell dumpsys package "$PKG" | grep -m2 -E "versionCode|versionName" | tee -a "$OUT/result.txt"
timeout 20 adb shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS 2>/dev/null || true
timeout 30 adb logcat -c || true
nohup sh -c 'adb logcat -v time > /tmp/relgate_logcat.txt 2>&1' >/dev/null 2>&1 &
for i in 1 2 3; do
  timeout 20 adb shell am force-stop "$PKG" || true
  sleep 3
  r=$(timeout 120 adb shell am start -W -n "$ACT" 2>&1) || true
  echo "$r" > "$OUT/am_start_$i.txt"
  echo "$r" | grep -q "Status: ok" || fail "cold start $i: am start did not complete ($(echo "$r" | tr '\n' ' ' | cut -c1-200))"
  tt=$(echo "$r" | sed -n 's/^TotalTime: *//p' | tr -d '\r')
  sleep 25
  timeout 15 adb exec-out screencap -p > "$OUT/cold_${i}.png" 2>/dev/null || true
  timeout 10 adb shell echo alive | grep -q alive || fail "cold start $i: emulator stopped answering"
  pid=$(timeout 20 adb shell pidof "$PKG" | tr -d '\r')
  [ -n "$pid" ] || fail "cold start $i: app NOT running 25 s after launch"
  echo "cold start $i OK: TotalTime=${tt:-?} ms pid=$pid" | tee -a "$OUT/result.txt"
done
sleep 2
cp /tmp/relgate_logcat.txt "$OUT/logcat.txt" 2>/dev/null || true
grep -E "FATAL EXCEPTION|ANR in $PKG|$PKG.*has died|FATAL SIGNAL|AndroidRuntime.*$PKG|E/flutter.*(Unhandled|Fatal)|Fatal signal [0-9]+ .*$PKG" \
  "$OUT/logcat.txt" > "$OUT/crashes.txt" 2>/dev/null || true
timeout 60 adb shell dumpsys dropbox --print 2>/dev/null \
  | grep -E -A3 "data_app_(crash|anr|native_crash)" | grep -B1 -A2 "Process: $PKG" >> "$OUT/crashes.txt" || true
if [ -s "$OUT/crashes.txt" ]; then head -30 "$OUT/crashes.txt"; fail "crash/ANR during the 3 cold starts"; fi
grep -q "ASSISTO_PREFS_FAIL" "$OUT/logcat.txt" && fail "settings store (SharedPreferences) failed"
echo "PASS 3/3 cold starts, no crash/ANR" | tee -a "$OUT/result.txt"
finish 0
