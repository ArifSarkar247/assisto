import 'dart:async';

import 'package:flutter/foundation.dart';

/// gap-sos (P0): an SOS that could not reach the server keeps trying even
/// after its screen is closed.
///
/// Before: the Emergency hub's SOS gave up at once when offline (only the
/// SMS step was left — if the user did not send the SMS, the family never
/// knew, even after the internet came back), and the family SOS screen
/// stopped retrying the moment the user pressed Back. Now ONE app-wide retry
/// owns the unsent press: same press id every time (the server makes a
/// retry idempotent, so the family is never rung twice), every [every]
/// until it goes through or [maxTries] (about 30 minutes at 15 s), or the
/// user taps "Stop trying". A newer SOS press replaces an older pending one.
/// Lives only while the app process lives (no WorkManager / background
/// service — the lock-screen SOS keeps its own native queue).
class SosRetry {
  SosRetry._();

  static Timer? _timer;
  static String? _clientId;
  static Future<Map<String, dynamic>> Function()? _send;
  static void Function(Map<String, dynamic> result)? _onSent;
  static int _tries = 0;
  static bool _busy = false;

  /// 15 s x 120 = 30 minutes of trying.
  static const maxTries = 120;

  /// True while an unsent SOS is being retried (screens show "still trying").
  static final ValueNotifier<bool> trying = ValueNotifier<bool>(false);

  static bool get active => _timer != null;
  static String? get clientId => _clientId;

  /// Start retrying [send] (which must re-use the SAME press id).
  static void start({
    required String clientId,
    required Future<Map<String, dynamic>> Function() send,
    Duration every = const Duration(seconds: 15),
    void Function(Map<String, dynamic> result)? onSent,
  }) {
    stop();
    _clientId = clientId;
    _send = send;
    _onSent = onSent;
    _tries = 0;
    _timer = Timer.periodic(every, (_) => _tick());
    trying.value = true;
  }

  static Future<void> _tick() async {
    final send = _send;
    final id = _clientId;
    if (_busy || send == null) return;
    _busy = true;
    try {
      final r = await send().timeout(const Duration(seconds: 10));
      if (_clientId != id) return; // stopped or replaced meanwhile
      final cb = _onSent;
      stop();
      try {
        cb?.call(r);
      } catch (_) {/* best-effort: the screen that asked may be gone */}
    } catch (_) {
      if (_clientId == id && ++_tries >= maxTries) stop();
    } finally {
      _busy = false;
    }
  }

  /// The user tapped "Stop trying" (or a test cleans up).
  static void stop() {
    _timer?.cancel();
    _timer = null;
    _clientId = null;
    _send = null;
    _onSent = null;
    _tries = 0;
    trying.value = false;
  }
}
