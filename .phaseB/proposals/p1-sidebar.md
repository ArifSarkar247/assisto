# p1-sidebar — proposals (manifest / gradle / pubspec / MainActivity)

**Nothing to apply for this build.** This slot changes no AndroidManifest,
Gradle, pubspec or MainActivity, and adds no native Kotlin.

## Why there is no native language-detection channel (honest note)

The owner asked for automatic Bangla / English / Banglish voice input, using
Android's own language detection where the phone supports it.

What was checked:
- **speech_to_text 7.5.0** (the version in pubspec.lock) builds its
  RecognizerIntent in `SpeechToTextPlugin.kt` with only these extras:
  LANGUAGE_MODEL, CALLING_PACKAGE, PARTIAL_RESULTS, LANGUAGE, PREFER_OFFLINE,
  MAX_RESULTS and SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS.
- It does **not** pass `EXTRA_ENABLE_LANGUAGE_DETECTION` or
  `EXTRA_LANGUAGE_DETECTION_ALLOWED_LANGUAGES` (API 34+), and has no hook
  to add custom extras.

Doing this properly would need a second recogniser on our side: our own
`SpeechRecognizer`, with its own listener, partial-results stream, error
mapping and `onLanguageDetection`. That second recogniser would compete with
speech_to_text for the mic. That is too risky for this build:
- It cannot be tested here (there is no device; spoken input can't run in CI).
- The owner's Realme 9i runs Android 13, so it would not benefit anyway.
  Detection needs Android 14+, and a recogniser that supports detection for bn.
- It is a new crash surface on ColorOS.

What ships instead (Dart only, in `lib/widgets/voice_input.dart`):
- **Auto (default):** listen with the bn-BD recogniser. Google's Bangla model
  transcribes Bangla, English words and mixed Banglish speech.
  - Fallback order is bn_BD, then bn_IN, then any bn.
  - If the phone has no Bangla at all, Auto uses English instead of failing.
  - If the engine rejects Bangla at runtime (`error_language_not_supported` /
    `_unavailable`), the user sees the honest "Bangla missing" hint, and their
    next tap in that chat goes to English.
- **Manual override:** only in Settings → Voice (Auto / Bangla / English). It
  is stored under `voice_mode_v1`. The old BN/EN chip and its
  `voice_lang_v1` key are no longer used.
- **Server transcription:** skipped. The backend has only a key-gated
  *request-shape* seam (`core/logic/transcription.py`, integration
  `transcription`). It makes no real STT provider call and returns no text,
  and the app does not record audio for upload. Wiring a real Whisper /
  Deepgram call needs the owner's key plus a recording path, so it is left
  for later.

### Plan for a later build (not applied)
A new file would hold a lazy `MethodChannel("assisto/voice_detect")`, with
methods `isSupported()` (SDK ≥ 34 && `SpeechRecognizer.isRecognitionAvailable`)
and `listen(allowed=[bn-BD,en-US])`. The listen method would stream partials
over an `EventChannel` and wrap every call in try/catch:
`app/android_overlay/app/src/main/kotlin/com/assisto/assisto/voice/VoiceDetectChannel.kt`

It would be registered in `MainActivity.configureFlutterEngine` with one
guarded line. Dart would use it only when `isSupported()` is true and the mode
is Auto, and keep speech_to_text otherwise. It would need a real Android 14+
device test before shipping.
