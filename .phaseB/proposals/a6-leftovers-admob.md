# Proposal — slot a6-leftovers, part AdMob

The FCM part is in `a6-leftovers.md` (already being integrated). This file covers
**AdMob only**. Apply A1 + A2 + A3 **together**: with google_mobile_ads linked
but no `APPLICATION_ID` meta-data, the Mobile Ads SDK crashes at launch.

Without these proposals the branch is green: `NoopAdsBridge` serves no ads,
the rewarded sheet shows its honest "ads not set up yet" state, and nothing
is ever credited without a completed ad.

## What is already in the branch (no proposal needed)
- `app/lib/ads/ad_rules.dart` — pure rule engine (+ `test/ad_rules_test.dart`, 16 tests):
  screen allowlist (app-open: `home` only; rewarded: `credits` only; everything
  else default-deny) + hard block tokens (sos/safety/emergency/journey/lost/
  security, pay/topup/checkout/billing/plans, login/otp/signup/password, call),
  3 h app-open floor (server may only lengthen) + daily cap, plan gating
  (paid = no app-open; rewarded only when the user opts in), real-vs-TEST unit
  choice.
- `app/lib/ads/ads_service.dart` — lazy: `start()` waits 8 s after it is called,
  the SDK is initialised only right before the first ad; app-open on resume
  only when signed in AND the navigator is at its root (home) — any pushed
  screen counts as `unknown` = blocked. Last-shown time + per-day count in
  SharedPreferences. Reports `ads/event app_open` after a shown ad.
- Real unit ids are used only when the server says `configured` (owner saved
  REAL ids that pass `test_admob`) **and** the server app id equals the APK's
  `ADMOB_APP_ID` dart-define. Otherwise Google TEST units, and only in debug
  or with `--dart-define=ADS_TEST_MODE=true` (QA). A release APK without real
  ids shows **no** ads.
- `rewarded_ad_sheet.dart` now plays a real rewarded ad first and posts
  `ads/event rewarded` ONLY on the SDK reward callback (before, it posted
  the event with no ad — that would have credited users without an ad as soon
  as AdMob was enabled). Also fixed: it read `caps.rewarded_today/_cap`, but
  the server returns `caps.rewarded.{cap,used}`.
- `credits_screen.dart` — Premium/Business get an opt-in tile ("Earn credits
  with an optional ad"); button disabled while a pack purchase is in progress.
- `plans_screen.dart` — the "watch an ad +1 credit" button used to call
  `/credits/rewarded` with no ad at all (free credit once AdMob was on) and sat
  on the paywall; it now opens the Credits screen.
- Backend (commit 632cb68): `GET /ads/config`, `test_admob` validator, paid
  opt-in rewarded crediting, `ads_app_open` kill-switch flag.

## A1 — pubspec + activate the bridge
```
bash .phaseB/proposals/a6-admob-apply.sh
```
```diff
--- a/app/pubspec.yaml
+++ b/app/pubspec.yaml
@@
   home_widget: ^0.7.0
+  # a6 AdMob — free plan only, lazy (first ad), never on safety/payment/
+  # login/call screens. TEST ids until the owner saves real ones.
+  google_mobile_ads: 9.1.0
```
plus `git mv app/lib/ads/admob_ads_bridge.dart.pending app/lib/ads/admob_ads_bridge.dart` and
```diff
--- a/app/lib/ads/ads_binding.dart
+++ b/app/lib/ads/ads_binding.dart
-import 'ads_bridge.dart';
+import 'admob_ads_bridge.dart';
+import 'ads_bridge.dart';
@@
-AdsBridge createAdsBridge() => const NoopAdsBridge();
+AdsBridge createAdsBridge() => AdmobAdsBridge();
```
Verified locally: with A1 applied, `flutter pub get` resolves google_mobile_ads 9.1.0
(published 2026-08-11; pulls webview_flutter 4.14.1, play-services-ads 25.4.0,
minSdk 24 <= our 26) and `flutter analyze lib/ads` is clean. Reverted afterwards.

## A2 — CI workflow (`a6-admob-android-yml.diff`, `git apply --check` OK on the pre-FCM file)
- Manifest: `com.google.android.gms.ads.APPLICATION_ID = ${admobAppId}`,
  `OPTIMIZE_INITIALIZATION` + `OPTIMIZE_AD_LOADING` = true, and
  `com.google.android.gms.ads.MobileAdsInitProvider` → `tools:node="remove"`
  (no startup ContentProvider; SDK inits on `MobileAds.initialize()`).
- Gradle `defaultConfig`: `manifestPlaceholders["admobAppId"]` = env
  `ADMOB_APP_ID` or Google's TEST app id `ca-app-pub-3940256099942544~3347511713`.
- Release build step: `env ADMOB_APP_ID: ${{ secrets.ADMOB_APP_ID }}` and
  `--dart-define=ADMOB_APP_ID=...` (same default) so Dart knows which app id the APK has.
- Tested against a fresh `flutter create` (AGP 9.1.0): manifest parses, placeholder lands in defaultConfig.
- If P2 (FCM) is applied first, the hunks touch the same step text near the
  same anchors; apply by hand if `git apply` offsets fail (both are small, additive).

```diff
--- a/.github/workflows/android.yml	2026-10-21 04:52:38.427825347 +0000
+++ b/.github/workflows/android.yml	2026-10-21 04:52:38.451935676 +0000
@@ -191,6 +191,25 @@
           )
           if 'androidx.startup.InitializationProvider' not in s:
               s = s.replace('</application>', startup_remove + '    </application>', 1)
+          # ---- a6 AdMob ----
+          # APPLICATION_ID is REQUIRED (the Mobile Ads SDK crashes at launch
+          # without it). Value comes from the admobAppId manifestPlaceholder:
+          # secret ADMOB_APP_ID, else Google's TEST app id.
+          admob = (
+              '\n        <meta-data android:name="com.google.android.gms.ads.APPLICATION_ID"'
+              ' android:value="${admobAppId}"/>'
+              '\n        <meta-data android:name="com.google.android.gms.ads.flag.OPTIMIZE_INITIALIZATION"'
+              ' android:value="true"/>'
+              '\n        <meta-data android:name="com.google.android.gms.ads.flag.OPTIMIZE_AD_LOADING"'
+              ' android:value="true"/>'
+              # no startup ContentProvider: the SDK initialises when the app
+              # calls MobileAds.initialize() right before the first ad.
+              '\n        <provider android:name="com.google.android.gms.ads.MobileAdsInitProvider"'
+              ' android:authorities="${applicationId}.mobileadsinitprovider"'
+              ' tools:node="remove"/>\n'
+          )
+          if 'com.google.android.gms.ads.APPLICATION_ID' not in s:
+              s = s.replace('</application>', admob + '    </application>', 1)
           open(p, "w").write(s)
           print("manifest patched: label, permissions, queries, UCropActivity, native components, androidx.startup removed")
           PY
@@ -246,6 +265,17 @@
           s = _re.sub(r'\n[ \t]*minSdk[A-Za-z]*\s*=?[^\n]*', '', s)
           inject = '\n        minSdk = 26' if is_kts else '\n        minSdkVersion 26'
           s = s.replace('defaultConfig {', 'defaultConfig {' + inject, 1)
+          # a6 AdMob app id -> manifest placeholder (secret ADMOB_APP_ID or
+          # Google's TEST app id). Must match the --dart-define below.
+          if 'admobAppId' not in s:
+              test_id = "ca-app-pub-3940256099942544~3347511713"
+              if is_kts:
+                  ph = ('\n        manifestPlaceholders["admobAppId"] = '
+                        '(System.getenv("ADMOB_APP_ID") ?: "").ifBlank { "%s" }' % test_id)
+              else:
+                  ph = ('\n        manifestPlaceholders += [admobAppId: '
+                        '(System.getenv("ADMOB_APP_ID") ?: "") ?: "%s"]' % test_id)
+              s = s.replace('defaultConfig {', 'defaultConfig {' + ph, 1)
           # compileSdk 36 (required by flutter_plugin_android_lifecycle)
           s = _re.sub(r'\n[ \t]*compileSdk[A-Za-z]*\s*=?[^\n]*', '', s)
           cinject = '\n    compileSdk = 36' if is_kts else '\n    compileSdk 36'
@@ -271,6 +301,8 @@
 
       - name: Build release APK (arm64 only)
         working-directory: app
+        env:
+          ADMOB_APP_ID: ${{ secrets.ADMOB_APP_ID }}
         run: |
           API_BASE="${{ github.event.inputs.api_base || 'https://api.lifeassisto.com' }}"
           BUILD_TIME="$(date -u +%Y-%m-%dT%H:%MZ)"
@@ -279,7 +311,8 @@
             --build-number=${{ github.run_number }} \
             --build-name=1.0.${{ github.run_number }} \
             --dart-define=API_BASE="$API_BASE" \
-            --dart-define=BUILD_TIME="$BUILD_TIME"
+            --dart-define=BUILD_TIME="$BUILD_TIME" \
+            --dart-define=ADMOB_APP_ID="${ADMOB_APP_ID:-ca-app-pub-3940256099942544~3347511713}"
 
       - name: Build x86_64 debug APK (emulator smoke test only — NOT shipped)
         working-directory: app
```

## A3 — start AdsService after the first frame (`app/lib/main.dart`)
```diff
--- a/app/lib/main.dart
+++ b/app/lib/main.dart
@@
 import 'push/push_service.dart';
+import 'ads/ads_service.dart';
@@
         unawaited(Future<void>.delayed(const Duration(seconds: 2), () async {
           try { await PushService.instance.start(appState); } catch (_) {}
         }));
+        // a6 AdMob — lazy (8 s idle inside start; SDK only before the first
+        // ad), free plan only, home screen only, >= 3 h apart. Guarded.
+        unawaited(Future<void>.delayed(const Duration(seconds: 3), () async {
+          try { await AdsService.instance.start(appState); } catch (_) {}
+        }));
       }
```
(Inside the existing `if (!safe)` block, so startup safe-mode skips it.)
Rewarded ads work without A3 (they start lazily from the Credits screen).

## Risks — needs CI smoke + a real device
- play-services-ads depends on androidx.work. `androidx.startup.InitializationProvider`
  is already removed in CI, so WorkManager is never auto-initialised. If the
  SDK calls `WorkManager.getInstance()` for offline pings and does not catch
  the IllegalStateException, an ad load could crash. Check this on the API-33
  smoke run with TEST mode (`--dart-define=ADS_TEST_MODE=true`) before shipping.
- google_mobile_ads pulls `androidx.lifecycle:lifecycle-process` (its
  ProcessLifecycleInitializer is also disabled by the same removal). We don't
  use `AppStateEventNotifier`, so this should be harmless.

## L3 — Google UMP consent (built, goes live with A1)
- `app/lib/ads/consent.dart` (`AdConsent`) gates EVERY ad request: AdsService
  (app-open, rewarded) before `show*`, and the hero / Photo Studio pending
  bridges inside `_init()` before `MobileAds.initialize()`.
- Real bridge `app/lib/ads/admob_consent_bridge.dart.pending` (UMP inside
  google_mobile_ads 9.1.0 — no extra dependency, no extra manifest entry).
  `a6-admob-apply.sh` now also renames it and binds it in `consent_binding.dart`.
- No-op unless the APK's `ADMOB_APP_ID` dart-define is a REAL app id; fail
  closed if a real app id is present but UMP is not linked.
- Verified locally: with google_mobile_ads 9.1.0 temporarily added, all four
  pending bridges analyze clean (reverted afterwards).
