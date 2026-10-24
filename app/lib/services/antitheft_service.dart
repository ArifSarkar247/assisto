import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../device_id.dart';

/// b6-antitheft — Dart bridge to the native always-on Lost/Stolen engine.
///
/// Channel: "com.assisto/antitheft" (see
/// android_overlay/.../antitheft/AntiTheftChannel.kt). EVERY call is wrapped so
/// a missing plugin or a native error can NEVER crash the app; the engine is
/// Android-only and entirely opt-in. Nothing here runs at app launch — the UI
/// calls [start] only after the user enables protection and the server returns
/// the engine token.
class AntiTheftService {
  static const _ch = MethodChannel('com.assisto/antitheft');

  // Android (and host tests) use the channel; a real iPhone has no engine.
  static bool get supported => !Platform.isIOS;

  /// What the phone can ACTUALLY do (honest UI). Keys the native side fills:
  ///   sdk (int), brand (String), canReadSim (bool), canReadSimNumber (bool),
  ///   canCamera (bool), canBackgroundLocation (bool), batteryOptimised (bool).
  /// Returns {} on any error — the UI then shows a cautious "unknown" state.
  static Future<Map<String, dynamic>> capabilities() async {
    if (!supported) return const {};
    try {
      final r = await _ch.invokeMethod<Map>('capabilities');
      return r == null ? const {} : Map<String, dynamic>.from(r);
    } catch (_) {
      return const {};
    }
  }

  /// Is the opt-in foreground service running right now (native truth)?
  static Future<bool> isRunning() async {
    if (!supported) return false;
    try {
      return await _ch.invokeMethod<bool>('isRunning') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Start the foreground service with the scoped engine token + config.
  /// The service shows a persistent notification the whole time it runs
  /// (Android requires it for a foreground service, and it is the honest thing
  /// to do). Returns false on any failure — the caller re-reads [isRunning].
  static Future<bool> start({
    required String engineToken,
    required String apiBase,
    required Map<String, dynamic> config,
    required Map<String, String> notif, // {title, body, off, resumeTitle, resumeBody}
    // at-falsealarm: true ONLY when the owner just switched protection on —
    // the SIM(s) in the phone now become the silent baseline. A relaunch
    // re-arm never passes it (it compares to the stored baseline).
    bool rebaseline = false,
  }) async {
    if (!supported) return false;
    try {
      return await _ch.invokeMethod<bool>('start', {
            'engineToken': engineToken,
            'apiBase': apiBase,
            'config': config,
            'notifTitle': notif['title'] ?? 'Protection on',
            'notifBody': notif['body'] ?? '',
            'notifOff': notif['off'] ?? 'Turn off', // play-fgs
            // at-heartbeat: "protection paused, tap to resume" texts
            'resumeTitle': notif['resumeTitle'] ?? '',
            'resumeBody': notif['resumeBody'] ?? '',
            'rebaseline': rebaseline,
            // own-device: the engine sends the app's id with its ingest
            'deviceId': DeviceId.now(),
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// at-heartbeat: the app was opened / resumed. If protection is ON (the
  /// native engine still holds its scoped token) the engine is started again
  /// with that token and `rebaseline: false` — the SIM baseline recorded at
  /// switch-on is compared, never re-recorded — or, if it is already running,
  /// asked for an immediate check-in. Protection off -> false, nothing runs.
  /// [notif] = {title, body, off, resumeTitle, resumeBody}. Never throws.
  static Future<bool> resume({required Map<String, String> notif}) async {
    if (!supported) return false;
    try {
      return await _ch.invokeMethod<bool>('resume', {
            'notifTitle': notif['title'] ?? '',
            'notifBody': notif['body'] ?? '',
            'notifOff': notif['off'] ?? '',
            'resumeTitle': notif['resumeTitle'] ?? '',
            'resumeBody': notif['resumeBody'] ?? '',
            'deviceId': DeviceId.now(), // own-device
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Stop the foreground service (called after the server disables protection).
  static Future<void> stop() async {
    if (!supported) return;
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {/* ignore */}
  }

  /// Hand the running engine the owner's new settings (from the server's
  /// settings response). Called only from the open app, so the engine may
  /// re-declare its foreground types (e.g. add CAMERA for the opt-in intruder
  /// photo). Returns false when the engine is not running or on any error.
  static Future<bool> configure(Map<String, dynamic> config) async {
    if (!supported) return false;
    try {
      return await _ch.invokeMethod<bool>('configure', {'config': config}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// at-falsealarm: the owner is on the protection screen (handling his own
  /// phone) — the engine pauses snatch detection while [on]. Native side caps
  /// it at 15 minutes in case "off" is never sent. Never throws.
  static Future<void> setQuiet(bool on) async {
    if (!supported) return;
    try {
      await _ch.invokeMethod('setQuiet', {'on': on});
    } catch (_) {/* ignore */}
  }

  /// Ask the engine to try an immediate heartbeat + flush its queue now (e.g.
  /// right after enabling, or on app resume). Best-effort; never throws.
  static Future<void> flushNow() async {
    if (!supported) return;
    try {
      await _ch.invokeMethod('flush');
    } catch (_) {/* ignore */}
  }
}
