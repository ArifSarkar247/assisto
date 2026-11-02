import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'call_controller.dart';
import 'call_pip.dart';
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

  /// calls-a: a warm call launch from MainActivity.onNewIntent
  /// ({action, call_id, payload}); main.dart points it at CallLaunchRouter.
  static void Function(Map<dynamic, dynamic>? args)? onCallLaunch;

  /// callpip: a button inside the PiP window ('mute' | 'camera' | 'end').
  static void Function(String id)? onPipAction;

  /// callpip: "Return to call" on the ongoing-call notification.
  static void Function()? onCallReturn;

  /// calls-a: install the Dart-side handler (no native call — safe before
  /// the first frame) so a warm call launch is never dropped.
  static void listen() => _ensureHandler();

  static void _ensureHandler() {
    if (_handlerSet) return;
    _handlerSet = true;
    try {
      _ch.setMethodCallHandler((call) async {
        if (call.method == 'pipChanged') inPip.value = call.arguments == true;
        if (call.method == 'callLaunch') {
          final a = call.arguments;
          try {
            onCallLaunch?.call(a is Map ? a : null);
          } catch (e) {
            callLog('call_native#2', e);
          }
        }
        if (call.method == 'pipAction') {
          try {
            onPipAction?.call('${call.arguments ?? ''}');
          } catch (e) {
            callLog('call_native#3', e);
          }
        }
        if (call.method == 'callReturn') {
          try {
            onCallReturn?.call();
          } catch (e) {
            callLog('call_native#4', e);
          }
        }
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

  // ---- ring-everywhere (IncomingCall.kt / CallAck.kt / TelecomBridge.kt) ----

  /// The API base + app version the NATIVE ring needs for its delivered /
  /// ringing / decline ack (no token: the push carries a per-call signature).
  static Future<void> setNativeConfig(String apiBase, String appVersion) =>
      _invoke<bool>('setNativeConfig',
          {'api_base': apiBase, 'app_version': appVersion});

  /// calls-a: is the native ring notification for [callId] still posted?
  /// null = can't tell (no native side / no activity yet).
  static Future<bool?> ringActive(String callId) =>
      _invoke<bool>('ringActive', {'call_id': callId});

  /// Stop the native ring + its Telecom call for [callId] (idempotent).
  static Future<void> cancelRing(String callId) =>
      _invoke<bool>('cancelRing', {'call_id': callId});

  /// Telecom self-managed call: mark it active / end it.
  static Future<bool> telecomActive(String callId) async =>
      await _invoke<bool>('telecomActive', {'call_id': callId}) == true;
  static Future<bool> telecomEnd(String callId) async =>
      await _invoke<bool>('telecomEnd', {'call_id': callId}) == true;

  /// Notifications on AND the ringing call channel not switched off?
  /// null = Android can't tell us right now.
  static Future<bool?> callChannelOk() => _invoke<bool>('callChannelOk');

  /// {brand, manufacturer, model, sdk_int} (no PII) or null.
  static Future<Map<String, Object?>?> deviceFacts() async {
    final m = await _invoke<Map<dynamic, dynamic>>('deviceFacts');
    return m?.map((k, v) => MapEntry('$k', v as Object?));
  }

  /// CI smoke build ONLY (ASSISTO_SMOKE): arm the adb ring-test hook.
  static Future<bool> armRingTest() async =>
      await _invoke<bool>('armRingTest') == true;

  static Future<bool> pipSupported() async {
    _ensureHandler();
    return await _invoke<bool>('pipSupported') == true;
  }

  static Future<bool> enterPip({int w = 9, int h = 16}) async {
    _ensureHandler();
    return await _invoke<bool>('enterPip', {'w': w, 'h': h}) == true;
  }

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
  static Future<bool> setAutoPip(bool on, {int w = 9, int h = 16}) =>
      setPip(on
          ? PipState(auto: true, aspect: PipAspect(w, h), actions: const [])
          : PipState.off);

  static String? _pipSig;

  /// callpip: the whole PiP state (auto-enter, shape, the window's buttons
  /// with their labels) — sent only when it changed.
  static Future<bool> setPip(PipState st, {Map<String, String>? labels}) async {
    final sig = st.signature;
    if (sig == _pipSig) return st.auto;
    _pipSig = sig;
    _ensureHandler();
    return await _invoke<bool>('setAutoPip', {
          'on': st.auto,
          'w': st.aspect.w,
          'h': st.aspect.h,
          'actions': [
            for (final a in st.actions)
              {
                'id': a.id.name,
                'on': a.on,
                'label': labels?['${a.id.name}:${a.on ? 1 : 0}'] ?? a.id.name,
              }
          ],
        }) ==
        true;
  }

  @visibleForTesting
  static void resetPipForTest() => _pipSig = null;

  /// callpip: picture-in-picture switched ON for Assisto? (some phones
  /// ship it off). null = no PiP on this phone / unknown -> no hint.
  static Future<bool?> pipAllowed() async {
    _ensureHandler();
    return _invoke<bool>('pipAllowed');
  }

  /// callpip: opens Assisto's picture-in-picture switch in Settings.
  static Future<bool> openPipSettings() async {
    _ensureHandler();
    return await _invoke<bool>('openPipSettings') == true;
  }

  /// callpip: Back on Assisto's LAST screen during a call. [pip] = shrink
  /// the live video call into PiP; otherwise (or when PiP is not possible)
  /// Assisto goes to the background — never closes, the call keeps running.
  static Future<bool> leaveApp({required bool pip}) async {
    _ensureHandler();
    return await _invoke<bool>('leaveApp', {'pip': pip}) == true;
  }

  /// callpip: the ongoing-call notification gets "Return to call" (opens
  /// Assisto directly — a notification action, no background launch) and
  /// "End call". [since] = when the call connected (the notification's
  /// timer). Only for OUR keep-alive notification ([CallKeepAlive.serviceId]).
  static Future<bool> decorateOngoing({
    required int id,
    required String channelId,
    required String title,
    required String text,
    required String returnLabel,
    required String endLabel,
    required String endButtonId,
    DateTime? since,
  }) async {
    _ensureHandler();
    return await _invoke<bool>('decorateOngoing', {
          'id': id,
          'channel': channelId,
          'title': title,
          'text': text,
          'return': returnLabel,
          'end': endLabel,
          'endId': endButtonId,
          if (since != null) 'since': since.millisecondsSinceEpoch,
        }) ==
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
