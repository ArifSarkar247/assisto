# #79 Hands-free Voice SOS — integration note

Opt-in, **OFF by default** always-listening wake-phrase SOS. A `flutter_foreground_task`
foreground service keeps on-device `speech_to_text` listening (screen off too); on a
wake-phrase match it fires the **EXISTING** SOS action (`api.journeySos`) — it never
duplicates or fakes the alert. Honest persistent notification, battery warning, and an
on-device-only privacy statement are all shown in the UI.

## Packages (pubspec.yaml — already edited)
- Added: `flutter_foreground_task: ^11.0.0` (FGS scaffold + persistent notification +
  `ForegroundServiceTypes.microphone`/`.location`, `sendDataToMain`/`sendDataToTask`
  isolate bridge, `@pragma('vm:entry-point')` callback). No `intl` dep → no version
  conflict; needs `shared_preferences ^2.5.5` (satisfied).
- Reused (already present): `speech_to_text ^7.0.0` (on-device recognition),
  `geolocator ^13` (GPS for the alert), `permission_handler ^11` (mic + openAppSettings).
- `flutter pub get` + `flutter analyze` on the 3 new files = **0 issues**. Lang gate CLEAN.

## New files
- `app/lib/widgets/voice_sos_config.dart` — pure-Dart: Settings keys
  (`voice_sos_on` default false, `voice_sos_phrase`, `voice_sos_cd`), 2 safe default
  wake phrases (`assisto help help`, `assisto emergency now`), and the word-boundary
  `matches()` matcher (unit-testable, no Flutter imports).
- `app/lib/widgets/voice_sos_service.dart` —
  - `voiceSosStartCallback()` (top-level, `@pragma('vm:entry-point')`) → sets the handler.
  - `VoiceSosTaskHandler` (service isolate): keeps `speech_to_text` listening, restarts
    on `done`/`notListening`/error, heartbeat-revives in `onRepeatEvent`; on phrase match
    `FlutterForegroundTask.sendDataToMain(kVoiceSosFire)`. Sends `kVoiceSosUnavailable`
    when no on-device engine (never fakes a transcript).
  - `VoiceSosManager` (main isolate): holds the authenticated `AppState`, receives the
    fire signal, and runs the **existing** SOS (GPS fix + `api.journeySos`). Also
    `init()`/`start()`/`stop()`/`updatePhrase()`.
- `app/lib/screens/voice_sos_screen.dart` — opt-in settings UI: main toggle, wake-phrase
  picker, battery honesty, on-device privacy note, running-state note, and the
  mic-denied → **Open settings** flow (never a dead tap).

## Edited files
- `app/pubspec.yaml` — added the package (see above).
- `app/lib/widgets/chatnav.dart` — route `'voice_sos' → VoiceSosScreen` + English synonyms
  (`hands-free sos`, `voice sos`, `wake phrase`, …). Add `voice_sos` to
  `core/screen_synonyms.py` for Bangla open-from-chat (backend layer).
- `app/lib/screens/safety_screen.dart` — import + a tile (`t.vsosTitle`/`t.vsosTileSubtitle`)
  that opens `VoiceSosScreen` (entry point inside the Safety hub).
- `app/lib/l10n/app_en.arb` + `app_bn.arb` — 24 `vsos*` keys merged (en==bn parity held).
  Source also at `.phaseB/up_voicesos_arb.json`.

## EXISTING SOS reused (NOT duplicated)
- `app/lib/widgets/journey_api.dart:82` — `ApiClient.journeySos({journeyId, lat, lng,
  silent, siren})` → `POST /journey/sos`. This is the single shared SOS action; the
  manual flows use it too (`app/lib/screens/journey_sos_screen.dart:98`).
- `voice_sos_service.dart:212` calls `app.api.journeySos(lat, lng, siren: true)` — same
  endpoint, same family/circle alert + GPS as the button. Offline → server queue/retry
  (unchanged behaviour).

## ARB keys (24, en+bn, no placeholders)
vsosTitle, vsosTileSubtitle, vsosHeadline, vsosIntro, vsosEnableTitle, vsosStateOn,
vsosStateOff, vsosPhraseLabel, vsosPhraseTitle, vsosChange, vsosBatteryNote,
vsosPrivacyNote, vsosRunningNote, vsosNotRunningNote, vsosUnavailable, vsosMicDenied,
vsosMicBlocked, vsosMicBlockedBody, vsosOpenSettings, vsosStartFailed,
vsosNotifChannelName, vsosNotifChannelDesc, vsosNotifTitle, vsosNotifText.

## Settings wiring
All via the existing `Settings` (SharedPreferences) helper — no new storage. The screen
is self-contained (toggle persists `voice_sos_on`); reachable from the Safety hub tile and
`voice_sos` chat route. `VoiceSosManager.instance.attach(appState)` is called from the
screen on enable. **Optional (recommended):** on app start, if `voice_sos_on==true`, call
`VoiceSosManager.instance.init(...)` + `.attach(appState)` + `.start(...)` so the service
survives a reboot/app-kill (the service itself has `autoRunOnBoot:false` by design, so
re-arm happens on next app open — honest and battery-safe).

## MANIFEST ENTRIES TO INJECT (integrator — do NOT edit .github/workflows/android.yml)
`RECORD_AUDIO`, `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, `INTERNET` are ALREADY
injected by the workflow's manifest-patch step. ADD the following (either as a new
permission block in the workflow's `perms` string, OR — preferred for an overlay-only
change — commit an `app/android_overlay/app/src/main/AndroidManifest.xml` fragment that
the merge step overlays; if adding to the workflow patch, append to the existing `perms`):

Permissions (inside `<manifest>`):
```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<uses-permission android:name="android.permission.WAKE_LOCK"/>
```

Service component (inside `<application>`) — declares the microphone+location FGS type on
the package's own service class (required on Android 14 / targetSdk 34+):
```xml
<service
    android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
    android:foregroundServiceType="microphone|location"
    android:exported="false"
    android:stopWithTask="true" />
```
(App id `com.assisto`, package `com.assisto.assisto`, minSdk 23, compileSdk 36. On
minSdk 23 the FGS-type attributes are ignored on old OS and honoured on new OS — correct.)

If injecting via the workflow Python patch, mirror the existing idempotent guards, e.g.:
```python
fgs_perms = (
    '\n    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>'
    '\n    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE"/>'
    '\n    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION"/>'
    '\n    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>'
    '\n    <uses-permission android:name="android.permission.WAKE_LOCK"/>\n'
)
if 'FOREGROUND_SERVICE_MICROPHONE' not in s:
    s = re.sub(r'(<manifest[^>]*>)', r'\1' + fgs_perms, s, count=1)
fgs_service = (
    '\n        <service android:name="com.pravera.flutter_foreground_task.service.ForegroundService"'
    ' android:foregroundServiceType="microphone|location" android:exported="false"'
    ' android:stopWithTask="true"/>\n'
)
if 'flutter_foreground_task.service.ForegroundService' not in s:
    s = s.replace('</application>', fgs_service + '    </application>', 1)
```

## Native Kotlin
NONE required. `flutter_foreground_task` ships the `ForegroundService` + lifecycle;
`speech_to_text` runs in the service isolate. No files under
`app/android_overlay/app/src/main/kotlin/...` are needed for #79 (only the manifest
entries above).

## No dedicated wake-word engine (default path, no key)
Default = on-device `speech_to_text` + `VoiceSosConfig.matches` (continuous dictation,
word-boundary substring match on the chosen phrase). This works with **no API key**.
If a hands-off always-on hotword with lower battery/false-positives is later wanted,
`porcupine_flutter` (Picovoice) is the drop-in seam — it needs an access KEY, so make it
**key-gated**: swap only `VoiceSosTaskHandler._startListening`/match for the Porcupine
`PorcupineManager` callback and gate it behind a key check; keep `speech_to_text` as the
no-key fallback. The default must remain the no-key path.

## DEVICE-TEST-ONLY (cannot verify in headless CI)
- Actual on-device speech recognition + wake-phrase firing (the recognizer is a
  platform service; CI has no mic/engine → the code returns the honest
  `vsosUnavailable` state, which is correct).
- Foreground service surviving screen-off and the persistent notification rendering.
- Battery drain over a real listening session.
- The real `POST /journey/sos` family/circle alert delivery.

## bn/en device-test checklist
1. Fresh install, English: Safety hub → Hands-free Voice SOS. Confirm toggle is **OFF**
   by default; battery note + on-device privacy note visible.
2. Toggle ON → mic reason dialog (en) → grant → persistent "Assisto is listening for your
   SOS phrase" notification appears. Repeat in Bangla (bn copy, same flow).
3. Deny mic permanently → "Microphone is blocked" card + **Open settings** opens system
   settings (never a dead tap). Both languages.
4. **Screen-off test:** lock the phone, speak the wake phrase → SOS countdown/alert fires;
   confirm family/circle receives the `/journey/sos` alert with GPS. Verify in bn too.
5. **Pocket / false-trigger test:** enable, pocket the phone, normal conversation + ~10 min
   of ambient speech → SOS must NOT fire (phrase is uncommon; verify no accidental alert).
6. Change wake phrase to the 2nd default → confirm old phrase no longer fires, new one does
   (no service restart needed — `sendDataToTask`).
7. Toggle OFF → notification disappears, service stops; speaking the phrase does nothing.
8. Device with no speech engine / mic unavailable → honest `vsosUnavailable` state; the
   manual SOS button still works.
9. Reboot with toggle ON → open app → confirm it re-arms (or document that re-arm is on
   next app open by design).
```
