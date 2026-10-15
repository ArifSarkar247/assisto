# P11 — iOS PREP integration note

Make the Android-only Assisto Flutter app iOS-ready WITHOUT breaking Android:
(A) gracefully guard/hide Android-only native features on iOS, (B) add an iOS
compile-check CI, (C) complete iOS Info.plist permission usage strings.

Nothing in `api.dart`, `core/models.py`, or Asalify was touched.

## Files changed

### Dart (graceful Android-only guards — part A)
- `app/lib/screens/lost_stolen_screen.dart` (#80, device-admin)
  - `import 'dart:io' show Platform;`
  - `build()`: on `Platform.isIOS` returns an honest **Android-only** state
    (`_iosOnly()`) instead of the device-admin UI.
  - Every MethodChannel entry guarded with an iOS early-return so the native
    `com.assisto/device_admin` channel **never fires on iOS**:
    `_refreshAdmin` (reports INACTIVE and returns), `_enable`,
    `_openAdminSettings`, `_testLock`, `_testAlarm`.
- `app/lib/screens/voice_sos_screen.dart` (#79, always-on voice SOS FGS)
  - `import 'dart:io' show Platform;`
  - `build()`: on iOS returns an honest **Android-only** state (`_iosOnly()`).
  - `_load()` skips querying the foreground service / mic status on iOS.
  - `_toggle()` early-returns on iOS (the `flutter_foreground_task` service is
    **never started on iOS**).
  - `didChangeAppLifecycleState` no longer calls `_refreshMic()` on iOS.
  - Manual SOS is untouched and keeps working on iOS (separate path).
- `app/lib/services/home_widget_service.dart` (#196, home-screen widget)
  - `import 'dart:io' show Platform;`
  - New `static bool get isSupported => Platform.isAndroid;`
  - `init()`, `refresh()`, `clear()` all **no-op on iOS** (never call
    `HomeWidget.*`). `isEnabled`/`setEnabled` (SharedPreferences only) unchanged.
- `app/lib/screens/settings_screen.dart` (`_HomeWidgetTile`)
  - On iOS renders a disabled `ListTile` with an honest "coming soon"
    (`t.hwIosSoon`) instead of a toggle that would do nothing.

### Localization (no Bangla literals in .dart — all via AppLocalizations)
- `app/lib/l10n/app_en.arb` + `app/lib/l10n/app_bn.arb`: 4 new keys.
- Regenerated `app/lib/l10n/app_localizations*.dart` via `flutter gen-l10n`
  (these are git-ignored and rebuilt in CI).
- New ARB keys emitted to `.phaseB/up_ios_arb.json` as `{key:[bn,en]}`:
  `iosAndroidOnlyTitle`, `lostStolenIosOnlyBody`, `vsosIosOnlyBody`, `hwIosSoon`.

### CI (part B + C)
- `.github/workflows/ios.yml` — new macOS compile-check workflow (see below).

## Platform-guard points (summary)
| Feature | Native dependency | iOS behaviour |
|---|---|---|
| #80 Lost/stolen | MethodChannel `com.assisto/device_admin` | honest Android-only screen; channel never invoked |
| #79 Voice SOS | `flutter_foreground_task` + `speech_to_text` FGS | honest Android-only screen; service never started; manual SOS still works |
| #196 Home widget | `home_widget` (AppWidgetProvider) | service no-ops; Settings tile shows "coming soon" |

Other native touchpoints checked and found **cross-platform safe** (no change
needed): SMS/dial/WhatsApp hand-offs all go through `url_launcher`
(`tel:` / `sms:` / `https://wa.me/...`), which iOS supports. `sos_native_hooks.dart`
contains only a doc comment, no live channel. The only `MethodChannel` in the
whole `lib/` tree is the device-admin one (now guarded).

## The ios.yml job
`runs-on: macos-14` (iOS builds require a Mac). Triggers: `workflow_dispatch`
(manual) + `push` to `main` on `app/**` or the workflow file. Steps:
1. checkout + `subosito/flutter-action@v2` (stable).
2. `flutter create --platforms=ios .` in `app/` (iOS platform tree is NOT
   committed — mirrors the android.yml approach).
3. `flutter pub get`.
4. **Patch `ios/Runner/Info.plist`** with the complete permission usage strings
   (part C) + `UIBackgroundModes`.
5. **Patch `ios/Podfile`** `platform :ios, '15.0'` (required — see gotcha).
6. `flutter precache --ios`.
7. `pod install --repo-update` (surfaces any iOS-unsupported pod as an isolated
   failure).
8. `flutter build ios --release --no-codesign` — proves the app COMPILES for
   iOS unsigned. It does **NOT** produce a signed/installable IPA.

Clearly marked throughout as a **compile check only**.

## Info.plist entries added (part C)
Camera / mic / photos (consistent with android.yml's iOS patch), plus:
- `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`,
  `NSPhotoLibraryUsageDescription`
- `NSLocationWhenInUseUsageDescription`,
  `NSLocationAlwaysAndWhenInUseUsageDescription`
- `NSContactsUsageDescription` (circle invites / contact matching)
- `NSSpeechRecognitionUsageDescription` (voice input)
- `NSMotionUsageDescription` (steps/activity)
- `NSHealthShareUsageDescription` + `NSHealthUpdateUsageDescription` (the
  `health` plugin reads HealthKit; the HealthKit *capability* still needs
  signing, out of scope for the unsigned compile check)
- `UIBackgroundModes` (`fetch`, `processing`) for the foreground-task pod

## Plugin iOS support (Android-only-guarded vs iOS-supported)
All declared plugins support iOS on pub.dev:
- iOS-supported, used normally on iOS: `http`, `sqflite`, `path_provider`,
  `shared_preferences`, `flutter_secure_storage`, `provider`,
  `package_info_plus`, `open_filex`, `flutter_local_notifications`, `timezone`,
  `url_launcher`, `image_picker`, `camera`, `permission_handler`,
  `image_cropper`, `geolocator`, `speech_to_text`, `share_plus`,
  `intl`, `flutter_localizations`.
- iOS-supported **but Dart usage guarded Android-only** (so the plugin compiles
  and its pod installs, but we never invoke it on iOS):
  - `flutter_foreground_task` — iOS background is 30s/15min; we do NOT run the
    always-on voice-SOS service on iOS (guarded in `voice_sos_screen.dart`).
  - `home_widget` — has an iOS WidgetKit side, but **no iOS widget extension is
    built**, so all calls are no-ops on iOS (guarded in `home_widget_service`).
  - `health` — supports iOS via HealthKit but needs the **HealthKit capability**
    (a signing concern) for real reads; min iOS 15.0.
- **No plugin is Android-only / unsupported on iOS.** None were removed.

## Will `flutter build ios --no-codesign` pass?
**Expected to pass**, with the two patches the workflow applies:
1. **Podfile deployment target must be `>= 15.0`** — `health` requires 15.0 and
   `flutter_foreground_task` 13.0. The default Flutter Podfile target is lower,
   which would make `pod install` fail on those pods. The workflow sets
   `platform :ios, '15.0'`, which resolves this.
2. The `health` plugin's **HealthKit capability** is a *signing/entitlement*
   concern, not a compile concern — `--no-codesign` skips signing, so it should
   not block the compile. (It WOULD block a real signed archive until the
   capability is added in Xcode with a provisioning profile.)

Residual risk is normal CI/version churn (CocoaPods specs, Xcode version on the
runner), not a known Android-only plugin. If a pod unexpectedly breaks the
build, the `pod install` step isolates which one — do NOT remove the plugin;
guard its Dart usage the same way (dart:io `Platform` check) and document it
here.

## How to RUN the iOS compile check
- GitHub UI: Actions → "iOS compile check (Assisto)" → **Run workflow**
  (`workflow_dispatch`), pick branch `main`.
- CLI: `gh workflow run ios.yml --ref main`
- It also runs automatically on pushes to `main` that touch `app/**`.
- Watch: `gh run watch` / `gh run list --workflow=ios.yml`.
- Output: a green compile check. **No artifact / no IPA** is produced (unsigned).

## Follow-ups to DOCUMENT (NOT built here — need a Mac + Apple Developer acct)

### iOS Share Extension (receive shared photos/links into Assisto)
- A new Xcode **Share Extension** target (`ShareViewController`) embedded in the
  Runner app, sharing an **App Group** (`group.com.assisto`) so the extension
  and the app can exchange files/data.
- Needs: App Group capability on both targets, an `NSExtension` /
  `NSExtensionActivationRule` in the extension's Info.plist, and app-side code to
  read the shared item from the App Group container on launch.
- Pairs with the Android share-target intent-filter (already in the overlay).
- Cannot be generated by `flutter create`; must be added in Xcode on a Mac and
  committed as part of a signed build pipeline.

### Siri Shortcuts / App Intents (e.g. "Hey Siri, send SOS")
- Modern path: an **App Intents** extension (iOS 16+) exposing intents like
  `SendSosIntent`, `OpenReminderIntent`, each calling into the existing app
  logic via the App Group / a shared method channel.
- Older path: `NSUserActivity` donation + `INIntent` definitions.
- Needs: a `.intentdefinition` or App Intents Swift target, Siri capability, and
  usage strings; voice SOS via Siri would be the iOS-friendly REPLACEMENT for
  the Android always-on foreground listener (#79) since iOS forbids the latter.
- Requires Xcode on a Mac; document as the preferred iOS "hands-free SOS" route.

### Also for a real signed build (beyond this compile check)
- Apple Developer account + provisioning profiles + signing in CI (secrets).
- HealthKit capability on the Runner target (for `health` reads).
- A WidgetKit extension to actually ship the #196 home widget on iOS (until then
  the Settings tile honestly says "coming soon").

## ACTUAL iOS COMPILE RESULT (2 CI runs, Xcode default + 15.4)
Both failed at the SAME point — `camera_avfoundation` Swift:
  `Type 'AVCaptureSession' has no member 'wasInterruptedNotification'`
  `Type 'AVCaptureSession' has no member 'runtimeErrorNotification'`
This is INSIDE the `camera` 0.11.0+2 plugin's iOS code, not ours. pod install +
the Xcode build run fine; only the camera pod's Swift fails to compile. This is a
known plugin/Xcode-SDK issue. FIX for the real iOS release (on a Mac):
  1) bump `camera` to a newer version (then re-run the Android APK build to confirm
     Android stays green — camera is shared), OR
  2) pin/patch camera_avfoundation to a compatible pod, OR
  3) temporarily gate the camera screen out of the iOS build if iOS v1 ships without it.
Everything else (all other plugins, Dart, Info.plist, Podfile iOS 15.0, guards) is
iOS-ready. Did NOT bump camera here to avoid destabilizing the green Android build.
