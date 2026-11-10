#!/usr/bin/env bash
# faststart (owner 10 Nov 00:55): start-time measurement on a low-RAM
# emulator. Runs INSIDE reactivecircus/android-emulator-runner (emulator up,
# CI Django on 10.0.2.2:8700, pid in $START_OUT/django.pid). Every adb call is
# time-boxed; the step never fails — tools/startspeed/collect.py judges.
#
#  1. device facts
#  2. real app (profile APK, ASSISTO_PERF marks), fresh install: cold x3
#     (language picker) online + x2 airplane
#  3. perf test APK (same package): signs in + My Circle flow (p02: seeds a
#     chat with 200 real E2E messages)
#  4. real app again over the signed-in data (install -r keeps it):
#       online   : cold x5, hot x5 (Home key -> reopen), warm x3 (activity
#                  re-created in a live process), My Circle x3 (tapped 3 s
#                  after a cold open: ao_open circle@3000) + x2 at the very
#                  first frame (circle0 = worst case)
#       airplane : the same (cold x5, hot x3, warm x3, My Circle x3)
#       lie-fi   : network ON but the server frozen (SIGSTOP) = the slow /
#                  captive-portal case: cold x3, My Circle x2 (30 s windows)
set -u
OUT="${START_OUT:-$PWD/start_out}"
PKG=com.assisto.assisto
DEV=/sdcard/Android/data/$PKG/files/reality
APP_APK="${PERF_APP_APK:?}"
TEST_APK="${PERF_TEST_APK:?}"
mkdir -p "$OUT/mem" "$OUT/runs" "$OUT/shots"
LOG="$OUT/live_logcat.txt"
MK="$OUT/runs/markers.txt"

A() { timeout "${T:-60}" adb "$@"; }
say() { echo "== $(date +%T) $*" | tee -a "$OUT/run.log"; }
app_pid() { T=10 A shell pidof "$PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}'; }
grant() {
  for p in POST_NOTIFICATIONS RECORD_AUDIO CAMERA ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION READ_MEDIA_IMAGES READ_CONTACTS; do
    T=10 A shell pm grant $PKG android.permission.$p >/dev/null 2>&1 || true
  done
}
install_apk() {
  local r
  r=$(T=240 A install -r -t "$1" 2>&1 | tail -2)
  echo "install $(basename "$1"): $r" >> "$OUT/run.log"
  if ! echo "$r" | grep -q Success; then
    say "install -r failed ($r) - clean install"
    T=60 A uninstall "$PKG" >/dev/null 2>&1 || true
    T=240 A install -t "$1" >> "$OUT/run.log" 2>&1 || true
    echo "CLEAN_REINSTALL $(basename "$1")" >> "$OUT/run.log"
  fi
  grant
}
CMP=""
launcher() { T=20 A shell cmd package resolve-activity --brief "$PKG" 2>/dev/null | tr -d '\r' | tail -1; }

begin() { echo "BEGIN $1 $2 $(date +%s%3N)" >> "$MK"; }
end_() { echo "END $1 $2 $(date +%s%3N)" >> "$MK"; }

cold() {  # $1 label  $2 count  $3 wait-s  [$4 extra am args]
  local i
  for i in $(seq 1 "$2"); do
    T=20 A shell am force-stop "$PKG" >/dev/null 2>&1 || true
    sleep 4
    begin "$1" "$i"
    T=60 A shell am start -W -n "$CMP" ${4:-} > "$OUT/runs/${1}_$i.txt" 2>&1 || true
    sleep "$3"
    T=15 A exec-out screencap -p > "$OUT/shots/${1}_$i.png" 2>/dev/null || true
    end_ "$1" "$i"
  done
}
hot() {  # $1 label $2 count: Home key, then reopen (process + activity alive)
  local i
  for i in $(seq 1 "$2"); do
    T=10 A shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
    sleep 4
    begin "$1" "$i"
    T=60 A shell am start -W -n "$CMP" > "$OUT/runs/${1}_$i.txt" 2>&1 || true
    sleep 4
    end_ "$1" "$i"
  done
}
warm() {  # $1 label $2 count: activity re-created in the live process
  local i
  for i in $(seq 1 "$2"); do
    T=10 A shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
    sleep 4
    begin "$1" "$i"
    # FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_CLEAR_TASK
    T=60 A shell am start -W -f 0x10008000 -n "$CMP" > "$OUT/runs/${1}_$i.txt" 2>&1 || true
    sleep 10
    end_ "$1" "$i"
  done
}
net_off() {
  T=10 A shell cmd connectivity airplane-mode enable >/dev/null 2>&1 || true
  T=10 A shell svc wifi disable >/dev/null 2>&1 || true
  T=10 A shell svc data disable >/dev/null 2>&1 || true
  sleep 5
  echo "airplane=$(T=10 A shell settings get global airplane_mode_on | tr -d '\r') ping=$(T=10 A shell ping -c1 -W2 10.0.2.2 >/dev/null 2>&1 && echo reachable || echo unreachable)" | tee -a "$OUT/net_state.txt"
  # some emulator images keep the host route in airplane mode: then REJECT
  # all app traffic (fast failure, exactly like a phone with no signal)
  if T=10 A shell ping -c1 -W2 10.0.2.2 >/dev/null 2>&1; then
    T=10 A shell "iptables -I OUTPUT -d 10.0.2.2 -j REJECT; iptables -I OUTPUT -p udp --dport 53 -j REJECT" >/dev/null 2>&1 || true
    IPT=1
    echo "fallback iptables REJECT; ping=$(T=10 A shell ping -c1 -W2 10.0.2.2 >/dev/null 2>&1 && echo reachable || echo unreachable)" | tee -a "$OUT/net_state.txt"
  fi
}
IPT=0
net_on() {
  T=10 A shell cmd connectivity airplane-mode disable >/dev/null 2>&1 || true
  T=10 A shell svc wifi enable >/dev/null 2>&1 || true
  T=10 A shell svc data enable >/dev/null 2>&1 || true
  if [ "$IPT" = 1 ]; then
    T=10 A shell "iptables -D OUTPUT -d 10.0.2.2 -j REJECT; iptables -D OUTPUT -p udp --dport 53 -j REJECT" >/dev/null 2>&1 || true
    IPT=0
  fi
  sleep 8
  echo "online ping=$(T=10 A shell ping -c1 -W2 10.0.2.2 >/dev/null 2>&1 && echo reachable || echo unreachable)" | tee -a "$OUT/net_state.txt"
}
DJ=$(cat "$OUT/django.pid" 2>/dev/null || echo "")
server_freeze() { [ -n "$DJ" ] && kill -STOP "$DJ" 2>/dev/null; echo "server frozen (lie-fi)" >> "$OUT/net_state.txt"; }
server_thaw() { [ -n "$DJ" ] && kill -CONT "$DJ" 2>/dev/null; echo "server thawed" >> "$OUT/net_state.txt"; }

# ------------------------------------------------------------ 1. device
say "device"
# root adbd now (before the logcat stream starts) so the offline fallback
# can use iptables later without restarting adbd mid-run
T=30 A root >/dev/null 2>&1 || true; sleep 5; T=60 A wait-for-device || true
{
  for p in ro.build.version.sdk ro.product.model ro.config.low_ram dalvik.vm.heapgrowthlimit dalvik.vm.heapsize; do
    echo "$p=$(T=10 A shell getprop $p | tr -d '\r')"
  done
  echo "nproc=$(T=10 A shell nproc | tr -d '\r')"
  echo "wm_size=$(T=10 A shell wm size | tr -d '\r' | tail -1)"
  T=10 A shell cat /proc/meminfo | head -3
} > "$OUT/device.txt" 2>&1
cat "$OUT/device.txt"
for ime in $(T=10 A shell ime list -s 2>/dev/null | tr -d '\r'); do T=10 A shell ime disable "$ime" >/dev/null 2>&1 || true; done
for s in window_animation_scale transition_animation_scale animator_duration_scale; do
  T=10 A shell settings put global $s 1 >/dev/null 2>&1 || true
done
A logcat -c || true
: > "$LOG"
( timeout 7200 adb logcat -v epoch >> "$LOG" 2>&1 ) &
say "settle 45 s after boot"; sleep 45

# ------------------------------------------------------------ 2. fresh
install_apk "$APP_APK"
CMP=$(launcher)
say "fresh install: cold x3 online, x2 airplane"
cold fresh_online 3 10
net_off; cold fresh_offline 2 10; net_on

# ------------------------------------------------------------ 3. sign in + My Circle seed
install_apk "$TEST_APK"
( timeout 1800 tail -n +1 -F "$LOG" 2>/dev/null \
    | grep --line-buffered -oE 'PERF_MEM [A-Za-z0-9_]+' \
    | while read -r _ tag; do
        T=40 A shell dumpsys meminfo "$PKG" > "$OUT/mem/$tag.txt" 2>&1 || true
        T=10 A shell "mkdir -p $DEV/acks && touch $DEV/acks/$tag.mem" >/dev/null 2>&1 || true
      done ) &
( timeout 1800 tail -n +1 -F "$LOG" 2>/dev/null \
    | grep --line-buffered -oE 'REALITY_SHOT [A-Za-z0-9_.-]+\.png' \
    | while read -r _ f; do
        T=20 A exec-out screencap -p > "$OUT/shots/$f" 2>/dev/null || true
        T=10 A shell "mkdir -p $DEV/acks && touch $DEV/acks/$f" >/dev/null 2>&1 || true
      done ) &
say "perf test: sign in + p02 (My Circle)"
T=20 A shell am force-stop "$PKG" >/dev/null 2>&1 || true
T=20 A shell am start -n "$(launcher)" >/dev/null 2>&1 || true
deadline=$(( $(date +%s) + 1500 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  grep -q "PERF_ALL_DONE" "$LOG" && break
  sleep 5
done
grep -q "PERF_ALL_DONE" "$LOG" && say "perf test done" || say "perf test: out of time"
T=60 A pull "$DEV/perf.json" "$OUT/perf.json" >/dev/null 2>&1 || true

# ------------------------------------------------------------ 4. signed in
install_apk "$APP_APK"
CMP=$(launcher)
say "signed in: online"
cold home_online 5 12
hot hot_online 5
warm warm_online 3
cold circle_online 3 14 "--es ao_open circle@3000"
cold circle0_online 2 12 "--es ao_open circle"
T=40 A shell dumpsys meminfo "$PKG" > "$OUT/mem/home_idle.txt" 2>&1 || true

say "signed in: airplane mode"
net_off
cold home_offline 5 12
hot hot_offline 3
warm warm_offline 3
cold circle_offline 3 14 "--es ao_open circle@3000"
cold circle0_offline 2 12 "--es ao_open circle"
net_on

say "signed in: lie-fi (network on, server frozen)"
server_freeze
cold home_liefi 3 30
cold circle_liefi 2 30 "--es ao_open circle@3000"
server_thaw
sleep 5
cold home_after 2 12

# dry-run of the per-build CI guard script on this same emulator/APK
say "guard script dry run"
GUARD_OUT="$OUT/guard" bash "$(dirname "$0")/guard.sh" "$APP_APK" > "$OUT/guard.log" 2>&1 || true
tail -12 "$OUT/guard.log"
T=30 A shell dumpsys activity exit-info "$PKG" > "$OUT/exit_info.txt" 2>&1 || true
grep -E "FATAL|AndroidRuntime|has died|ANR in" "$LOG" | tail -40 > "$OUT/problems.txt" || true
say "done"
pkill -f "tail -n +1 -F $LOG" 2>/dev/null || true
pkill -f "adb logcat -v epoch" 2>/dev/null || true
jobs -p | xargs -r kill 2>/dev/null || true
timeout 20 adb emu kill >/dev/null 2>&1 || true
sleep 5
pkill -9 -f qemu-system 2>/dev/null || true
exit 0
