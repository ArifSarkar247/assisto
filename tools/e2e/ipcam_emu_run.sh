#!/usr/bin/env bash
# cctvbox: runs INSIDE android-emulator-runner (ipcam-e2e.yml). The app test
# on the emulator; on failure a logcat tail is kept as evidence.
set -uo pipefail
cd "$(dirname "$0")/../../app"
timeout 1500 flutter test integration_test/ipcam_guard_e2e_test.dart -d emulator-5554 \
  --dart-define=REALITY_API_BASE=http://10.0.2.2:18700 \
  --dart-define=IPCAM_CTL=http://10.0.2.2:18799 2>&1 | tee "$E2E_DIR/flutter_test.log"
RC=${PIPESTATUS[0]}
timeout 20 adb logcat -d 2>/dev/null | grep -iE "flutter|MediaCodec|CCodec|guardbox|AndroidRuntime|IPCAM" | tail -400 > "$E2E_DIR/logcat_tail.txt" || true
exit $RC
