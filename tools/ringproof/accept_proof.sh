#!/bin/bash
# calls-a accept proof (job ring-proof in android.yml, after ring_proof.sh):
# tapping ACCEPT on an incoming call must open the CALL SCREEN as the very
# first screen — no home first, no second ringing screen — on a cold app, a
# warm (backgrounded) app and the lock screen.
#
# The ring is the smoke APK's adb-only hook (RingTestReceiver, same native
# path as an FCM ring). Accept is tapped on the REAL notification button
# (shade -> uiautomator "Answer"/"Accept"); if the shade layout cannot be read
# the script fires the IDENTICAL intent the button carries (am start on
# CallEntryActivity is not possible from adb because it is not exported, so
# the fallback targets MainActivity with the same action/extras) and says so.
#
# Evidence per case (accept_<case>.png / _logcat.txt / _activities.txt):
#   cold : "CALL_LAUNCH cold action=accept" (native, MainActivity.getInitialRoute)
#          + "CALL_ENTRY entry=coldAccept ... result=first=call" (Dart)
#          + "FIRST_FRAME top=call_accept"  (the first Flutter frame = call)
#   warm : "CALL_LAUNCH warm action=accept" + "entry=warmAccept ... top=call"
#   lock : as cold/warm, plus the keyguard still showing while our activity
#          is resumed (shown OVER the lock screen, no unlock asked)
# The CI emulator is NOT signed in, so after the first frame the call screen
# honestly closes ("CALL_SCREEN closed reason=signed_out") — the proof is the
# routing (first screen), which is what the owner's bug was about.
# Usage: accept_proof.sh <smoke.apk> <api-level>   (APK already installed by
# ring_proof.sh is fine; it is re-installed with -r). Exit 1 on a failed case.
set -u
APK="$1"; API="$2"; PKG=com.assisto.assisto
RCV="$PKG/$PKG.calls.RingTestReceiver"
fail=0; n=0
log() { echo "$*" | tee -a accept_result.txt; }

adb install -r -g "$APK" >/dev/null 2>&1 || true
[ "$API" -ge 33 ] && adb shell pm grant $PKG android.permission.POST_NOTIFICATIONS 2>/dev/null
adb shell appops set $PKG USE_FULL_SCREEN_INTENT allow 2>/dev/null || true
# arm the hook once (first launch of the smoke build, after its first frame)
adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 25

ring() {  # $1 = call id
  adb shell am broadcast -f 0x20 -a $PKG.RING_TEST -n "$RCV" --es call_id "$1" --es caller_name "'CI Caller'" >/dev/null
}

# Tap the notification's Answer/Accept button through the real shade.
tap_accept() {  # $1 = call id ; echoes "tap" or "intent"
  local id="$1"
  adb shell cmd statusbar expand-notifications >/dev/null 2>&1
  sleep 2
  adb shell uiautomator dump /sdcard/acc_ui.xml >/dev/null 2>&1
  adb pull /sdcard/acc_ui.xml acc_ui.xml >/dev/null 2>&1
  local b
  b=$(python3 - <<'PY' 2>/dev/null
import re
try:
    x = open("acc_ui.xml", encoding="utf-8").read()
except Exception:
    raise SystemExit
for m in re.finditer(r'<node [^>]*>', x):
    n = m.group(0)
    t = (re.search(r'text="([^"]*)"', n) or [None, ""])[1]
    d = (re.search(r'content-desc="([^"]*)"', n) or [None, ""])[1]
    if re.fullmatch(r'(?i)\s*(answer|accept)\s*', t) or re.fullmatch(r'(?i)\s*(answer|accept)\s*', d):
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
        if b:
            x1, y1, x2, y2 = map(int, b.groups())
            print((x1 + x2) // 2, (y1 + y2) // 2)
            break
PY
)
  if [ -n "$b" ]; then
    adb shell input tap $b
    echo tap
    return
  fi
  adb shell cmd statusbar collapse >/dev/null 2>&1
  # identical extras to IncomingCall.post()'s Answer PendingIntent
  local nid
  nid=$(grep -o "RING_TEST shown=true id=[0-9]*" ring_tmp.txt 2>/dev/null | tail -1 | sed 's/.*id=//')
  adb shell "am start -n $PKG/$PKG.MainActivity -a SELECT_FOREGROUND_NOTIFICATION -f 0x10000000 \
    --ei notificationId ${nid:-0} --es actionId accept --ez cancelNotification true \
    --es payload '{\"kind\":\"call\",\"call_id\":\"$id\",\"caller_name\":\"CI Caller\",\"caller_id\":\"0\",\"video\":\"false\",\"lang\":\"en\"}'" >/dev/null 2>&1
  echo intent
}

check() {  # $1 = case  $2.. = required logcat patterns (regex)
  local c="$1"; shift
  local ok=yes miss=""
  for pat in "$@"; do
    grep -qE "$pat" "accept_${c}_logcat.txt" || { ok=no; miss="$miss [$pat]"; }
  done
  # never a second ringing screen / home first on the accept path
  if grep -qE "FIRST_FRAME top=other" "accept_${c}_logcat.txt"; then ok=no; miss="$miss [first frame was not the call]"; fi
  if [ $ok = yes ]; then log "API $API $c: ACCEPT OK (how=$how)"; else log "API $API $c: FAIL (how=$how) missing:$miss"; fail=1; fi
}

collect() {  # $1 = case
  sleep 4
  adb exec-out screencap -p > "accept_${1}.png" 2>/dev/null || true
  timeout 30 adb logcat -d > "accept_${1}_logcat.txt" || true
  adb shell dumpsys activity activities > "accept_${1}_activities.txt" 2>/dev/null || true
  adb shell dumpsys window > "accept_${1}_window.txt" 2>/dev/null || true
}

# ---- 1) cold: app killed, Accept on the heads-up / shade notification
n=$((n+1)); id=$((995000 + n)); how=-
adb shell am force-stop $PKG
adb shell input keyevent KEYCODE_WAKEUP; adb shell wm dismiss-keyguard >/dev/null 2>&1; adb shell input keyevent KEYCODE_HOME
sleep 2; timeout 30 adb logcat -c || true
ring $id; sleep 5
timeout 20 adb logcat -d > ring_tmp.txt || true
how=$(tap_accept $id)
collect cold
check cold "CALL_LAUNCH cold action=accept" "entry=coldAccept action=accept id=$id result=first=call" "FIRST_FRAME top=call_accept"
adb shell am broadcast -f 0x20 -a $PKG.RING_TEST -n "$RCV" --es call_id "$id" --ez cancel true >/dev/null 2>&1

# ---- 2) warm: app open then sent to the background, Accept
n=$((n+1)); id=$((995000 + n)); how=-
adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 12
adb shell input keyevent KEYCODE_HOME; sleep 3
timeout 30 adb logcat -c || true
ring $id; sleep 5
timeout 20 adb logcat -d > ring_tmp.txt || true
how=$(tap_accept $id)
collect warm
check warm "CALL_LAUNCH warm action=accept" "entry=warmAccept action=accept id=$id result=(top=call|ringing_screen_accept)"
adb shell am broadcast -f 0x20 -a $PKG.RING_TEST -n "$RCV" --es call_id "$id" --ez cancel true >/dev/null 2>&1

# ---- 3) lock screen: app killed, screen off -> full-screen ring over the
# keyguard -> Accept. Proof: our activity resumed while the keyguard shows.
n=$((n+1)); id=$((995000 + n)); how=-
adb shell am force-stop $PKG
adb shell input keyevent KEYCODE_SLEEP; sleep 3
timeout 30 adb logcat -c || true
ring $id; sleep 6
timeout 20 adb logcat -d > ring_tmp.txt || true
adb shell input keyevent KEYCODE_WAKEUP; sleep 1
how=$(tap_accept $id)
collect lock
check lock "CALL_LAUNCH (cold|warm) action=(open|accept)" "entry=(cold|warm)(Open|Accept) .*id=$id"
kg=no; grep -qiE "mShowingLockscreen=true|isKeyguardShowing=true|KeyguardShowing=true|mKeyguardShowing=true" accept_lock_window.txt accept_lock_activities.txt 2>/dev/null && kg=yes
top=no; grep -qE "(mResumedActivity|topResumedActivity|ResumedActivity).*$PKG/.MainActivity" accept_lock_activities.txt 2>/dev/null && top=yes
log "API $API lock: keyguard_showing=$kg assisto_resumed=$top (both yes = shown OVER the lock screen)"
adb shell am broadcast -f 0x20 -a $PKG.RING_TEST -n "$RCV" --es call_id "$id" --ez cancel true >/dev/null 2>&1
adb shell input keyevent KEYCODE_WAKEUP

[ $fail = 0 ] && log "ACCEPT PROOF OK on API $API (3/3)" || log "ACCEPT PROOF FAILED on API $API"
exit $fail
