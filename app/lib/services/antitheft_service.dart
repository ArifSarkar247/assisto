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
            // grab-guard: the local "Was this you?" notification texts
            'grabTitle': notif['grabTitle'] ?? '',
            'grabBody': notif['grabBody'] ?? '',
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
            'grabTitle': notif['grabTitle'] ?? '', // grab-guard
            'grabBody': notif['grabBody'] ?? '',
            'deviceId': DeviceId.now(), // own-device
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// grab-guard: a grab detected on THIS phone waits [SnatchPolicy
  /// .confirmWindowMs] for the owner's "Was this you?" before it is sent.
  /// Returns the milliseconds left, or null (nothing pending / error).
  static Future<int?> grabPendingMs() async {
    if (!supported) return null;
    try {
      final v = await _ch.invokeMethod<int>('grabPending');
      return (v == null || v < 0) ? null : v;
    } catch (_) {
      return null;
    }
  }

  /// grab-guard: the owner confirmed (Security PIN verified by the server)
  /// it was him — drop the pending grab. True = it was still pending (never
  /// sent); false = nothing pending / already sent.
  static Future<bool> grabCancel() async {
    if (!supported) return false;
    try {
      return await _ch.invokeMethod<bool>('grabCancel') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// grab-guard: "No, it wasn't me" — send the pending grab right now.
  static Future<void> grabSendNow() async {
    if (!supported) return;
    try {
      await _ch.invokeMethod('grabSendNow');
    } catch (_) {/* ignore */}
  }

  /// Stop the foreground service (called after the server disables protection).
  static Future<void> stop() async {
    if (!supported) return;
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {/* ignore */}
  }

  /// Hand the running engine the owner's new settings (from the server's
  /// settings response). Called only from the open app. Returns false when
  /// the engine is not running or on any error.
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

  /// antitheft2: sha256 of the current Wi-Fi name (for "save my home
  /// Wi-Fi"), or null (not on Wi-Fi, or Android hides the name without the
  /// location permission). Never throws.
  static Future<String?> wifiHash() async {
    if (!supported) return null;
    try {
      final v = await _ch.invokeMethod<String>('wifiHash');
      return (v == null || v.length != 64) ? null : v;
    } catch (_) {
      return null;
    }
  }

  /// at100: a wrong Security PIN was typed in the OPEN app and the server
  /// said `intruder_snap` -> the engine takes ONE front photo now (shutter
  /// sound; only works while Assisto is on screen). False = not possible
  /// (engine off, option off, no camera / permission). Never throws.
  static Future<bool> intruderSnap() async {
    if (!supported) return false;
    try {
      return await _ch.invokeMethod<bool>('intruderSnap') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// at100: is a remote alarm ringing on THIS phone right now?
  static Future<bool> alarmPlaying() async {
    if (!supported) return false;
    try {
      return await _ch.invokeMethod<bool>('alarmPlaying') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// at100: stop the remote alarm on THIS phone (the owner found it).
  static Future<bool> alarmStop() async {
    if (!supported) return false;
    try {
      return await _ch.invokeMethod<bool>('alarmStop') ?? false;
    } catch (_) {
      return false;
    }
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
