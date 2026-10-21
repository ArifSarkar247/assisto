#!/usr/bin/env bash
# a6-leftovers — apply the APP-SIDE part P1 of the FCM proposal in one go:
#   1. pubspec: firebase_core + firebase_messaging (exact pins)
#   2. activate the Firebase bridge (rename .pending -> .dart, switch binding)
# Run from the repo root. Idempotent. Then: flutter pub get && flutter analyze.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
python3 - <<'PY'
p = "app/pubspec.yaml"
s = open(p).read()
if "firebase_messaging:" not in s:
    anchor = "  home_widget: ^0.7.0\n"
    assert anchor in s, "pubspec anchor (home_widget) not found"
    s = s.replace(anchor, anchor +
        "  # a6 FCM push — key-gated by google-services.json (CI secret\n"
        "  # GOOGLE_SERVICES_JSON_B64). Lazy init after first frame; the auto-init\n"
        "  # FirebaseInitProvider is removed in the manifest (ColorOS history).\n"
        "  firebase_core: 4.15.0\n"
        "  firebase_messaging: 16.7.0\n", 1)
    open(p, "w").write(s)
    print("pubspec: firebase deps added")
else:
    print("pubspec: already has firebase_messaging")
PY
if [ -f app/lib/push/firebase_push_bridge.dart.pending ]; then
  git mv app/lib/push/firebase_push_bridge.dart.pending app/lib/push/firebase_push_bridge.dart 2>/dev/null \
    || mv app/lib/push/firebase_push_bridge.dart.pending app/lib/push/firebase_push_bridge.dart
fi
python3 - <<'PY'
p = "app/lib/push/push_binding.dart"
s = open(p).read()
old = "PushBridge createPushBridge() => const NoopPushBridge();"
if old in s:
    s = s.replace("import 'push_bridge.dart';",
                  "import 'firebase_push_bridge.dart';\nimport 'push_bridge.dart';", 1)
    s = s.replace(old, "PushBridge createPushBridge() => FirebasePushBridge();")
    open(p, "w").write(s)
    print("binding: FirebasePushBridge active")
else:
    print("binding: already switched")
PY
