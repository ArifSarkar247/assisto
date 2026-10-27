#!/bin/bash
# ring-everywhere proof (job ring-proof in android.yml): an incoming call must
# RING NATIVELY with the app killed. Uses the smoke APK's adb-only hook
# (calls/RingTestReceiver.kt: needs DUMP, armed only by the ASSISTO_SMOKE build
# after its first frame) which runs exactly the native path an FCM ring push runs.
# Usage: ring_proof.sh <smoke.apk> <api-level>
# Writes ring_<case>.png / ring_<case>_*.txt and ring_result.txt; exit 1 on any failed case.
set -u
APK="$1"; API="$2"; PKG=com.assisto.assisto
RCV="$PKG/$PKG.calls.RingTestReceiver"
fail=0; n=0
log() { echo "$*" | tee -a ring_result.txt; }

adb install -r -g "$APK" >/dev/null || { log "install failed"; exit 1; }
[ "$API" -ge 33 ] && adb shell pm grant $PKG android.permission.POST_NOTIFICATIONS 2>/dev/null
adb shell appops set $PKG USE_FULL_SCREEN_INTENT allow 2>/dev/null || true
adb shell dumpsys deviceidle whitelist -$PKG >/dev/null 2>&1 || true   # never whitelisted: real Doze

# 1st launch: the smoke build arms the hook after its first frame.
timeout 30 adb logcat -c || true
adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 40

ring_case() {   # $1=name  $2=setup command(s)
  local c="$1"; n=$((n+1)); local id=$((990000 + n))
  adb shell am force-stop $PKG
  adb shell input keyevent KEYCODE_WAKEUP; adb shell wm dismiss-keyguard >/dev/null 2>&1; adb shell input keyevent KEYCODE_HOME
  sleep 2
  eval "$2"
  sleep 3
  timeout 30 adb logcat -c || true
  adb shell am broadcast -f 0x20 -a $PKG.RING_TEST -n "$RCV" --es call_id "$id" --es caller_name "'CI Caller'" >/dev/null
  sleep 8
  adb exec-out screencap -p > "ring_${c}.png" 2>/dev/null || true
  timeout 30 adb logcat -d > "ring_${c}_logcat.txt" || true
  adb shell dumpsys notification --noredact > "ring_${c}_notif.txt" 2>/dev/null || true
  local shown=no notif=no inapp=no screen=no
  grep -q "RING_TEST shown=true" "ring_${c}_logcat.txt" && shown=yes
  grep -q "pkg=$PKG" "ring_${c}_notif.txt" && grep -qiE "channel=.*call|category=call" "ring_${c}_notif.txt" && notif=yes
  # calls-a: screen off -> the full-screen intent opens Assisto's ringing
  # screen. It must STILL be ringing 8 s later: either the native ring
  # notification is still posted, or the ringing screen started the in-app
  # ringtone because the notification was gone (Dart logs RING_INAPP_START).
  grep -q "RING_INAPP_START id=$id" "ring_${c}_logcat.txt" && inapp=yes
  grep -qE "CALL_ENTRY entry=(cold|warm)Open action=open id=$id result=(first|top)=ringing" "ring_${c}_logcat.txt" && screen=yes
  if grep -q "RING_TEST ignored" "ring_${c}_logcat.txt"; then log "API $API $c: hook NOT ARMED (not a smoke build?)"; fail=1
  elif [ $shown = yes ] && [ $notif = yes ]; then log "API $API $c: RING OK (native ring shown, call notification still posted; ringing screen=$screen)"
  elif [ $shown = yes ] && [ $inapp = yes ]; then log "API $API $c: RING OK (ringing screen=$screen rings IN-APP; native notification gone)"
  else log "API $API $c: FAIL (shown=$shown call-notification=$notif in-app-ring=$inapp ringing-screen=$screen)"; fail=1; fi
  adb shell am broadcast -f 0x20 -a $PKG.RING_TEST -n "$RCV" --es call_id "$id" --ez cancel true >/dev/null 2>&1
  adb shell dumpsys deviceidle unforce >/dev/null 2>&1 || true
  adb shell input keyevent KEYCODE_WAKEUP
  sleep 2
}

ring_case killed_home   ":"
ring_case killed_settings "adb shell am start -a android.settings.SETTINGS >/dev/null"
ring_case screen_off    "adb shell input keyevent KEYCODE_SLEEP"
ring_case doze          "adb shell input keyevent KEYCODE_SLEEP; adb shell dumpsys battery unplug; adb shell dumpsys deviceidle force-idle"
adb shell dumpsys battery reset >/dev/null 2>&1 || true

[ $fail = 0 ] && log "RING PROOF OK on API $API (4/4)" || log "RING PROOF FAILED on API $API"
exit $fail
