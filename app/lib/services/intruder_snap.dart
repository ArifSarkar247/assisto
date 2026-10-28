import 'dart:async' show unawaited;

import '../state.dart' show Settings;
import 'antitheft_service.dart';

/// at100 — the intruder photo, OPEN-APP ONLY.
///
/// The owner turns it on from a full consent screen (OFF by default). Then,
/// when a wrong Security PIN is typed INSIDE Assisto (the "Are you OK?"
/// check after a grab, switching protection off, a Section-8 action...), the
/// server answers `intruder_snap: true` once the owner's threshold of wrong
/// attempts in a row is reached, and the app asks the engine for ONE front
/// photo — with the system shutter sound and Android's camera dot. Never in
/// the background, never on the lock screen, never covert: every PIN dialog
/// shows a visible line saying so while it is on ([armed]).
class IntruderSnap {
  IntruderSnap._();

  static const _kOn = 'at_intruder_on';
  static bool _armed = false;
  static bool _loaded = false;
  static bool _hadOn = false;

  /// Test seam: set the cached state without touching storage.
  static void debugSetArmed(bool on) {
    _armed = on;
    _loaded = true;
  }

  /// Test seam: replaces the native call.
  static Future<bool> Function()? snapOverride;

  /// Is the (consented) intruder photo on for this phone? Drives the visible
  /// notice on PIN dialogs. Cached; [load] refreshes it.
  static bool get armed => _armed;

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      _armed = await Settings.getBool(_kOn, false);
      _hadOn = _armed;
    } catch (_) {}
  }

  /// Remember the server's answer (engine state / settings response).
  static Future<void> remember(bool on) async {
    final changed = on != _armed || !_loaded;
    _armed = on;
    _loaded = true;
    // persist only a real change (an "off" that was already off writes
    // nothing — keeps screen loads free of storage work)
    if (!changed || (!on && !_hadOn)) return;
    _hadOn = on;
    try {
      await Settings.setBool(_kOn, on);
    } catch (_) {}
  }

  /// After a PIN-gated server answer: take the photo when the server says so.
  /// Never throws, never blocks the caller's UI (fire-and-forget).
  static bool after(Map<String, dynamic>? resp) {
    if (resp == null || resp['intruder_snap'] != true) return false;
    final f = snapOverride ?? AntiTheftService.intruderSnap;
    unawaited(f().catchError((_) => false));
    return true;
  }
}
