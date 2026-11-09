import '../audio/audio_route_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Thin, crash-guarded bridge to the native Assisto Voice channel
/// (`AssistoVoiceChannel.kt`). Every call is lazy (the native side only
/// creates TextToSpeech / CameraManager / the wake service on first use) and
/// every call swallows errors: if the native half is missing (older build) or
/// throws, the Dart side gets a safe fallback value and degrades honestly.
class VaNative {
  VaNative._();

  static const MethodChannel _ch = MethodChannel('com.assisto/voice');

  static Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _ch.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('VaNative.$method failed: $e');
      return null;
    }
  }

  /// True when the native half is present in this build.
  static Future<bool> available() async => (await _call<bool>('ping')) == true;

  // ---- launch / default assistant -----------------------------------------

  /// True once if the app was opened via the assist gesture / wake word.
  static Future<bool> consumeAssistLaunch() async =>
      (await _call<bool>('consumeAssistLaunch')) == true;

  /// Whether Assisto currently holds the Android "Digital assistant" role.
  /// null = unknown (Android < 10 or native missing).
  static Future<bool?> isDefaultAssistant() =>
      _call<bool>('isDefaultAssistant');

  /// Opens the system screen where the user picks the default assistant.
  static Future<bool> openAssistantSettings() async =>
      (await _call<bool>('openAssistantSettings')) == true;

  // ---- speech out ------------------------------------------------------------

  /// Speak [text] in [lang] ('bn' | 'en'). Returns 'ok', 'no_voice' (engine has
  /// no voice for that language), 'no_engine', or null (native missing).
  ///
  /// audioroute: read-aloud (AI assistant, aivoice, Car Mode, hands-free
  /// loop) plays on the media stream, so it follows the connected earphones;
  /// a stale call / mic session is cleared first (never on the earpiece).
  static Future<String?> speak(String text, String lang) async {
    try {
      await AudioRouteService.instance
          .preparePlayback(AudioUse.assistantSpeak);
    } catch (_) {}
    return _call<String>('speak', {'text': text, 'lang': lang});
  }

  static Future<void> stopSpeaking() => _call<void>('stopSpeaking');

  /// Opens the system TTS settings (to install the Bangla voice).
  static Future<bool> openTtsSettings() async =>
      (await _call<bool>('openTtsSettings')) == true;

  /// aivoice: opens the phone's "Voice input" settings (where ColorOS / MIUI
  /// / Samsung users pick Google as the speech engine). Falls back to the
  /// keyboard settings on the native side. false = nothing opened.
  static Future<bool> openVoiceInputSettings() async =>
      (await _call<bool>('openVoiceInputSettings')) == true;

  // ---- phone actions -------------------------------------------------------

  /// Turn the flashlight on/off. 'ok' | 'no_flash' | 'error' | null.
  static Future<String?> torch(bool on) => _call<String>('torch', {'on': on});

  /// Hand an alarm to the phone's clock app. 'ok' | 'no_app' | 'denied' | null.
  static Future<String?> setAlarm(int? hour, int? minute, String label) =>
      _call<String>(
          'setAlarm', {'hour': hour, 'minute': minute, 'label': label});

  static Future<String?> setTimer(int? seconds, String label) =>
      _call<String>('setTimer', {'seconds': seconds, 'label': label});

  /// Launcher apps on this phone: [{label, package}].
  static Future<List<Map<String, String>>> listApps() async {
    final r = await _call<List<Object?>>('listApps');
    if (r == null) return const [];
    return [
      for (final e in r)
        if (e is Map)
          {
            'label': '${e['label'] ?? ''}',
            'package': '${e['package'] ?? ''}',
          }
    ];
  }

  static Future<bool> launchApp(String package) async =>
      (await _call<bool>('launchApp', {'package': package})) == true;

  /// Phonebook entries [{name, phone}]. Requires READ_CONTACTS (asked by the
  /// caller at the moment of use).
  static Future<List<Map<String, String>>> contacts() async {
    final r = await _call<List<Object?>>('contacts');
    if (r == null) return const [];
    return [
      for (final e in r)
        if (e is Map)
          {'name': '${e['name'] ?? ''}', 'phone': '${e['phone'] ?? ''}'}
    ];
  }

  /// Places the call directly (needs CALL_PHONE). 'ok' | 'denied' | null.
  static Future<String?> callNow(String number) =>
      _call<String>('callNow', {'number': number});

  /// YouTube in-app search (falls back to the caller's web URL when null).
  static Future<bool> youtubeSearch(String query) async =>
      (await _call<bool>('youtubeSearch', {'query': query})) == true;

  // ---- lock screen -----------------------------------------------------------

  /// True when the phone is locked (Assisto was opened over the lock screen).
  static Future<bool> isLocked() async => (await _call<bool>('isLocked')) == true;

  /// Ask Android to show the unlock prompt. true = unlocked.
  static Future<bool> requestUnlock() async =>
      (await _call<bool>('requestUnlock')) ?? true; // no native = never locked

  /// Stop showing over the lock screen; [moveBack] returns to the lock screen.
  static Future<void> leaveLockScreen({bool moveBack = false}) =>
      _call<void>('leaveLockScreen', {'moveBack': moveBack});

  // ---- music -----------------------------------------------------------------

  static const pkgYtMusic = 'com.google.android.apps.youtube.music';
  static const pkgSpotify = 'com.spotify.music';
  static const pkgYoutube = 'com.google.android.youtube';

  /// Installed music apps among YouTube Music / Spotify / YouTube.
  static Future<List<String>> musicApps() async {
    final r = await _call<List<Object?>>('musicApps');
    return r == null ? const [] : r.map((e) => '$e').toList();
  }

  /// Android MEDIA_PLAY_FROM_SEARCH into [package]: 'ok' | 'no_app' | 'error'.
  static Future<String?> playFromSearch(String package, String query,
          {String? artist, String? title}) =>
      _call<String>('playFromSearch', {
        'package': package,
        'query': query,
        'artist': artist,
        'title': title,
      });

  /// Open one YouTube video in the YouTube app (it starts playing).
  static Future<bool> openYoutubeVideo(String id) async =>
      (await _call<bool>('openYoutubeVideo', {'id': id})) == true;

  // ---- wake word (k1-wake: openWakeWord on ONNX Runtime) --------------------

  /// {state: listening|paused|stopped|error|engine_missing, reason,
  ///  pausedUntil (ms), wanted, level} or null when native is missing.
  static Future<Map<Object?, Object?>?> wakeStatus() =>
      _call<Map<Object?, Object?>>('wakeStatus');

  /// [configJson] = VaWake.nativeConfig(...). 'running' | 'engine_missing' |
  /// 'error:<why>' | null.
  static Future<String?> wakeStart(String configJson) =>
      _call<String>('wakeStart', {'config': configJson});

  static Future<void> wakeStop() => _call<void>('wakeStop');

  static Future<void> wakePause(int minutes) =>
      _call<void>('wakePause', {'minutes': minutes});

  static Future<void> wakeResume() => _call<void>('wakeResume');

  /// True once the native side has stored the user's on/off choice.
  static Future<bool> wakeHasNativeChoice() async =>
      (await _call<bool>('wakeHasNativeChoice')) == true;

  /// Hex sha256 of a local file (model verification), null on failure.
  static Future<String?> sha256(String path) =>
      _call<String>('sha256', {'path': path});

  /// {manufacturer, brand, model, sdk, ignoringBattery}.
  static Future<Map<Object?, Object?>?> deviceInfo() =>
      _call<Map<Object?, Object?>>('deviceInfo');

  /// kind: 'autostart' | 'battery' -> 'oem' | 'generic' | 'none' | null.
  static Future<String?> openOemSettings(String kind) =>
      _call<String>('openOemSettings', {'kind': kind});

  /// Long-press power / side-key setting -> 'oem' | 'generic' | 'none' | null.
  static Future<String?> openPowerKeySettings() =>
      _call<String>('openPowerKeySettings');
}
