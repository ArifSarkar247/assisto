#!/usr/bin/env bash
# playvideos (owner decision 8, 9 Nov): records the two Play declaration
# videos on the CI emulator. Runs INSIDE android-emulator-runner (emulator
# booted, throwaway Django on :8700). NEVER on the server.
#
# Unlike tools/reality/run_flows.sh (which pre-grants every permission at
# line ~58), NOTHING is granted here: Android's real permission dialogs show
# and are tapped with `uiautomator dump` + `input tap` (tap_target.py).
# The app (app/integration_test/play_videos_test.dart) prints
#   PLAYVID_MARK <name>  -> timeline mark (rec_start_x / rec_stop_x start and
#                           stop `screenrecord`, <=170 s chunks)
#   PLAYVID_HOST <name>  -> we act (tap a dialog, Home, shade, GPS route) and
#                           then touch acks/<name>.done
# compose.py then cuts each recording to <=30 s with ffmpeg.
set -u
OUT="${PV_OUT:-$PWD/pv_out}"
LANG_CODE="${PV_LANG:-en}"
APK="${PV_APK:?PV_APK}"
PKG=com.assisto.assisto
DEV=/sdcard/Android/data/$PKG/files/reality
HERE="$(cd "$(dirname "$0")" && pwd)"
TOTAL="${PV_TOTAL_SECONDS:-1500}"
mkdir -p "$OUT/a" "$OUT/b" "$OUT/ui" "$OUT/shots"
LOG="$OUT/live_logcat.txt"

# stdin from /dev/null: an adb (or screenrecord) child must never eat the
# PLAYVID lines the main loop reads (run 42594996042 lost every line after
# the first screenrecord started).
A() { timeout "${T:-60}" adb "$@" < /dev/null; }
say() { echo "$(date +%T) $*" | tee -a "$OUT/run.log"; }
now() { date +%s.%N; }
rel() { awk -v a="$(cat "$OUT/$1/t0" 2>/dev/null || now)" -v b="$(now)" 'BEGIN{printf "%.2f", b-a}'; }
CUR=""   # the video being recorded (a|b)
ev() { [ -n "$CUR" ] && echo "$1 $(rel "$CUR")" >> "$OUT/$CUR/events.txt"; say "event $1 (${CUR:-no rec})"; }
ack() { T=10 A shell "mkdir -p $DEV/acks && touch $DEV/acks/$1.done" >/dev/null 2>&1 || true; }
shot() { T=20 A exec-out screencap -p > "$OUT/shots/$1.png" 2>/dev/null || true; }

# ------------------------------------------------------------ device prep
say "device sdk $(T=10 A shell getprop ro.build.version.sdk | tr -d '\r')"
for ime in $(T=10 A shell ime list -s 2>/dev/null | tr -d '\r'); do
  T=10 A shell ime disable "$ime" >/dev/null 2>&1 || true
done
T=10 A shell settings put secure show_ime_with_hard_keyboard 0 >/dev/null 2>&1 || true
T=10 A shell settings put secure location_mode 3 >/dev/null 2>&1 || true
T=10 A shell cmd location set-location-enabled true >/dev/null 2>&1 || true
# a made-up walk (not anyone's real place): start point, then ~16 steps NE
LAT0=23.7800; LNG0=90.4000
geo() { T=10 A emu geo fix "$2" "$1" >/dev/null 2>&1 || true; }
geo "$LAT0" "$LNG0"; sleep 1; geo "$LAT0" "$LNG0"
A logcat -c || true
: > "$LOG"
( timeout "$TOTAL" adb logcat -v time >> "$LOG" 2>&1 < /dev/null ) &

say "install $(basename "$APK") (no -g: nothing pre-granted)"
T=300 A install -t "$APK" 2>&1 | tail -2 | tee -a "$OUT/run.log"
T=10 A shell dumpsys package $PKG | grep -E "granted=true" | head -20 > "$OUT/granted_before.txt" || true
LAUNCHER=$(T=10 A shell cmd package resolve-activity --brief $PKG | tr -d '\r' | tail -1)
say "launcher $LAUNCHER"
front() { T=15 A shell am start -n "$LAUNCHER" >/dev/null 2>&1 || true; }

# ------------------------------------------------------------ helpers
REC_PID=""
rec_start() {  # $1 = a|b
  CUR=$1; now > "$OUT/$1/t0"; : > "$OUT/$1/events.txt"; : > "$OUT/$1/chunks.txt"
  touch "$OUT/$1/.rec"
  ( n=0; while [ -f "$OUT/$1/.rec" ] && [ "$n" -lt 4 ]; do
      echo "c$n.mp4 $(rel "$1")" >> "$OUT/$1/chunks.txt"
      T=200 A shell screenrecord --bit-rate 6000000 --time-limit 170 "/sdcard/pv_$1_c$n.mp4" \
        >> "$OUT/$1/screenrecord.log" 2>&1
      n=$((n + 1))
    done ) &
  REC_PID=$!
  say "recording $1"
}
rec_stop() {  # $1 = a|b
  [ -f "$OUT/$1/.rec" ] || return 0
  rm -f "$OUT/$1/.rec"
  sleep 1
  T=10 A shell pkill -INT screenrecord >/dev/null 2>&1 || true
  [ -n "$REC_PID" ] && { timeout 30 tail --pid="$REC_PID" -f /dev/null || kill "$REC_PID" 2>/dev/null; }
  sleep 2
  for f in $(T=10 A shell ls /sdcard/ 2>/dev/null | tr -d '\r' | grep -E "^pv_$1_c[0-9]+\.mp4$"); do
    T=120 A pull "/sdcard/$f" "$OUT/$1/${f#pv_$1_}" >/dev/null 2>&1 || true
  done
  ls -la "$OUT/$1" | tee -a "$OUT/run.log"
  CUR=""; REC_PID=""
}
ROUTE_PID=""
route_start() {
  touch "$OUT/.route"
  ( i=0; while [ -f "$OUT/.route" ] && [ "$i" -lt 120 ]; do
      lat=$(awk -v a="$LAT0" -v i="$i" 'BEGIN{printf "%.6f", a + i*0.00025}')
      lng=$(awk -v a="$LNG0" -v i="$i" 'BEGIN{printf "%.6f", a + i*0.00018}')
      geo "$lat" "$lng"; echo "$(date +%T) geo $lat $lng" >> "$OUT/route.log"
      i=$((i + 1)); sleep 2
    done ) &
  ROUTE_PID=$!
}
route_stop() { rm -f "$OUT/.route"; [ -n "$ROUTE_PID" ] && kill "$ROUTE_PID" 2>/dev/null; ROUTE_PID=""; }

focus() { T=10 A shell dumpsys window 2>/dev/null | grep -E "mCurrentFocus" | tr -d '\r'; }
# $1 = event prefix (perm_mic ...), $2 = seconds to wait for the dialog
tap_perm() {
  local pre=$1 end=$(( $(date +%s) + $2 )) seen=0 k=0 tgt x y what
  while [ "$(date +%s)" -lt "$end" ]; do
    if focus | grep -q permissioncontroller; then
      if [ "$seen" = 0 ]; then ev "${pre}_seen"; seen=1; fi
      local t_seen; t_seen=$(now)
      k=$((k + 1))
      T=30 A shell uiautomator dump /sdcard/pv_ui.xml >/dev/null 2>&1 || true
      T=20 A pull /sdcard/pv_ui.xml "$OUT/ui/${pre}_$k.xml" >/dev/null 2>&1 || true
      tgt=$(python3 "$HERE/tap_target.py" "$OUT/ui/${pre}_$k.xml")
      if [ -n "$tgt" ]; then
        read -r x y what <<< "$tgt"
        # keep the dialog readable on video for ~2.5 s in total
        awk -v s="$t_seen" -v n="$(now)" 'BEGIN{d=2.5-(n-s); if (d>0) system("sleep " d)}'
        shot "${pre}_dialog"
        T=10 A shell input tap "$x" "$y"
        ev "${pre}_tapped"
        say "tapped $what at $x,$y"
        sleep 1.5
        focus | grep -q permissioncontroller || return 0
      else
        say "$pre: dialog focused but no button found (dump $k)"
        sleep 1
      fi
    else
      sleep 0.5
    fi
  done
  [ "$seen" = 1 ] || say "$pre: no permission dialog appeared in $2 s"
  return 0
}

handle_host() {
  case "$1" in
    lang) T=10 A shell "mkdir -p $DEV/acks && touch $DEV/acks/lang_$LANG_CODE.done" >/dev/null 2>&1 ;;
    perm_mic) tap_perm perm_mic 35 ;;
    perm_notif) tap_perm perm_notif 15 ;;
    perm_loc) tap_perm perm_loc 35 ;;
    bg_shade_b)
      ev home_b; T=10 A shell input keyevent KEYCODE_HOME; sleep 1.5
      ev shade_b; T=10 A shell cmd statusbar expand-notifications; sleep 3; shot shade_b; sleep 4
      T=10 A shell cmd statusbar collapse; sleep 1
      T=10 A shell dumpsys notification --noredact 2>/dev/null | grep -E "pkg=$PKG|android.title=|android.text=" | head -30 > "$OUT/notifications_b.txt"
      front; sleep 2
      # video A needs its notification visible even if B's prompt failed
      T=10 A shell pm grant $PKG android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true ;;
    bg_route_a)
      ev home_a; T=10 A shell input keyevent KEYCODE_HOME; sleep 1.5
      ev shade_a; T=10 A shell cmd statusbar expand-notifications; sleep 3; shot shade_a; sleep 5
      T=10 A shell cmd statusbar collapse; sleep 1
      T=10 A shell dumpsys notification --noredact 2>/dev/null | grep -E "pkg=$PKG|android.title=|android.text=" | head -30 > "$OUT/notifications_a.txt"
      T=10 A shell dumpsys location 2>/dev/null | grep -iE "last.*location|gps" | head -10 > "$OUT/location_a.txt"
      front; sleep 1.5 ;;
    shade_after_a)
      T=10 A shell cmd statusbar expand-notifications; ev shade_after; sleep 3; shot shade_after
      T=10 A shell cmd statusbar collapse; sleep 1 ;;
    *) say "unknown host step $1" ;;
  esac
  ack "$1"
}

handle_mark() {
  case "$1" in
    rec_start_a) rec_start a ;;
    rec_start_b) rec_start b ;;
    rec_stop_a) rec_stop a ;;
    rec_stop_b) rec_stop b ;;
    live) ev live; route_start ;;
    *) ev "$1" ;;
  esac
}

# ------------------------------------------------------------ run
# watchdog: the app process gone (crash) or out of time -> fake all_done
( start=$(date +%s); seen=0; miss=0
  while :; do
    sleep 5
    grep -q "PLAYVID_MARK all_done" "$LOG" && exit 0
    if T=10 A shell pidof $PKG >/dev/null 2>&1; then seen=1; miss=0; else miss=$((miss + 1)); fi
    if { [ "$seen" = 1 ] && [ "$miss" -ge 4 ]; } || [ $(( $(date +%s) - start )) -gt $(( TOTAL - 240 )) ]; then
      echo "PLAYVID_MARK all_done (watchdog: app gone=$miss)" >> "$LOG"; exit 0
    fi
  done ) &

T=20 A shell am start -n "$LAUNCHER" >/dev/null 2>&1 || true
say "app launched (lang $LANG_CODE)"
while read -r kind name <&3; do
  case "$kind" in
    PLAYVID_HOST) say "host $name"; handle_host "$name" ;;
    REALITY_SHOT)  # the harness's own screenshots (e.g. on a failed step)
      T=20 A exec-out screencap -p > "$OUT/shots/$name" 2>/dev/null || true
      T=10 A shell "mkdir -p $DEV/acks && touch $DEV/acks/$name" >/dev/null 2>&1 || true ;;
    PLAYVID_MARK)
      [ "$name" = all_done ] && { say "all done"; break; }
      handle_mark "$name" ;;
  esac
done 3< <(timeout "$TOTAL" tail -n +1 -F "$LOG" 2>/dev/null \
           | grep --line-buffered -oE 'PLAYVID_(MARK|HOST) [A-Za-z0-9_]+|REALITY_SHOT [A-Za-z0-9_.-]+\.png')

route_stop
for v in a b; do [ -f "$OUT/$v/.rec" ] && { CUR=$v; rec_stop "$v"; }; done
T=60 A pull "$DEV/results.json" "$OUT/results.json" >/dev/null 2>&1 || true
grep -aE "PLAYVID_|REALITY_FLOW_START|REALITY FAIL|TestFailure|Exception" "$LOG" | cut -c1-300 | tail -80 > "$OUT/flow_log.txt" || true
for v in b a; do python3 "$HERE/compose.py" "$OUT" "$v" "$LANG_CODE" | tee -a "$OUT/run.log" || true; done
exit 0
