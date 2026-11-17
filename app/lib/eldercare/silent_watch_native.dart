import 'package:flutter/services.dart';

/// fcelder — the Silent Watch native side (android_overlay/.../silentwatch/
/// SilentWatch.kt) behind an interface so tests use a fake. Every call is
/// crash-guarded: an older build / iOS / a failure answers false / null.
abstract class SilentWatchNative {
  Future<bool> arm(Map<String, dynamic> args);
  Future<bool> disarm();
  Future<bool> noteActivity();
  Future<bool> ok();

  /// "I am going out" (phone left at home) for [minutes]: no "Are you OK?"
  /// until then + 30 min; any later sign of life ends the pause.
  Future<bool> goingOut(int minutes);

  /// {enabled, stage (0 = quiet, 1..3 = ringing), told, last_ms,
  ///  ring_at_ms, log: [epoch minutes], told_log: [epoch minutes],
  ///  away_until_ms} or null.
  Future<Map<String, dynamic>?> state();
}

class ChannelSilentWatchNative implements SilentWatchNative {
  static const MethodChannel _ch = MethodChannel('com.assisto/silent_watch');

  Future<T?> _call<T>(String m, [Object? a]) async {
    try {
      return await _ch.invokeMethod<T>(m, a);
    } catch (_) {
      return null; // no native side (older build / tests / iOS)
    }
  }

  @override
  Future<bool> arm(Map<String, dynamic> args) async => await _call<bool>('arm', args) ?? false;

  @override
  Future<bool> disarm() async => await _call<bool>('disarm') ?? false;

  @override
  Future<bool> noteActivity() async => await _call<bool>('noteActivity') ?? false;

  @override
  Future<bool> ok() async => await _call<bool>('ok') ?? false;

  @override
  Future<bool> goingOut(int minutes) async => await _call<bool>('goingOut', minutes) ?? false;

  @override
  Future<Map<String, dynamic>?> state() async {
    final m = await _call<Map<dynamic, dynamic>>('state');
    return m == null ? null : m.map((k, v) => MapEntry('$k', v));
  }
}
