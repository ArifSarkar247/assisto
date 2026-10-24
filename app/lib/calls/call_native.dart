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
        if (call.method == 'networkChanged') {
          final c = _net;
          if (c != null && !c.isClosed) c.add('${call.arguments ?? 'other'}');
        }
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

  /// play-fsi: may incoming calls show full-screen? (Android 14+ asks the
  /// user; older Android: always true. Errors count as true — never nag.)
  static Future<bool> canFullScreen() async {
    _ensureHandler();
    final v = await _invoke<bool>('canFullScreen');
    return v ?? true;
  }

  /// Opens Settings -> Assisto -> Full screen notifications.
  static Future<bool> openFullScreenSettings() async {
    _ensureHandler();
    return await _invoke<bool>('openFullScreenSettings') == true;
  }

  static Future<bool> pipSupported() async {
    _ensureHandler();
    return await _invoke<bool>('pipSupported') == true;
  }

  static Future<bool> enterPip({int w = 9, int h = 16}) async {
    _ensureHandler();
    return await _invoke<bool>('enterPip', {'w': w, 'h': h}) == true;
  }

  static bool _autoPip = false;

  static StreamController<String>? _net;

  /// calls-presence: the phone's DEFAULT network changed during a call
  /// ('wifi' | 'cellular' | 'other') or was lost ('lost'). The native
  /// ConnectivityManager callback exists only while someone listens (one
  /// call screen); without the native side the stream is simply silent.
  /// ACCESS_NETWORK_STATE is already in the manifest (no new permission).
  static Stream<String> networkChanges() {
    final c = _net ??= StreamController<String>.broadcast(
      onListen: () {
        _ensureHandler();
        unawaited(_invoke<bool>('watchNetwork', {'on': true}));
      },
      onCancel: () {
        unawaited(_invoke<bool>('watchNetwork', {'on': false}));
      },
    );
    return c.stream;
  }

  /// b1-calls: Home / the recents gesture shrinks a LIVE video call into
  /// picture-in-picture (API 31+ auto-enter; 26-30 user-leave hint). Only
  /// changes the native side when the wanted state changes.
  static Future<bool> setAutoPip(bool on, {int w = 9, int h = 16}) async {
    if (on == _autoPip) return on;
    _autoPip = on;
    _ensureHandler();
    return await _invoke<bool>('setAutoPip', {'on': on, 'w': w, 'h': h}) ==
        true;
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
