#!/usr/bin/env bash
# guardbox-play — shell helper for app/integration_test/flows/phonecam_fgs_flow.dart
# (guardbox-fgs.yml). The flow prints "PCFGS:<CMD>:<tag>" (logcat, I/flutter);
# this script does what only the shell can and answers with an ack file in the
# app's files dir (run-as: debug test APK):
#   SLEEP      power key -> screen off (KEYCODE_SLEEP) + power state
#   WAKE       screen on + dismiss the (swipe) keyguard
#   DUMP       dumpsys of our services + the camera notification -> $OUT
#   NOTIFSTOP  open the shade, find OUR notification's Stop button, tap it
# usage: pcfgs_sidecar.sh  (env REALITY_OUT)
OUT="${REALITY_OUT:?}"
PKG=com.assisto.assisto
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="$OUT/pcfgs_sidecar.log"
mkdir -p "$OUT"; touch "$OUT/live_logcat.txt"
A() { timeout 25 adb "$@"; }
ack() { A shell run-as $PKG sh -c "mkdir -p files && echo '$2' > files/pcfgs_ack_$1" >> "$LOG" 2>&1; }
declare -A seen
timeout 4000 tail -n0 -F "$OUT/live_logcat.txt" 2>/dev/null \
  | grep --line-buffered -oE 'PCFGS:[A-Z]+:[a-z0-9]+' | while read -r m; do
  cmd=$(echo "$m" | cut -d: -f2); tag=$(echo "$m" | cut -d: -f3)
  [ -n "${seen[$tag]:-}" ] && { ack "$tag" "${seen[$tag]}"; continue; }
  echo "== $(date +%T) $cmd $tag" >> "$LOG"
  res=ok
  case "$cmd" in
    SLEEP)
      A shell input keyevent KEYCODE_SLEEP >> "$LOG" 2>&1; sleep 3
      res="$(A shell dumpsys power | grep -m1 -oE 'mWakefulness=[A-Za-z]+' | tr -d '\r')"
      ;;
    WAKE)
      A shell input keyevent KEYCODE_WAKEUP >> "$LOG" 2>&1; sleep 1
      A shell wm dismiss-keyguard >> "$LOG" 2>&1; sleep 2
      res="$(A shell dumpsys power | grep -m1 -oE 'mWakefulness=[A-Za-z]+' | tr -d '\r')"
      ;;
    DUMP)
      A shell dumpsys activity services $PKG > "$OUT/pcfgs_${tag}_services.txt" 2>&1
      A shell dumpsys notification --noredact > "$OUT/pcfgs_${tag}_notif_all.txt" 2>&1
      grep -n -A6 -E '[|]47310[|]' "$OUT/pcfgs_${tag}_notif_all.txt" > "$OUT/pcfgs_${tag}_notif.txt" || true
      rm -f "$OUT/pcfgs_${tag}_notif_all.txt"
      if grep -q 'PhoneCamService' "$OUT/pcfgs_${tag}_services.txt"; then
        res="service=$(grep -m1 -oE 'isForeground=[a-z]+' "$OUT/pcfgs_${tag}_services.txt" || echo listed)"
      else
        res="service=none"
      fi
      [ -s "$OUT/pcfgs_${tag}_notif.txt" ] && res="$res notif=yes" || res="$res notif=no"
      ;;
    NOTIFSTOP)
      res="notfound"
      A shell cmd statusbar expand-notifications >> "$LOG" 2>&1; sleep 2
      for i in 1 2 3 4; do
        A shell uiautomator dump /sdcard/pcfgs_ui.xml >> "$LOG" 2>&1
        A pull /sdcard/pcfgs_ui.xml "$OUT/pcfgs_${tag}_ui$i.xml" >> "$LOG" 2>&1
        xy="$(python3 "$HERE/pcfgs_ui.py" "$OUT/pcfgs_${tag}_ui$i.xml")"
        echo "ui$i -> $xy" >> "$LOG"
        case "$xy" in
          stop\ *) set -- $xy; A shell input tap "$2" "$3"; res="tapped $2,$3"; break ;;
          expand\ *) set -- $xy; A shell input tap "$2" "$3"; sleep 2 ;;
          *) A shell input swipe 540 300 540 1500 300; sleep 2 ;;
        esac
      done
      sleep 2; A shell cmd statusbar collapse >> "$LOG" 2>&1
      ;;
    *) res="unknown $cmd" ;;
  esac
  seen[$tag]="$res"
  echo "   -> $res" >> "$LOG"
  ack "$tag" "$res"
done
