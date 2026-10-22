# m3-circle — proposals (pubspec / native). Nothing here is applied on the branch.

## 1. In-app QR SCANNER for "Add to My Circle" (optional, next native build)

Today (no scanner plugin in pubspec): My Circle -> Add -> "Show my QR code"
(qr_flutter, already a dependency) + "Copy / Share link", and the other person
"Paste an invite link" (POST /circle/invite/redeem). A phone's own camera app
opens the QR as a link to https://<base>/i/<token>, which now has a real
bilingual landing page (web/urls.py `i/<token>`). The add screen states
honestly that in-app scanning comes in a later update.

Proposed plugin: `mobile_scanner: 5.2.3` (pub.dev, publisher juliansteenbakker,
licence **BSD-3-Clause**). Uses CameraX + ML Kit barcode scanning (bundled
model, no Google Play services dependency for the bundled variant).

```diff
--- a/app/pubspec.yaml
+++ b/app/pubspec.yaml
@@ dependencies:
   qr_flutter: ^4.1.0
+  mobile_scanner: 5.2.3         # m3-circle: scan a My Circle invite QR in-app
```

* Permission: `android.permission.CAMERA` is ALREADY added by android.yml
  (line ~152, camera plugin) — no manifest change needed.
* Owner rules: create the MobileScannerController lazily on the scan screen
  only, wrap start() in try/catch, never at launch. No startup ContentProvider.
* APK size: +~2.5 MB (bundled ML Kit barcode model, arm64).
* Wiring (≈40 lines, no other changes): a "Scan QR" tile in
  `m3_add_to_circle_screen.dart` -> push a scanner page -> on the first barcode
  whose value contains `/i/` call `api.m3Redeem(value)` (same path as Paste).
* Needs the CI API-33 launch smoke + a real-device scan before shipping.

## 2. SharedPreferences broken on release builds (root cause behind the
##    "Phone Safety Check-up spins forever" report) — needs a native look

Evidence (server log `.phaseB/client_crash_reports.log`, users 3 and 18, every
launch on 21 Oct, Android release builds):

```
[prefs] prefs read theme: PlatformException(PlatformException,
  java.lang.NoSuchMethodError: no non-static method
  "Lio/flutter/plugins/sharedpreferences/SharedPreferencesApiRegistrar;.getAll(
   Ljava/lang/String;Ljava/util/List;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;"
```

So `SharedPreferences.getInstance()` THROWS on the device. Every screen that
awaited a Settings read without its own try/catch never left its spinner —
Phone Safety Check-up's `_load()` is exactly that. Fixed app-side on this
branch (Settings never throws/hangs, in-memory fallback, honest banner,
LoadingGate 15 s rule) — but the store itself is still broken on device, so
settings like the chosen Phone-Safety brand / ticks do not survive a restart.

Not reproducible here: `shared_preferences_android 2.4.28` (pubspec.lock) has
no class `SharedPreferencesApiRegistrar` in its sources, so the shipped APK was
either built with a different plugin version than the lock, or R8 renamed /
stripped the method the JNI bridge looks up. Proposed checks for the
integrator (CI, release APK):

1. `apkanalyzer dex packages app-release.apk | grep -i sharedpreferences` —
   confirm which plugin classes/methods are in the shipped dex.
2. If R8 is the cause, keep the plugin intact:
   ```diff
   --- a/app/android/app/proguard-rules.pro   (create via android.yml overlay)
   +++ b/app/android/app/proguard-rules.pro
   +# m3-circle: SharedPreferences JNI/Pigeon bridge must survive R8
   +-keep class io.flutter.plugins.sharedpreferences.** { *; }
   +-keepclassmembers class io.flutter.plugins.sharedpreferences.** { *; }
   ```
   and in `android/app/build.gradle(.kts)` release buildType:
   `proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")`.
3. If it is a version skew, run `flutter pub get --enforce-lockfile` in
   android.yml so CI cannot resolve a different plugin than the lock.
4. The CI smoke installs the DEBUG x86_64 APK only, so it can never catch an
   R8/release-only failure like this one. Suggest one extra smoke step that
   installs the release arm64 APK on an arm64 image (or runs
   `adb logcat | grep '\[prefs\]'` after launch) — or simply watch the
   `[prefs]` line in `client_crash_reports.log` after the next build: it must
   disappear.
