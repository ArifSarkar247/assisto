#!/usr/bin/env bash
# cctv-accuracy: runs INSIDE android-emulator-runner (cctv-grid.yml). Installs
# the PROFILE test APK, starts it with `am start` (like perf2gb: real AOT, no
# VM service), and while the grid runs samples every 30 s: dumpsys meminfo
# (PSS / RSS), the app's pid (a change or none = a crash / kill) and the
# device's free memory. Ends on GRID_E2E_DONE or after GRID_MAX_S.
set -uo pipefail
OUT="${E2E_DIR:-/tmp/assisto-grid-e2e}"
PKG=com.assisto.assisto
APK="${GRID_APK:?}"
MAX="${GRID_MAX_S:-1500}"
mkdir -p "$OUT"
A() { timeout "${T:-60}" adb "$@"; }
say() { echo "== $(date +%T) $*" | tee -a "$OUT/run.log"; }
A shell getprop ro.build.version.sdk > "$OUT/device.txt" 2>&1
A shell cat /proc/meminfo | head -3 >> "$OUT/device.txt" 2>&1
A shell wm size >> "$OUT/device.txt" 2>&1
cat "$OUT/device.txt"
T=300 A install -r -t "$APK" | tail -1 | tee -a "$OUT/run.log"
A logcat -c || true
(timeout $((MAX + 60)) adb logcat -v time > "$OUT/logcat.txt" 2>&1 &)
T=30 A shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
say "started"
first_pid=""
start=$(date +%s)
: > "$OUT/mem.tsv"
while :; do
  now=$(( $(date +%s) - start ))
  pid=$(T=10 A shell pidof "$PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}')
  [ -z "$first_pid" ] && [ -n "$pid" ] && first_pid="$pid" && say "pid $pid"
  if [ -n "$first_pid" ] && [ "$pid" != "$first_pid" ]; then
    say "APP_DIED pid was $first_pid now '${pid:-none}'"; echo "APP_DIED $now" >> "$OUT/run.log"
    [ -z "$pid" ] && break
    first_pid="$pid"
  fi
  if [ -n "$pid" ]; then
    m=$(T=20 A shell dumpsys meminfo "$PKG" 2>/dev/null | tr -d '\r')
    pss=$(echo "$m" | awk '/TOTAL PSS:/{print $3; exit} /^ *TOTAL /{print $2; exit}')
    rss=$(echo "$m" | awk '/TOTAL RSS:/{print $6; exit}')
    avail=$(T=10 A shell cat /proc/meminfo 2>/dev/null | awk '/MemAvailable/{print $2}')
    printf '%s\t%s\t%s\t%s\n' "$now" "${pss:-}" "${rss:-}" "${avail:-}" >> "$OUT/mem.tsv"
  fi
  # a screenshot every ~2.5 min (2x2, 3x3, scrolled, big) for the owner doc
  if [ -n "$pid" ] && [ $(( now / 30 % 5 )) -eq 4 ]; then
    timeout 20 adb exec-out screencap -p > "$OUT/shot_${now}s.png" 2>/dev/null || true
  fi
  grep -q "GRID_E2E_DONE" "$OUT/logcat.txt" 2>/dev/null && { say "done"; break; }
  [ "$now" -ge "$MAX" ] && { say "TIMEOUT"; break; }
  sleep 30
done
sleep 5
grep -h "GRID_E2E" "$OUT/logcat.txt" | sed 's/^.*\(GRID_E2E\)/\1/' > "$OUT/grid_lines.txt" || true
grep -iE "FATAL EXCEPTION|OutOfMemory|lowmemorykiller|am_kill|Process $PKG .* has died|ANR in $PKG" \
  "$OUT/logcat.txt" | grep -v "GRID_E2E" | head -50 > "$OUT/crash_lines.txt" || true
T=20 A shell dumpsys activity exit-info "$PKG" 2>/dev/null | head -60 > "$OUT/exit_info.txt" || true
wc -l "$OUT/grid_lines.txt" "$OUT/mem.tsv" "$OUT/crash_lines.txt"
exit 0
