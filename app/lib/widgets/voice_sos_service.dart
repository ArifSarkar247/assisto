import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:geolocator/geolocator.dart';

import '../state.dart';
import 'voice_sos_config.dart';
import 'journey_api.dart';

/// Hands-free Voice SOS foreground service (feature #79).
///
/// Architecture (honest + no duplicated SOS):
///   - [VoiceSosTaskHandler] runs in the foreground-service isolate. It keeps
///     the on-device `speech_to_text` engine listening (restarting it when the
///     platform ends a session) and, when the chosen wake phrase is heard, it
///     calls `FlutterForegroundTask.sendDataToMain('fire')`.
///   - [VoiceSosManager] runs in the MAIN isolate (it holds the authenticated
///     ApiClient + AppState). It listens for that 'fire' signal and runs the
///     EXISTING SOS action — the same `api.journeySos(...)` + GPS path the
///     manual SOS button uses. The service isolate never has the auth token and
///     never sends an alert itself; it only wakes the app.
///
/// Why a foreground service: Android requires a persistent notification for any
/// always-listening microphone work, and it is the honest thing to do — the
/// user can always see (and stop) that Assisto is listening. Battery: always
/// listening uses battery; this is OFF by default and the UI says so.
///
/// Privacy: speech is transcribed on-device; Assisto uploads nothing but the
/// final SOS alert (same as manual SOS).

const int kVoiceSosServiceId = 7900;

/// Signals the service isolate sends to the main isolate.
const String kVoiceSosFire = 'voice_sos_fire';
const String kVoiceSosUnavailable = 'voice_sos_unavailable';
const String kVoiceSosListening = 'voice_sos_listening';

/// Top-level entry point for the foreground task isolate. MUST be top-level and
/// annotated so it is not tree-shaken in release builds.
@pragma('vm:entry-point')
void voiceSosStartCallback() {
  FlutterForegroundTask.setTaskHandler(VoiceSosTaskHandler());
}

class VoiceSosTaskHandler extends TaskHandler {
  final SpeechToText _speech = SpeechToText();
  bool _ready = false;
  bool _firedOnce = false;
  String _phrase = VoiceSosConfig.defaultPhrases.first;
  // Recognise in the app's ACTIVE language. Without this the plugin defaults to
  // the DEVICE locale, so a Bangla wake phrase on a non-Bengali device is never
  // transcribed and SOS never fires. Derived from the persisted app locale.
  String _localeId = 'en_US';
  DateTime _lastRestart = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _phrase = await VoiceSosConfig.phrase();
    _localeId = await VoiceSosConfig.speechLocaleId();
    try {
      _ready = await _speech.initialize(
        onStatus: (status) {
          // The engine stops itself after silence; keep it alive.
          if (status == 'done' || status == 'notListening') {
            _restartListening();
          }
        },
        onError: (_) => _restartListening(),
        debugLogging: false,
      );
    } catch (_) {
      _ready = false;
    }
    if (!_ready) {
      // Honest: no on-device engine -> tell the UI, do not pretend to listen.
      FlutterForegroundTask.sendDataToMain(kVoiceSosUnavailable);
      return;
    }
    FlutterForegroundTask.sendDataToMain(kVoiceSosListening);
    _startListening();
  }

  void _startListening() {
    if (!_ready) return;
    try {
      _speech.listen(
        onResult: (r) {
          final heard = r.recognizedWords;
          if (VoiceSosConfig.matches(heard, _phrase)) {
            _fire();
          }
        },
        // Continuous dictation so we see partials and never miss the phrase.
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: false,
          listenMode: ListenMode.dictation,
          listenFor: const Duration(minutes: 5),
          pauseFor: const Duration(seconds: 3),
          localeId: _localeId,
        ),
      );
    } catch (_) {
      _restartListening();
    }
  }

  void _restartListening() {
    // Debounce restarts so a flapping engine does not spin the CPU/battery.
    final now = DateTime.now();
    if (now.difference(_lastRestart) < const Duration(milliseconds: 800)) {
      return;
    }
    _lastRestart = now;
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      if (!_speech.isListening) _startListening();
    });
  }

  void _fire() {
    if (_firedOnce) return; // the main isolate runs the cancellable countdown
    _firedOnce = true;
    try {
      _speech.stop();
    } catch (_) {}
    FlutterForegroundTask.sendDataToMain(kVoiceSosFire);
    // Allow re-arming after a short window (in case the user cancels the SOS).
    Future<void>.delayed(const Duration(seconds: 20), () {
      _firedOnce = false;
      _restartListening();
    });
  }

  @override
  void onReceiveData(Object data) {
    // The main isolate can push an updated wake phrase without a restart.
    if (data is String && data.startsWith('phrase:')) {
      _phrase = data.substring('phrase:'.length);
    }
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    // Heartbeat: if the recogniser has silently died, revive it.
    if (_ready && !_speech.isListening && !_firedOnce) _startListening();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    try {
      await _speech.stop();
      await _speech.cancel();
    } catch (_) {}
  }
}

/// Main-isolate manager: initialises the service config, starts/stops it, and
/// (critically) wires the service's 'fire' signal to the EXISTING SOS action.
class VoiceSosManager {
  VoiceSosManager._();
  static final VoiceSosManager instance = VoiceSosManager._();

  AppState? _app;
  bool _wired = false;
  bool _firing = false;

  /// Callbacks the host screen can observe for honest UI state.
  VoidCallback? onUnavailable;
  VoidCallback? onListening;

  /// Called once near app start AND whenever the service is (re)started so the
  /// manager can fire SOS using the live, authenticated AppState.
  void attach(AppState app) {
    _app = app;
    if (_wired) return;
    FlutterForegroundTask.addTaskDataCallback(_onData);
    _wired = true;
  }

  void _onData(Object data) {
    if (data == kVoiceSosFire) {
      _fireSos();
    } else if (data == kVoiceSosUnavailable) {
      onUnavailable?.call();
    } else if (data == kVoiceSosListening) {
      onListening?.call();
    }
  }

  /// Fire the SAME SOS as the manual path: GPS fix (best-effort) + the existing
  /// `api.journeySos(...)` alert to the circle/family. This is the single
  /// shared action — we do NOT build a second SOS.
  Future<void> _fireSos() async {
    if (_firing) return;
    final app = _app;
    if (app == null) return;
    _firing = true;
    try {
      double? lat;
      double? lng;
      try {
        if (await Geolocator.isLocationServiceEnabled()) {
          var perm = await Geolocator.checkPermission();
          if (perm == LocationPermission.denied) {
            perm = await Geolocator.requestPermission();
          }
          if (perm != LocationPermission.denied &&
              perm != LocationPermission.deniedForever) {
            final pos = await Geolocator.getCurrentPosition();
            lat = pos.latitude;
            lng = pos.longitude;
          }
        }
      } catch (_) {}
      try {
        await app.api.journeySos(lat: lat, lng: lng, siren: true);
      } catch (_) {
        // Offline: the server-side queue/retry handles delivery; the service
        // keeps running. Nothing to surface from the background.
      }
    } finally {
      _firing = false;
    }
  }

  /// One-time plugin init (notification channel + task options). Safe to call
  /// repeatedly.
  Future<void> init(
    String channelName,
    String channelDesc,
    String notifTitle,
    String notifText,
  ) async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'assisto_voice_sos',
        channelName: channelName,
        channelDescription: channelDesc,
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(15000),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  Future<bool> isRunning() => FlutterForegroundTask.isRunningService;

  /// Start the always-listening service. Returns false if the OS refused.
  Future<bool> start(String notifTitle, String notifText) async {
    try {
      if (await FlutterForegroundTask.isRunningService) return true;
      final r = await FlutterForegroundTask.startService(
        serviceId: kVoiceSosServiceId,
        serviceTypes: const [
          ForegroundServiceTypes.microphone,
          ForegroundServiceTypes.location,
        ],
        notificationTitle: notifTitle,
        notificationText: notifText,
        callback: voiceSosStartCallback,
      );
      return r is ServiceRequestSuccess;
    } catch (e) {
      if (kDebugMode) print('voice sos start failed: $e');
      return false;
    }
  }

  Future<void> stop() async {
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}
  }

  /// Push an updated wake phrase to a running service without restarting it.
  void updatePhrase(String phrase) {
    FlutterForegroundTask.sendDataToTask('phrase:$phrase');
  }
}
