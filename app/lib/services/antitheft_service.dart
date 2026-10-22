import 'dart:io' show Platform;

import 'package:flutter/services.dart';

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

  static bool get supported => Platform.isAndroid;

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
    required Map<String, String> notif, // {title, body}
  }) async {
    if (!supported) return false;
    try {
      return await _ch.invokeMethod<bool>('start', {
            'engineToken': engineToken,
            'apiBase': apiBase,
            'config': config,
            'notifTitle': notif['title'] ?? 'Protection on',
            'notifBody': notif['body'] ?? '',
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

  /// Ask the engine to try an immediate heartbeat + flush its queue now (e.g.
  /// right after enabling, or on app resume). Best-effort; never throws.
  static Future<void> flushNow() async {
    if (!supported) return;
    try {
      await _ch.invokeMethod('flush');
    } catch (_) {/* ignore */}
  }
}
