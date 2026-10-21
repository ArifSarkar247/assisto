# a3-voice — Part 3 native voice assistant: integrator proposal (rev 2)

Rev 2 follows the owner order: long-press POWER → Assisto, listening, even from
the lock screen; onboarding step; "Hey / Hi Assisto"; play a song by
artist + title.

All Dart, backend and NEW native files (`app/android_overlay/.../voice/*.kt`,
`res/xml/assisto_voice_interaction.xml`, `res/xml/assisto_recognition.xml`) are
already on `agent/a3-voice` (based on `integrate`). Until stage 1 is applied
nothing references them, so the app behaves exactly as today. The Dart side
catches MissingPluginException and says "needs the next update".

## Decision re-check: VoiceInteractionService is REQUIRED (rev 1 was wrong)

What AOSP does on Android 12–14:
- Long-press POWER ("Hold for Assistant"), long-press HOME and the corner-swipe
  gesture all end up in SystemUI `AssistManager.startAssist()`.
- If the ROLE_ASSISTANT holder has an active VoiceInteractionService (VIS), SystemUI
  calls `showSessionForActiveService()`. The session window is shown over the
  keyguard, so the app can be used on a locked phone.
- If the holder is only an `ACTION_ASSIST` activity, SystemUI simply starts that
  activity. On a locked phone the activity stays behind the lock screen until
  the user unlocks.
- Conclusion: "listen instantly even from the lock screen" needs a VIS. Rev 1's
  activity-only entry stays as the fallback, and it also handles the headset
  VOICE_COMMAND button.

The RecognitionService concern:
- `VoiceInteractionServiceInfo` rejects a VIS without `android:recognitionService`,
  so we must declare one.
- When the user picks Assisto as the assistant, Android also makes that service
  the phone's default speech recognizer.
- Therefore `AssistoRecognitionService` is a transparent proxy. Each request is
  forwarded to the best real recognizer (Speech Services by Google, then the
  Google app, then any other), and the callbacks are relayed back. Assisto's own
  `speech_to_text` keeps working, and so do other apps that use the default
  recognizer.
- Limit (documented in the code): other apps' requests run with Assisto's
  microphone permission.

Lock-screen flow:
- The session starts MainActivity with `assisto_voice_locked=true`.
- `applyLaunchIntent` sets `setShowWhenLocked(true)`. The integrated manifest
  already sets this statically, from a6.
- Dart detects the lock (`isLocked`). Torch and SOS run straight away. Every
  other action calls `requestDismissKeyguard` first, and if the user does not
  unlock, it answers "unlock first".
- Closing the screen or pressing back calls `moveTaskToBack` before the route
  pops, so the phone returns to the lock screen and no private screen is shown.

Note for the integrator (not my area): the static `android:showWhenLocked="true"` that a6 set on MainActivity
- lets any Assisto screen show over the keyguard once launched while the phone
  is locked. Please confirm the a6 call/SOS screens guard this the way the
  voice screen does.

## Stage 1: required

### 1a. MainActivity.kt
- `register()` installs the channel handler only.
- `applyLaunchIntent()` in `onCreate` and `onNewIntent` marks "open Assisto Voice"
  for an assist or wake launch.
- Everything is guarded by try/catch. Nothing heavy runs at launch.

```diff
--- a/app/android_overlay/app/src/main/kotlin/com/assisto/assisto/MainActivity.kt
+++ b/app/android_overlay/app/src/main/kotlin/com/assisto/assisto/MainActivity.kt
@@ -46,8 +46,36 @@
     private val dpm: DevicePolicyManager
         get() = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
 
+    // Part 3 (a3-voice): an assist / wake launch marks "open Assisto Voice"
+    // (and, when locked, lets that launch show over the keyguard).
+    override fun onCreate(savedInstanceState: android.os.Bundle?) {
+        super.onCreate(savedInstanceState)
+        try {
+            com.assisto.assisto.voice.AssistoVoiceChannel.applyLaunchIntent(this, intent)
+        } catch (e: Throwable) {
+        }
+    }
+
+    override fun onNewIntent(intent: Intent) {
+        super.onNewIntent(intent)
+        setIntent(intent)
+        try {
+            com.assisto.assisto.voice.AssistoVoiceChannel.applyLaunchIntent(this, intent)
+        } catch (e: Throwable) {
+        }
+    }
+
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
- `READ_CONTACTS` and `CALL_PHONE` are runtime permissions, asked only when the
  user first calls or messages someone by name, or confirms a call. If refused,
  the dialer opens instead.
- `SET_ALARM` is a normal permission, needed for AlarmClock intents.
- `<queries>`:
  - LAUNCHER, for "open <app>";
  - `TTS_SERVICE` and `RecognitionService`; on API 30+ the app can't bind to a TTS engine or find the real recognizer without them;
  - YouTube, YouTube Music, Spotify and WhatsApp, so the app can tell which are installed.
- VIS, session service and recognition proxy: explained in the decision re-check above.
  - The VIS and session services are protected by `BIND_VOICE_INTERACTION`.
  - Note: while Assisto is the selected assistant, Android keeps the VIS bound,
    so Assisto's process stays lightly resident, as Google Assistant's does.
    No Flutter engine starts until the UI opens.
- `AssistEntryActivity`: the ACTION_ASSIST / VOICE_COMMAND fallback. It has no
  UI and no Flutter.
- `WakeWordService`: `foregroundServiceType="microphone"`, not exported, opt-in.
  The FGS microphone and notification permissions are already declared (#79).
  No WorkManager. No startup ContentProvider.

Checked locally: I ran the patched python step on a sample generated manifest.
The result is well-formed XML with all five components present.

```diff
--- a/.github/workflows/android.yml
+++ b/.github/workflows/android.yml
@@ -144,7 +144,12 @@
               '\n    <uses-permission android:name="android.permission.health.READ_SLEEP"/>'
               '\n    <uses-permission android:name="android.permission.health.READ_ACTIVE_CALORIES_BURNED"/>'
               # #80 lost/stolen — alarm vibration
-              '\n    <uses-permission android:name="android.permission.VIBRATE"/>\n'
+              '\n    <uses-permission android:name="android.permission.VIBRATE"/>'
+              # Part 3 Assisto Voice (a3-voice): contacts + call are asked ONLY
+              # at the moment of use; SET_ALARM is a normal permission.
+              '\n    <uses-permission android:name="android.permission.READ_CONTACTS"/>'
+              '\n    <uses-permission android:name="android.permission.CALL_PHONE"/>'
+              '\n    <uses-permission android:name="com.android.alarm.permission.SET_ALARM"/>\n'
           )
           if 'android.permission.INTERNET' not in s:
               s = re.sub(r'(<manifest[^>]*>)', r'\1' + perms, s, count=1)
@@ -157,6 +162,16 @@
               '\n      <intent><action android:name="android.intent.action.VIEW"/></intent>'
               # #70 Health Connect visibility (so the app can resolve HC)
               '\n      <package android:name="com.google.android.apps.healthdata"/>'
+              # Part 3 Assisto Voice: "open <app>", TTS engines + recognizers
+              # (needed on API 30+), music / WhatsApp hand-off.
+              '\n      <intent><action android:name="android.intent.action.MAIN"/>'
+              '<category android:name="android.intent.category.LAUNCHER"/></intent>'
+              '\n      <intent><action android:name="android.intent.action.TTS_SERVICE"/></intent>'
+              '\n      <intent><action android:name="android.speech.RecognitionService"/></intent>'
+              '\n      <package android:name="com.google.android.youtube"/>'
+              '\n      <package android:name="com.google.android.apps.youtube.music"/>'
+              '\n      <package android:name="com.spotify.music"/>'
+              '\n      <package android:name="com.whatsapp"/>'
               '\n    </queries>\n'
           )
           if '<queries>' not in s:
@@ -196,7 +211,51 @@
               '\n            <intent-filter>'
               '\n                <action android:name="android.app.action.DEVICE_ADMIN_ENABLED"/>'
               '\n            </intent-filter>'
-              '\n        </receiver>\n'
+              '\n        </receiver>'
+              # ---- a3-voice: Part 3 Assisto Voice ----
+              # Default digital assistant (VoiceInteractionService): long-press
+              # power / home / corner swipe open Assisto Voice, also over the
+              # lock screen. The platform REQUIRES a recognitionService; ours
+              # proxies to the phone's real recognizer so STT keeps working.
+              '\n        <service android:name="com.assisto.assisto.voice.AssistoVoiceInteractionService"'
+              ' android:permission="android.permission.BIND_VOICE_INTERACTION"'
+              ' android:exported="true">'
+              '\n            <meta-data android:name="android.voice_interaction"'
+              ' android:resource="@xml/assisto_voice_interaction"/>'
+              '\n            <intent-filter>'
+              '\n                <action android:name="android.service.voice.VoiceInteractionService"/>'
+              '\n            </intent-filter>'
+              '\n        </service>'
+              '\n        <service android:name="com.assisto.assisto.voice.AssistoVoiceSessionService"'
+              ' android:permission="android.permission.BIND_VOICE_INTERACTION"'
+              ' android:exported="true"/>'
+              '\n        <service android:name="com.assisto.assisto.voice.AssistoRecognitionService"'
+              ' android:exported="true">'
+              '\n            <intent-filter>'
+              '\n                <action android:name="android.speech.RecognitionService"/>'
+              '\n                <category android:name="android.intent.category.DEFAULT"/>'
+              '\n            </intent-filter>'
+              '\n            <meta-data android:name="android.speech"'
+              ' android:resource="@xml/assisto_recognition"/>'
+              '\n        </service>'
+              # Fallback ACTION_ASSIST / headset VOICE_COMMAND entry (no UI).
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
+              # Opt-in "Hey/Hi Assisto" wake word (never started at launch/boot).
+              '\n        <service android:name="com.assisto.assisto.voice.WakeWordService"'
+              ' android:foregroundServiceType="microphone"'
+              ' android:exported="false"/>\n'
           )
           if '.AssistoWidgetProvider' not in s:
               s = s.replace('</application>', native_components + '    </application>', 1)
```

Launch smoke:
- `lib/main.dart` adds `'voice_settings'` to the debug `__tour__`. That screen
  calls the native channel (ping, isDefaultAssistant, wakeStatus, musicApps)
  once on the emulator.
- The voice screen itself is not in the tour, because it opens the microphone.

## Stage 2: optional "Hey Assisto" / "Hi Assisto" engine
Prerequisites for the owner, explained in Bangla in OWNER_UNLOCK_LIST.md:
- Picovoice AccessKey.
- "Hey Assisto" and "Hi Assisto" `.ppn` files for Android, at https URLs.
- Admin → Integrations → "Picovoice wake word" → Save → Test.

Until then the toggle is honestly disabled: "Coming soon — available once the
wake-word key is set up".

Why Porcupine:
- On-device, about 1% CPU, about 2–3 MB on arm64.
- Vosk needs 7–10 MB of native libraries bundled (Play forbids downloading
  native code) plus a model of about 40 MB.
- The engine is called by reflection, so stage 1 builds without it.

How a wake-up opens Assisto:
- If Assisto is the default assistant, it calls `VoiceInteractionService.showSession()`.
  That opens the voice UI from the background and over the lock screen.
- Otherwise it starts the activity, and if Android blocks the background start,
  it shows a "Tap to talk" notification.

2a. Gradle dependency (this diff applies on top of stage 1):
```diff
--- a/.github/workflows/android.yml
+++ b/.github/workflows/android.yml
@@ -417,6 +417,17 @@
               print("desugaring enabled in", p)
           else:
               print("already enabled")
+          # Part 3 (a3-voice) STAGE 2: on-device "Hey/Hi Assisto" wake word
+          # engine (Picovoice Porcupine, arm64 ~2-3 MB). Called by reflection
+          # from WakeWordService, so nothing changes until the user opts in.
+          s = open(p).read()
+          if "porcupine-android" not in s:
+              s += ('\n\ndependencies {\n    implementation('
+                    '"ai.picovoice:porcupine-android:3.0.3")\n}\n') if is_kts else (
+                    "\n\ndependencies {\n    implementation "
+                    "'ai.picovoice:porcupine-android:3.0.3'\n}\n")
+              open(p, "w").write(s)
+              print("porcupine wake-word engine added")
           PY
 
       - name: Apply google-services Gradle plugin (only when Firebase config exists)
```
2b. New file `app/android_overlay/app/proguard-rules.pro`. R8 must keep the
classes called by reflection. Append this to the file if another slot already created it.
```
# a3-voice: Porcupine is used via reflection (WakeWordService.kt)
-keep class ai.picovoice.porcupine.** { *; }
```

## Not shared / no action
- No pubspec change and no Django migration.
- Backend (all with tests in `core/tests_a3_voice.py`):
  - `voice/config` and `voice/youtube`, in the `# ---- a3-voice ----` block of urls.py;
  - Integrations: new `picovoice` entry; the existing `youtube` entry gets a test and Bangla/English text;
  - `pricing.limits.voice_youtube_daily`, default 40, editable by the admin;
  - `agent.py`: a reminder that mentions "call" stays a reminder.
- ARB: `app/up_a3_arb.json` with 160 `va…` keys. The 139 old keys are unchanged, and 21 are new.
- Phone checklist in Bangla: `.phaseB/proposals/a3-voice-phone-tests.md`.

## Auto voice language (owner's final order)
- The BN/EN chip is removed from the Assisto Voice screen. The recognition
  language comes from `VoiceDictation` (owned by p1-sidebar: Auto by default,
  manual override only in Settings > Voice). `voice_assistant_screen.dart` only
  calls `VoiceDictation(lang: …)`, `start`, `stop`, `listening` and
  `addListener`. **Merge note:** if p1 changes the constructor to
  `VoiceDictation(mode: …)`, update the single line in `_boot()`. No other
  language API is used.
- Replies and TTS follow the language of the user's own words
  (`VaText.replyLang`, unit-tested):
  - Bangla script → bn;
  - Latin script with Banglish words → bn;
  - otherwise → en.
- Reply text comes from `lookupAppLocalizations(Locale(replyLang))`, so the card
  text and the spoken text are in the same language. Data saved to the user's
  lists (expense category, default reminder title) stays in the app language.
- `AssistoRecognitionService` passes the recognizer intent through unchanged.
  That includes p1's Android 14 `EXTRA_ENABLE_LANGUAGE_DETECTION` and the
  bn-BD + en-US extras.
