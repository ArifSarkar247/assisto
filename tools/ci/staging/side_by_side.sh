#!/usr/bin/env bash
# staging (owner order 17 Nov): prove "Assisto Test" (com.assisto.assisto.staging)
# installs and launches NEXT TO the production app (com.assisto.assisto) on one
# emulator — both installed at the same time, each cold-starts, no crash/ANR,
# and they are two different apps (own data dirs). Runs inside
# reactivecircus/android-emulator-runner (staging.yml). Evidence -> sbs/.
#   usage: staging_side_by_side.sh <staging.apk> <production.apk>
set -u
STG_APK="$1"; PROD_APK="$2"
STG=com.assisto.assisto.staging
PROD=com.assisto.assisto
mkdir -p sbs
fail() { echo "::error::$*"; echo "FAIL: $*" >> sbs/result.txt; exit 1; }

sleep 45
adb uninstall "$STG" >/dev/null 2>&1 || true
adb uninstall "$PROD" >/dev/null 2>&1 || true
adb install -r "$PROD_APK" > sbs/install_prod.txt 2>&1 || { cat sbs/install_prod.txt; fail "production APK did not install"; }
adb install -r "$STG_APK" > sbs/install_staging.txt 2>&1 || { cat sbs/install_staging.txt; fail "staging APK did not install next to production"; }
adb shell pm list packages | tr -d '\r' | grep -E "package:com\.assisto\.assisto(\.staging)?$" | sort > sbs/packages.txt
cat sbs/packages.txt
grep -qx "package:$PROD" sbs/packages.txt || fail "production app missing after installing staging"
grep -qx "package:$STG" sbs/packages.txt || fail "staging app missing"

# different apps: different Linux uid / data dir
adb shell dumpsys package "$STG" | tr -d '\r' | grep -m1 -E "userId=|appId=" > sbs/uid_staging.txt
adb shell dumpsys package "$PROD" | tr -d '\r' | grep -m1 -E "userId=|appId=" > sbs/uid_prod.txt
echo "uid staging: $(cat sbs/uid_staging.txt) | production: $(cat sbs/uid_prod.txt)"
cmp -s sbs/uid_staging.txt sbs/uid_prod.txt && fail "both packages share one uid"

for P in "$STG" "$PROD"; do
  adb shell pm grant "$P" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
done

launch() {   # $1 package, $2 tag
  local P="$1" T="$2"
  timeout 60 adb logcat -c || true
  (adb logcat -v time > "sbs/logcat_$T.txt" 2>&1 &) ; sleep 1
  adb shell monkey -p "$P" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 \
    || adb shell am start -n "$P/com.assisto.assisto.MainActivity" >/dev/null 2>&1
  sleep 35
  timeout 30 adb shell pidof "$P" | tr -d '\r' > "sbs/pid_$T.txt" 2>/dev/null || true
  adb exec-out screencap -p > "sbs/screen_$T.png" 2>/dev/null || true
  sleep 2
  pkill -f "adb logcat -v time" >/dev/null 2>&1 || true
  grep -E "FATAL EXCEPTION|ANR in $P|$P.*has died|FATAL SIGNAL|E/flutter.*(Unhandled|Fatal)" "sbs/logcat_$T.txt" > "sbs/crashes_$T.txt" 2>/dev/null || true
  test ! -s "sbs/crashes_$T.txt" && echo "no crash lines ($T)"
  test -s "sbs/crashes_$T.txt" && { cat "sbs/crashes_$T.txt" | head -20; fail "crash/ANR while launching $T ($P)"; }
  grep -q "Displayed $P/" "sbs/logcat_$T.txt" || fail "$T: $P/.MainActivity was never displayed"
  test -s "sbs/pid_$T.txt" || fail "$T: $P not running 35 s after a cold start"
  echo "$T COLD START OK pid=$(cat sbs/pid_$T.txt)"
}

launch "$STG" staging
launch "$PROD" production
# both alive at once (staging was not killed by starting production)
timeout 30 adb shell pidof "$STG" | tr -d '\r' > sbs/pid_staging_after.txt 2>/dev/null || true
test -s sbs/pid_staging_after.txt && echo "staging still running next to production"
adb shell dumpsys activity recents | tr -d '\r' | grep -E "realActivity=.*com\.assisto\.assisto" | head -5 > sbs/recents.txt || true
cat sbs/recents.txt
# launcher labels of both
adb shell dumpsys package "$STG" | tr -d '\r' | grep -m1 "versionName" > sbs/version_staging.txt || true
echo "PASS: production + Assisto Test installed together, both cold-start, no crash" | tee sbs/result.txt
