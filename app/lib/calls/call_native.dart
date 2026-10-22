import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'call_controller.dart';
import 'tone_generator.dart';
import 'call_log.dart';

/// Dart side of the native "com.assisto/calls" channel (CallsChannel.kt).
/// Every call is guarded: without the native side (tests, iOS, an old build)
/// it quietly answers false/null — never throws into the UI.
class CallNative {
  CallNative._();
  static const _ch = MethodChannel('com.assisto/calls');
  static bool _handlerSet = false;

  /// true while the activity is in picture-in-picture.
  static final ValueNotifier<bool> inPip = ValueNotifier<bool>(false);

  static void _ensureHandler() {
    if (_handlerSet) return;
    _handlerSet = true;
    try {
      _ch.setMethodCallHandler((call) async {
        if (call.method == 'pipChanged') inPip.value = call.arguments == true;
        return null;
      });
    } catch (e) {
      callLog('call_native#1', e);
    }
  }

  static Future<T?> _invoke<T>(String m, [Map<String, dynamic>? a]) async {
    try {
      return await _ch.invokeMethod<T>(m, a);
    } catch (_) {
      return null;
    }
  }

  static Future<bool> playTone(ToneSpec t) async =>
      await _invoke<bool>(
          'playTone', {'pcm': t.bytes, 'rate': t.sampleRate, 'loop': t.loop}) ==
      true;

  static Future<void> stopTone() => _invoke<bool>('stopTone');

  /// 'ring' | 'vibrate' | 'silent' | 'error' (null = no native side).
  static Future<String?> startRingtone(String? uri) =>
      _invoke<String>('startRingtone', {'uri': uri});

  static Future<void> stopRingtone() => _invoke<bool>('stopRingtone');

  /// Opens the phone's own sound picker. null = cancelled;
  /// {'uri': null} = "Silent"; uri '' never happens.
  static Future<Map<String, dynamic>?> pickSound(
      {required bool notification, String? current}) async {
    final r = await _invoke<Map<dynamic, dynamic>>('pickSound', {
      'type': notification ? 'notification' : 'ringtone',
      'current': current,
    });
    return r?.cast<String, dynamic>();
  }

  static Future<String> soundTitle(String? uri) async =>
      await _invoke<String>('soundTitle', {'uri': uri}) ?? '';

  /// Android 10+: install the generated Assisto melody as a phone ringtone
  /// (so the locked-screen ring can use it). Returns its content uri.
  static Future<String?> installRingtone(Uint8List wav, String name) =>
      _invoke<String>('installRingtone', {'wav': wav, 'name': name});

  static Future<bool> setProximity(bool on) async =>
      await _invoke<bool>('setProximity', {'on': on}) == true;

  /// Keep the screen on during a video call (FLAG_KEEP_SCREEN_ON).
  static Future<void> keepScreenOn(bool on) =>
      _invoke<bool>('keepScreenOn', {'on': on});

  static Future<bool> pipSupported() async {
    _ensureHandler();
    return await _invoke<bool>('pipSupported') == true;
  }

  static Future<bool> enterPip({int w = 9, int h = 16}) async {
    _ensureHandler();
    return await _invoke<bool>('enterPip', {'w': w, 'h': h}) == true;
  }
}

/// [CallSounds] for the app: generated tones through the native AudioTrack.
class NativeCallSounds implements CallSounds {
  ToneSpec? _ringback;

  @override
  Future<void> startRingback() async {
    _ringback ??= ToneGenerator.ringback();
    await CallNative.playTone(_ringback!);
  }

  @override
  Future<void> stopRingback() => CallNative.stopTone();

  Future<void> _once(ToneSpec t) async {
    await CallNative.playTone(t);
    // let it finish, but never block the UI longer than the tone
    await Future<void>.delayed(t.duration);
    await CallNative.stopTone();
  }

  @override
  Future<void> playBusy() => _once(ToneGenerator.busy());
  @override
  Future<void> playDeclined() => _once(ToneGenerator.declined());
  @override
  Future<void> playEnded() => _once(ToneGenerator.ended());

  @override
  Future<void> stopAll() async {
    await CallNative.stopTone();
    await CallNative.stopRingtone();
  }

  @override
  Future<void> setProximity(bool on) async {
    await CallNative.setProximity(on);
  }
}
