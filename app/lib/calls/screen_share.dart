import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'call_controller.dart';
import 'call_log.dart';
import 'media_ext.dart';

/// circle-screenshare: screen sharing in a My Circle video call — the state
/// machine (pure Dart, unit-tested with fakes).
///
///   idle --request--> consent (OUR sheet: the other person sees everything
///     on the screen, incl. notifications; Stop any time)
///   consent --cancel--> idle
///   consent --confirm--> starting: the SYSTEM consent dialog, then the
///     mediaProjection foreground service (Android 14+: only after consent),
///     then the screen goes on the call's video sender
///   starting --> sharing (red "You're sharing your screen · Stop" bar, the
///     notification's Stop, the system "Stop sharing" chip) | idle + notice
///   sharing --stop (bar, notification, system, call ended, back to voice)-->
///     idle (the camera comes back when it was on)
///
/// ONE controller per call ([ScreenShareController.of]): it outlives the
/// call screen (minimize to the mini bar, PiP) and stops by itself when the
/// call ends or leaves video mode — sharing never keeps running alone.
enum ScreenShareState { idle, consent, starting, sharing }

/// The honest one-line result shown after a start / stop that the user did
/// not do on the call screen.
enum ScreenShareNotice {
  none,
  denied,
  failed,
  stoppedBySystem,
}

/// The native side ("com.assisto/screenshare"): the mediaProjection
/// foreground service. A fake in tests.
abstract class ScreenShareService {
  Future<bool> start(
      {required String title, required String body, required String stop});
  Future<void> stop();

  /// The service is in this build's manifest (false on a Play build until
  /// the media-projection declaration is filed).
  Future<bool> available();

  /// 'user' = the notification's "Stop sharing"; 'system' = Android ended
  /// the projection (status-bar chip, screen lock, another app took it).
  Stream<String> get stopRequests;
}

class ScreenShareController extends ChangeNotifier {
  ScreenShareController({
    required this.call,
    required this.service,
  }) {
    _buildCheck = _checkBuild();
    _stopSub = service.stopRequests.listen((why) {
      log.add('stop-request:$why');
      unawaited(stop(system: why == 'system'));
    });
    call.addListener(_onCall);
  }

  static final Expando<ScreenShareController> _byCall =
      Expando<ScreenShareController>('screen-share');

  /// Test seam: the service the next [of] uses (null = the real one).
  @visibleForTesting
  static ScreenShareService? serviceOverride;

  /// The ONE controller of [call] (created on first use; null when the
  /// call's media cannot share — fakes, the broken-WebRTC fallback).
  static ScreenShareController? of(CallController call) {
    if (call.media is! ScreenShareMedia) return null;
    final have = _byCall[call];
    if (have != null && !have._disposed) return have;
    final c = ScreenShareController(
        call: call, service: serviceOverride ?? NativeScreenShareService());
    _byCall[call] = c;
    return c;
  }

  final CallController call;
  final ScreenShareService service;

  /// (title, body, stop) for the foreground-service notification, in the
  /// app's language — set by the call screen.
  (String, String, String) Function() texts = () =>
      ('Sharing your screen', '', 'Stop sharing');

  ScreenShareState state = ScreenShareState.idle;
  ScreenShareNotice notice = ScreenShareNotice.none;
  int noticeSeq = 0;
  final List<String> log = [];
  StreamSubscription<String>? _stopSub;
  bool _disposed = false;
  bool _serviceOn = false;

  ScreenShareMedia? get _media {
    final m = call.media;
    return m is ScreenShareMedia ? m as ScreenShareMedia : null;
  }

  bool get sharing => state == ScreenShareState.sharing;
  bool get busy => state == ScreenShareState.starting;

  /// The share button is offered: a live VIDEO call (sharing replaces the
  /// video; a voice call switches to video first).
  bool get available =>
      buildSupports == true && call.isLive && call.videoOn && _media != null;

  /// This build has the screen-share service (false on a Play build until
  /// the media-projection declaration is filed: NO button there — never a
  /// dead button or a "coming later" line). null = still asking.
  bool? buildSupports;
  late final Future<void> _buildCheck;

  Future<void> _checkBuild() async {
    bool ok;
    try {
      ok = await service.available();
    } catch (e) {
      callLog('screen_share#9', e);
      ok = false;
    }
    buildSupports = ok;
    log.add('build:$ok');
    if (!_disposed) notifyListeners();
  }

  void _set(ScreenShareState s) {
    if (state == s) return;
    state = s;
    log.add('state:${s.name}');
    if (!_disposed) notifyListeners();
  }

  void _notice(ScreenShareNotice n) {
    notice = n;
    noticeSeq++;
    log.add('notice:${n.name}');
    if (!_disposed) notifyListeners();
  }

  void _onCall() {
    if (_disposed) return;
    if (call.isEnded) {
      unawaited(stop());
      // the call is over: nothing can share any more
      Future<void>.microtask(dispose);
      return;
    }
    if (!call.videoOn && state != ScreenShareState.idle) unawaited(stop());
  }

  /// "Share screen" tapped: OUR consent sheet first.
  Future<void> request() async {
    await _buildCheck;
    if (_disposed || !available || state != ScreenShareState.idle) return;
    _set(ScreenShareState.consent);
  }

  /// Our consent sheet: "Not now" (or dismissed).
  void cancel() {
    if (state == ScreenShareState.consent) _set(ScreenShareState.idle);
  }

  /// Our consent sheet: "Continue" -> the system dialog and the capture.
  Future<void> confirm() async {
    final m = _media;
    if (state != ScreenShareState.consent || m == null) return;
    _set(ScreenShareState.starting);
    try {
      final added = await m.startScreenShare(beforeCapture: () async {
        final (title, body, stopLabel) = texts();
        _serviceOn =
            await service.start(title: title, body: body, stop: stopLabel);
        log.add('service:$_serviceOn');
        return _serviceOn;
      });
      if (_disposed || call.isEnded || !call.videoOn) {
        // the call ended / went to voice while the dialog was open
        try {
          await m.stopScreenShare();
        } catch (e) {
          callLog('screen_share#0', e);
        }
        await _stopService();
        _set(ScreenShareState.idle);
        return;
      }
      _set(ScreenShareState.sharing);
      await call.setScreenSharing(true, renegotiate: added);
    } on ScreenShareDenied {
      log.add('denied');
      await _stopService();
      _set(ScreenShareState.idle);
      _notice(ScreenShareNotice.denied);
    } catch (e) {
      callLog('screen_share#1', e);
      log.add('failed:$e');
      await _stopService();
      _set(ScreenShareState.idle);
      _notice(ScreenShareNotice.failed);
    }
  }

  Future<void> _stopService() async {
    if (!_serviceOn) return;
    _serviceOn = false;
    try {
      await service.stop();
    } catch (e) {
      callLog('screen_share#2', e);
    }
  }

  /// One-tap Stop (bar, notification, the system, call end). Idempotent.
  /// [system] = Android ended it (not the user on our screen): say so.
  Future<void> stop({bool system = false}) async {
    if (state != ScreenShareState.sharing) {
      if (state == ScreenShareState.consent) _set(ScreenShareState.idle);
      return;
    }
    _set(ScreenShareState.idle);
    try {
      await _media?.stopScreenShare();
    } catch (e) {
      callLog('screen_share#3', e);
    }
    await _stopService();
    log.add('stopped');
    if (system) _notice(ScreenShareNotice.stoppedBySystem);
    try {
      await call.setScreenSharing(false);
    } catch (e) {
      callLog('screen_share#4', e);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    if (_serviceOn) unawaited(_stopService()); // never leave it running
    _disposed = true;
    call.removeListener(_onCall);
    _stopSub?.cancel();
    super.dispose();
  }
}

/// The real native service (lazy: the channel is touched only on Share).
class NativeScreenShareService implements ScreenShareService {
  NativeScreenShareService._() {
    try {
      _ch.setMethodCallHandler((call) async {
        if (call.method == 'stopRequested') {
          final a = call.arguments;
          _stops.add(a is String ? a : 'user');
        }
        return null;
      });
    } catch (e) {
      callLog('screen_share#6', e);
    }
  }
  static NativeScreenShareService? _i;
  factory NativeScreenShareService() => _i ??= NativeScreenShareService._();

  static const _ch = MethodChannel('com.assisto/screenshare');
  final _stops = StreamController<String>.broadcast();

  @override
  Stream<String> get stopRequests => _stops.stream;

  @override
  Future<bool> start(
      {required String title,
      required String body,
      required String stop}) async {
    try {
      return await _ch.invokeMethod<bool>(
              'start', {'title': title, 'body': body, 'stop': stop}) ??
          false;
    } on MissingPluginException {
      // not Android (tests / desktop): no service is needed there
      return true;
    } catch (e) {
      callLog('screen_share#7', e);
      return false;
    }
  }

  @override
  Future<bool> available() async {
    try {
      return await _ch.invokeMethod<bool>('available') ?? false;
    } on MissingPluginException {
      return true; // not Android: nothing to declare
    } catch (e) {
      callLog('screen_share#10', e);
      return false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _ch.invokeMethod<void>('stop');
    } on MissingPluginException {
      return;
    } catch (e) {
      callLog('screen_share#8', e);
    }
  }
}
