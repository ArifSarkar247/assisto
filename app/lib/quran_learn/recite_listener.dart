// quranread: listens once (Arabic speech-to-text) for "I read, check me".
// Lazy: the engine is initialised on the first tap, never at launch. The mic
// is held through AudioRouteService (MicRouteHold) like every other listener.
// Audio is handled by the phone's own speech service; Assisto keeps no
// recording. Every call is guarded - the mic can never crash the lesson.
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../audio/audio_route_service.dart';
import '../widgets/permission_reason.dart';

enum ReciteIssue { none, denied, unavailable, noArabic, noMatch, network, busy, other }

class ReciteListener extends ChangeNotifier {
  ReciteListener({
    SpeechToText? engine,
    Future<bool> Function(BuildContext context)? askReason,
    Future<bool> Function()? micDenied,
  })  : _speech = engine ?? SpeechToText(),
        _askReason = askReason ?? ((c) => showPermissionReason(c, PermKind.mic)),
        _micDenied = micDenied ?? _osMicDenied;

  final SpeechToText _speech;
  final Future<bool> Function(BuildContext context) _askReason;
  final Future<bool> Function() _micDenied;
  final MicRouteHold _mic = MicRouteHold(AudioUse.assistantListen);
  static bool _reasonShown = false;

  bool listening = false;
  bool starting = false;
  String heard = '';
  ReciteIssue issue = ReciteIssue.none;

  /// Called once when a listening session ends with some text.
  VoidCallback? onFinished;
  bool _disposed = false;

  /// The Arabic recogniser locale this phone offers: Saudi first (closest to
  /// Quranic pronunciation in most engines), then Egypt, then any Arabic.
  static String? pickArabic(List<String> locales) {
    String norm(String s) => s.replaceAll('-', '_').toLowerCase();
    for (final want in const ['ar_sa', 'ar_eg', 'ar_ae', 'ar_jo']) {
      for (final l in locales) {
        if (norm(l) == want) return l;
      }
    }
    for (final l in locales) {
      final n = norm(l);
      if (n == 'ar' || n.startsWith('ar_')) return l;
    }
    return null;
  }

  static Future<bool> _osMicDenied() async {
    final st = await Permission.microphone.status;
    return st.isDenied || st.isPermanentlyDenied || st.isRestricted;
  }

  void _set(VoidCallback f) {
    if (_disposed) return;
    f();
    notifyListeners();
  }

  void _onStatus(String s) {
    if (s == 'done' || s == 'notListening') {
      _mic.stop();
      if (listening) {
        _set(() => listening = false);
        if (heard.trim().isNotEmpty) onFinished?.call();
      }
    }
  }

  void _onError(SpeechRecognitionError e) {
    _mic.stop();
    final code = e.errorMsg;
    _set(() {
      listening = false;
      issue = switch (code) {
        'error_no_match' || 'error_speech_timeout' => ReciteIssue.noMatch,
        'error_language_not_supported' ||
        'error_language_unavailable' =>
          ReciteIssue.noArabic,
        'error_network' ||
        'error_network_timeout' ||
        'error_server' ||
        'error_server_disconnected' =>
          ReciteIssue.network,
        'error_permission' || 'error_insufficient_permissions' => ReciteIssue.denied,
        'error_busy' || 'error_recognizer_busy' => ReciteIssue.busy,
        _ => ReciteIssue.other,
      };
    });
  }

  Future<void> start(BuildContext context) async {
    if (listening || starting) return;
    _set(() {
      starting = true;
      heard = '';
      issue = ReciteIssue.none;
    });
    try {
      if (!_speech.isAvailable) {
        if (!_reasonShown) {
          final ok = await _askReason(context);
          if (!ok) return;
          _reasonShown = true;
        }
        final ready =
            await _speech.initialize(onStatus: _onStatus, onError: _onError);
        if (!ready) {
          var denied = false;
          try {
            denied = await _micDenied().timeout(const Duration(seconds: 3));
          } catch (_) {}
          _set(() => issue = denied ? ReciteIssue.denied : ReciteIssue.unavailable);
          return;
        }
      }
      // The engine is a process-wide singleton: claim its callbacks.
      _speech.statusListener = _onStatus;
      _speech.errorListener = _onError;
      List<String> locales = const [];
      try {
        locales = (await _speech.locales()).map((l) => l.localeId).toList();
      } catch (_) {}
      final ar = pickArabic(locales);
      if (ar == null) {
        _set(() => issue = ReciteIssue.noArabic);
        return;
      }
      _set(() => listening = true);
      _mic.start();
      await _speech.listen(
        onResult: (r) => _set(() => heard = r.recognizedWords),
        listenOptions: SpeechListenOptions(
          localeId: ar,
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.dictation,
          listenFor: const Duration(seconds: 45),
          pauseFor: const Duration(seconds: 4),
        ),
      );
    } catch (_) {
      _mic.stop();
      _set(() {
        listening = false;
        issue = ReciteIssue.other;
      });
    } finally {
      _set(() => starting = false);
    }
  }

  Future<void> stop() async {
    try {
      await _speech.stop();
    } catch (_) {}
    _mic.stop();
    if (listening) {
      _set(() => listening = false);
      if (heard.trim().isNotEmpty) onFinished?.call();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _mic.stop();
    try {
      if (listening) _speech.cancel();
      if (_speech.statusListener == _onStatus) {
        _speech.statusListener = null;
        _speech.errorListener = null;
      }
    } catch (_) {}
    super.dispose();
  }
}
