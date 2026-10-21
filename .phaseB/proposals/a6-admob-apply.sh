#!/usr/bin/env bash
# a6-leftovers — APP-SIDE AdMob activation (part A1 of a6-leftovers-admob.md).
# Apply ONLY together with the manifest APPLICATION_ID meta-data (A2) —
# without it the Mobile Ads SDK crashes at launch. Idempotent; repo root.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
python3 - <<'PY'
p = "app/pubspec.yaml"
s = open(p).read()
if "google_mobile_ads:" not in s:
    anchor = "  home_widget: ^0.7.0\n"
    assert anchor in s, "pubspec anchor (home_widget) not found"
    s = s.replace(anchor, anchor +
        "  # a6 AdMob — free plan only, lazy (first ad), never on safety/payment/\n"
        "  # login/call screens. TEST ids until the owner saves real ones.\n"
        "  google_mobile_ads: 9.1.0\n", 1)
    open(p, "w").write(s)
    print("pubspec: google_mobile_ads added")
PY
P=app/lib/ads/admob_ads_bridge.dart
if [ -f "$P.pending" ]; then git mv "$P.pending" "$P" 2>/dev/null || mv "$P.pending" "$P"; fi
python3 - <<'PY'
p = "app/lib/ads/ads_binding.dart"
s = open(p).read()
old = "AdsBridge createAdsBridge() => const NoopAdsBridge();"
if old in s:
    s = s.replace("import 'ads_bridge.dart';",
                  "import 'admob_ads_bridge.dart';\nimport 'ads_bridge.dart';", 1)
    s = s.replace(old, "AdsBridge createAdsBridge() => AdmobAdsBridge();")
    open(p, "w").write(s)
    print("binding: AdmobAdsBridge active")
PY
