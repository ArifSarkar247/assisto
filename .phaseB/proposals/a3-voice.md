# a3-voice — Part 3 native voice assistant: integrator proposal

Everything Dart / backend / new Kotlin files is already on branch `agent/a3-voice`.
This file holds only the SHARED-file changes I am not allowed to make directly
(MainActivity.kt, the CI manifest/gradle patch). Apply in two stages, each only
after a real CI launch smoke (API 33) is green.

The new Kotlin files under `app/android_overlay/.../voice/` are compiled by CI
even before this proposal is applied, but nothing references them yet, so the
app behaves exactly as today. Without stage 1 the Dart side degrades honestly
(MissingPluginException is caught → "needs the next update" / web fallbacks).

## Stage 1 — required (assistant entry, TTS, torch, alarms, apps, contacts, calls)

### 1a. MainActivity.kt — register the `com.assisto/voice` channel
Why: the only way to expose my native bridge (TTS, torch, AlarmClock, app
launcher, contacts, direct call, assist-launch flag, wake service) to Dart
without adding a pub plugin. `register()` only installs a handler; nothing is
created until the first call. Wrapped in try/catch so it cannot affect launch.

```diff
--- a/app/android_overlay/app/src/main/kotlin/com/assisto/assisto/MainActivity.kt	2026-10-21 04:58:41.202641727 +0000
+++ b/app/android_overlay/app/src/main/kotlin/com/assisto/assisto/MainActivity.kt	2026-10-21 04:58:41.238607387 +0000
@@ -48,6 +48,15 @@
 
     override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
         super.configureFlutterEngine(flutterEngine)
+        // Part 3 (a3-voice): Assisto Voice channel "com.assisto/voice".
+        // Installs a handler only — TTS / camera / wake word are created on
+        // first use. Guarded so it can never affect launch.
+        try {
+            com.assisto.assisto.voice.AssistoVoiceChannel.register(
+                this, flutterEngine.dartExecutor.binaryMessenger
+            )
+        } catch (e: Throwable) {
+        }
         MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
             .setMethodCallHandler { call, result ->
                 when (call.method) {
```

### 1b. `.github/workflows/android.yml` — manifest patch
Why, line by line:
- `READ_CONTACTS` — "call Ammu" / "Rakib-ke likho…" looks the name up in the
  phonebook. Runtime permission asked ONLY when the user first calls/messages
  someone by name (with a reason dialog); never at launch.
- `CALL_PHONE` — after the user CONFIRMS in the sheet, place the call directly.
  Asked at that moment; if refused we open the dialer with the number (ACTION_DIAL).
- `com.android.alarm.permission.SET_ALARM` — normal (install-time) permission
  required by AlarmClock.ACTION_SET_ALARM / SET_TIMER on many clock apps.
- `<queries>`: LAUNCHER intent (for "open <app>" on API 30+), `TTS_SERVICE`
  (TextToSpeech cannot bind to any engine on API 30+ without it), YouTube +
  WhatsApp packages.
- `AssistEntryActivity` with `android.intent.action.ASSIST` (+ VOICE_COMMAND):
  this is what makes Assisto appear under Settings → Default apps → Digital
  assistant app. Translucent, no UI, no Flutter; it sets a flag and brings
  MainActivity forward. Deliberately NOT a VoiceInteractionService: that also
  needs a RecognitionService and selecting Assisto would replace the phone's
  default speech recognizer with a stub (breaking STT for Assisto and every app).
- `WakeWordService` (`foregroundServiceType="microphone"`, not exported): the
  opt-in "Hey Assisto" listener. `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MICROPHONE`
  + `POST_NOTIFICATIONS` are already declared (#79). Started only from the
  settings toggle, never at boot/launch; not sticky. No WorkManager, no
  startup ContentProvider.

Verified locally: the patched python step was run on a sample generated
manifest → well-formed XML, AssistEntryActivity + WakeWordService present.

```diff
--- a/.github/workflows/android.yml	2026-10-21 04:58:41.200344696 +0000
+++ b/.github/workflows/android.yml	2026-10-21 04:58:41.238357723 +0000
@@ -121,7 +121,13 @@
               '\n    <uses-permission android:name="android.permission.health.READ_SLEEP"/>'
               '\n    <uses-permission android:name="android.permission.health.READ_ACTIVE_CALORIES_BURNED"/>'
               # #80 lost/stolen — alarm vibration
-              '\n    <uses-permission android:name="android.permission.VIBRATE"/>\n'
+              '\n    <uses-permission android:name="android.permission.VIBRATE"/>'
+              # Part 3 Assisto Voice (a3-voice): runtime-asked ONLY at use time
+              # (call / message someone by name; direct call after confirm),
+              # SET_ALARM is a normal permission for AlarmClock intents.
+              '\n    <uses-permission android:name="android.permission.READ_CONTACTS"/>'
+              '\n    <uses-permission android:name="android.permission.CALL_PHONE"/>'
+              '\n    <uses-permission android:name="com.android.alarm.permission.SET_ALARM"/>\n'
           )
           if 'android.permission.INTERNET' not in s:
               s = re.sub(r'(<manifest[^>]*>)', r'\1' + perms, s, count=1)
@@ -134,6 +140,14 @@
               '\n      <intent><action android:name="android.intent.action.VIEW"/></intent>'
               # #70 Health Connect visibility (so the app can resolve HC)
               '\n      <package android:name="com.google.android.apps.healthdata"/>'
+              # Part 3 Assisto Voice: "open <app>" (launcher apps), spoken
+              # replies (TextToSpeech engines must be visible on API 30+),
+              # YouTube / WhatsApp hand-off.
+              '\n      <intent><action android:name="android.intent.action.MAIN"/>'
+              '<category android:name="android.intent.category.LAUNCHER"/></intent>'
+              '\n      <intent><action android:name="android.intent.action.TTS_SERVICE"/></intent>'
+              '\n      <package android:name="com.google.android.youtube"/>'
+              '\n      <package android:name="com.whatsapp"/>'
               '\n    </queries>\n'
           )
           if '<queries>' not in s:
@@ -173,7 +187,26 @@
               '\n            <intent-filter>'
               '\n                <action android:name="android.app.action.DEVICE_ADMIN_ENABLED"/>'
               '\n            </intent-filter>'
-              '\n        </receiver>\n'
+              '\n        </receiver>'
+              # Part 3 Assisto Voice: the "Digital assistant app" entry (ASSIST
+              # activity — no VoiceInteractionService, so the phone's speech
+              # recognizer is never replaced) + the opt-in wake-word service.
+              '\n        <activity android:name="com.assisto.assisto.voice.AssistEntryActivity"'
+              ' android:exported="true" android:excludeFromRecents="true"'
+              ' android:noHistory="true" android:launchMode="singleTop"'
+              ' android:theme="@android:style/Theme.Translucent.NoTitleBar">'
+              '\n            <intent-filter>'
+              '\n                <action android:name="android.intent.action.ASSIST"/>'
+              '\n                <category android:name="android.intent.category.DEFAULT"/>'
+              '\n            </intent-filter>'
+              '\n            <intent-filter>'
+              '\n                <action android:name="android.intent.action.VOICE_COMMAND"/>'
+              '\n                <category android:name="android.intent.category.DEFAULT"/>'
+              '\n            </intent-filter>'
+              '\n        </activity>'
+              '\n        <service android:name="com.assisto.assisto.voice.WakeWordService"'
+              ' android:foregroundServiceType="microphone"'
+              ' android:exported="false"/>\n'
           )
           if '.AssistoWidgetProvider' not in s:
               s = s.replace('</application>', native_components + '    </application>', 1)
```

Stage-1 launch smoke: `lib/main.dart` (already on the branch) adds
`'voice_settings'` to the debug `__tour__`, so the emulator opens the Assisto
Voice settings screen in-process and exercises the native channel
(ping / isDefaultAssistant / wakeStatus) once. The voice screen itself is not in
the tour (it auto-starts the microphone, which the tour can't dismiss).

Manual device check after stage 1 (owner's Realme 9i):
1. Settings → Voice assistant → "Open settings" → pick Assisto as Digital
   assistant app → long-press Home → Assisto Voice opens listening.
2. "আম্মুকে ফোন দাও" → contacts permission → confirm sheet → yes → call.
3. "টর্চ জ্বালাও", "kal 8tay alarm", "ইউটিউবে গান চালাও", "ধানমন্ডি কিভাবে যাব".

## Stage 2 — optional wake word engine (only when the owner wants "Hey Assisto")

Prerequisites (owner): Picovoice account → AccessKey; train "Hey Assisto"
(Android) → `.ppn`; host the .ppn at an https URL; Admin → Integrations →
"Picovoice wake word (Hey Assisto)" → paste AccessKey + URL → Save → Test.
Until then the app shows the toggle disabled with "Coming soon — available
once the wake-word key is set up". Commercial use may need a paid Picovoice plan.

Why Porcupine (not Vosk): on-device, ~1% CPU, ~2–3 MB arm64 vs Vosk's ~7–10 MB
native libs + a ~40 MB model download, and Play policy forbids downloading
native code, so Vosk's libs would always be bundled. Porcupine is called by
REFLECTION in `WakeWordService.kt`, so stage 1 compiles and runs without it
(native returns `engine_missing`, UI says "arrives with an update").

2a. Gradle dependency via the existing desugaring step:
```diff
--- a/.github/workflows/android.yml	2026-10-21 04:58:41.238357723 +0000
+++ b/.github/workflows/android.yml	2026-10-21 04:58:56.560820062 +0000
@@ -300,6 +300,17 @@
               print("desugaring enabled in", p)
           else:
               print("already enabled")
+          # Part 3 (a3-voice) STAGE 2: on-device "Hey Assisto" wake word engine
+          # (Picovoice Porcupine, arm64 ~2-3 MB). Called via reflection from
+          # WakeWordService, so the app is identical without it until used.
+          if "porcupine-android" not in s:
+              dep = ('\n\ndependencies {\n    implementation('
+                     '"ai.picovoice:porcupine-android:3.0.3")\n}\n') if is_kts else (
+                     "\n\ndependencies {\n    implementation "
+                     "'ai.picovoice:porcupine-android:3.0.3'\n}\n")
+              s += dep
+              open(p, "w").write(s)
+              print("porcupine wake-word engine added")
           PY
 
       - name: Build release APK (arm64 only)
```

2b. New file `app/android_overlay/app/proguard-rules.pro` (R8 must keep the
reflectively-called classes; Flutter's gradle plugin includes
`proguard-rules.pro` for release builds):
```
# a3-voice: Porcupine is used via reflection (WakeWordService.kt)
-keep class ai.picovoice.porcupine.** { *; }
```
If another agent also adds proguard-rules.pro, just append this line.

Stage-2 device check: enable the toggle → persistent "Listening for Hey
Assisto" notification with Stop → say "Hey Assisto" with Assisto in the
foreground (opens directly) and in the background (Android may block the
background activity start; a "Tap to talk to Assisto" notification is posted
instead — honest fallback).

## No other shared changes
- No pubspec change (reuses speech_to_text, url_launcher, permission_handler,
  path_provider, http, intl).
- No Django migration (wake-word config lives in the existing Integration table).
- `core/urls.py` block `# ---- a3-voice ----`; `integrations.py` REGISTRY entry
  + `test_picovoice` appended; `screen_synonyms.py` two routes; `agent.py`
  one-line fix (a reminder mentioning "call" is a reminder).
- ARB: `app/up_a3_arb.json` (139 keys, all `va…`).
