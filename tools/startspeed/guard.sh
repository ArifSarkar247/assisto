#!/usr/bin/env bash
# faststart CI GUARD (owner 10 Nov): on every build, the RELEASE x86_64 APK
# on a 2 GB / 2-core emulator, IN AIRPLANE MODE (no network at all, and no
# traffic to the live server): cold start and hot start, median of 5 after a
# warm-up. Fails when the median passes the limit; one automatic re-measure
# batch first (shared CI emulators jitter), the better batch counts.
#   cold: `am start -W` TotalTime median < COLD_LIMIT (default 2500 ms =
#         the 2 s owner target + 25 % emulator tolerance)
#   hot : Home key -> reopen, TotalTime median < HOT_LIMIT (default 1000 ms)
# Writes start_guard.json + a summary table. Usage: guard.sh <apk>
set -u
APK="$1"
PKG=com.assisto.assisto
COLD_LIMIT="${COLD_LIMIT:-2500}"
HOT_LIMIT="${HOT_LIMIT:-1000}"
OUT="${GUARD_OUT:-$PWD/start_guard}"
mkdir -p "$OUT"
A() { timeout "${T:-60}" adb "$@"; }

sleep 30
T=240 A install -r "$APK" | tail -1
T=10 A shell pm grant $PKG android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
T=10 A shell cmd connectivity airplane-mode enable >/dev/null 2>&1 || true
T=10 A shell svc wifi disable >/dev/null 2>&1 || true
T=10 A shell svc data disable >/dev/null 2>&1 || true
sleep 5
echo "airplane_mode_on=$(T=10 A shell settings get global airplane_mode_on | tr -d '\r')"
CMP=$(T=20 A shell cmd package resolve-activity --brief "$PKG" | tr -d '\r' | tail -1)
echo "launcher: $CMP"

total() { grep -oE 'TotalTime: *[0-9]+' | grep -oE '[0-9]+' | head -1; }
median() { sort -n | awk '{a[NR]=$1} END {if (NR==0) {print 99999} else if (NR%2) {print a[(NR+1)/2]} else {print int((a[NR/2]+a[NR/2+1])/2)}}'; }

cold_batch() {
  local i v
  for i in 1 2 3 4 5; do
    T=20 A shell am force-stop "$PKG" >/dev/null 2>&1 || true
    sleep 3
    v=$(T=60 A shell am start -W -n "$CMP" 2>&1 | total)
    echo "${v:-99999}"
    sleep 6
  done
}
hot_batch() {
  local i v
  for i in 1 2 3 4 5; do
    T=10 A shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
    sleep 3
    v=$(T=60 A shell am start -W -n "$CMP" 2>&1 | total)
    echo "${v:-99999}"
    sleep 3
  done
}

# warm-up (first launch after install: dex/AOT setup is not what users feel daily)
T=20 A shell am force-stop "$PKG" >/dev/null 2>&1 || true
T=60 A shell am start -W -n "$CMP" >/dev/null 2>&1 || true
sleep 10

C1=$(cold_batch | tr '\n' ' '); CM1=$(echo $C1 | tr ' ' '\n' | median)
H1=$(hot_batch | tr '\n' ' '); HM1=$(echo $H1 | tr ' ' '\n' | median)
echo "batch 1: cold [$C1] median $CM1 ms | hot [$H1] median $HM1 ms"
CM=$CM1; HM=$HM1; C2=""; H2=""
if [ "$CM1" -ge "$COLD_LIMIT" ] || [ "$HM1" -ge "$HOT_LIMIT" ]; then
  echo "over a limit - one re-measure batch"
  C2=$(cold_batch | tr '\n' ' '); CM2=$(echo $C2 | tr ' ' '\n' | median)
  H2=$(hot_batch | tr '\n' ' '); HM2=$(echo $H2 | tr ' ' '\n' | median)
  echo "batch 2: cold [$C2] median $CM2 ms | hot [$H2] median $HM2 ms"
  [ "$CM2" -lt "$CM" ] && CM=$CM2
  [ "$HM2" -lt "$HM" ] && HM=$HM2
fi
alive=$(T=10 A shell pidof $PKG | tr -d '\r')
T=10 A shell cmd connectivity airplane-mode disable >/dev/null 2>&1 || true
cat > "$OUT/start_guard.json" <<J
{"cold_median_ms": $CM, "hot_median_ms": $HM, "cold_limit_ms": $COLD_LIMIT, "hot_limit_ms": $HOT_LIMIT,
 "cold_runs": "$C1 $C2", "hot_runs": "$H1 $H2", "network": "airplane", "alive_after": "${alive:-no}"}
J
cat "$OUT/start_guard.json"
{
  echo "### Start-time guard (release APK, 2 GB emulator, airplane mode)"
  echo "| check | median ms | limit | result |"
  echo "|---|---|---|---|"
  echo "| cold start (first screen) | $CM | < $COLD_LIMIT | $([ "$CM" -lt "$COLD_LIMIT" ] && echo PASS || echo FAIL) |"
  echo "| hot start (reopen) | $HM | < $HOT_LIMIT | $([ "$HM" -lt "$HOT_LIMIT" ] && echo PASS || echo FAIL) |"
} | tee "$OUT/summary.md"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$OUT/summary.md" >> "$GITHUB_STEP_SUMMARY"
FAIL=0
[ "$CM" -lt "$COLD_LIMIT" ] || { echo "::error::cold start median $CM ms >= $COLD_LIMIT ms (start-time regression)"; FAIL=1; }
[ "$HM" -lt "$HOT_LIMIT" ] || { echo "::error::hot start median $HM ms >= $HOT_LIMIT ms (start-time regression)"; FAIL=1; }
[ -n "$alive" ] || { echo "::error::app not running after the start runs (offline)"; FAIL=1; }
exit $FAIL
