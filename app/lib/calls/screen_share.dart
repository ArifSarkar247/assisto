import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'call_controller.dart';
import 'call_log.dart';
import 'media_ext.dart';

/// callsB: screen sharing in a video call — the state machine (pure Dart,
/// unit-tested with fakes).
///
///   idle --request--> consent (OUR explanation sheet: everyone in the call
///     sees everything on the screen, incl. notifications; Stop any time)
///   consent --cancel--> idle
///   consent --confirm--> starting: the SYSTEM consent dialog, then the
///     mediaProjection foreground service (Android 14+: only after consent),
///     then the capture is sent on every peer connection
///   starting --> sharing (red "You're sharing your screen · Stop" bar +
///     the notification's Stop) | idle + notice (denied / failed)
///   sharing --stop (bar, notification, call ended)--> idle (camera back)
enum ScreenShareState { idle, consent, starting, sharing }

/// The honest one-line result shown after a failed start.
enum ScreenShareNotice { none, denied, failed }

/// The native side ("com.assisto/screenshare"): the mediaProjection
/// foreground service. A fake in tests.
abstract class ScreenShareService {
  Future<bool> start(
      {required String title, required String body, required String stop});
  Future<void> stop();

  /// The notification's "Stop sharing" was tapped.
  Stream<void> get stopRequests;
}

class ScreenShareController extends ChangeNotifier {
  ScreenShareController({
    required this.media,
    required this.service,
    required this.links,
    required this.texts,
  }) {
    _stopSub = service.stopRequests.listen((_) => unawaited(stop()));
  }

  /// The call's media (null / not [ScreenShareMedia] = not supported).
  final Object? media;
  final ScreenShareService service;

  /// Every call link that must be told (1:1: the one controller; group: the
  /// primary + every pair link).
  final List<CallController> Function() links;

  /// (title, body, stop) for the foreground-service notification, in the
  /// app's language.
  final (String, String, String) Function() texts;

  ScreenShareState state = ScreenShareState.idle;
  ScreenShareNotice notice = ScreenShareNotice.none;
  int noticeSeq = 0;
  final List<String> log = [];
  StreamSubscription<void>? _stopSub;
  bool _disposed = false;

  bool get supported => media is ScreenShareMedia;
  bool get sharing => state == ScreenShareState.sharing;
  bool get busy =>
      state == ScreenShareState.starting || state == ScreenShareState.consent;

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

  /// "Share screen" tapped: show our consent sheet first.
  void request() {
    if (!supported || state != ScreenShareState.idle) return;
    _set(ScreenShareState.consent);
  }

  /// Our consent sheet: "Not now".
  void cancel() {
    if (state == ScreenShareState.consent) _set(ScreenShareState.idle);
  }

  /// Our consent sheet: "Continue" -> the system dialog and the capture.
  Future<void> confirm() async {
    final m = media;
    if (state != ScreenShareState.consent || m is! ScreenShareMedia) return;
    _set(ScreenShareState.starting);
    var serviceStarted = false;
    try {
      final needs = await m.startScreenShare(beforeCapture: () async {
        final (title, body, stopLabel) = texts();
        serviceStarted =
            await service.start(title: title, body: body, stop: stopLabel);
        log.add('service:$serviceStarted');
        return serviceStarted;
      });
      if (_disposed) return;
      _set(ScreenShareState.sharing);
      for (final c in links()) {
        if (c.isEnded) continue;
        if (needs.any((n) => identical(n, c.media))) {
          unawaited(c.renegotiateForNewTrack());
        }
        unawaited(c.setScreenSharing(true));
      }
    } on ScreenShareDenied {
      log.add('denied');
      await _abort(serviceStarted);
      _notice(ScreenShareNotice.denied);
    } catch (e) {
      callLog('screen_share#1', e);
      log.add('failed:$e');
      await _abort(serviceStarted);
      _notice(ScreenShareNotice.failed);
    }
  }

  Future<void> _abort(bool serviceStarted) async {
    if (serviceStarted) {
      try {
        await service.stop();
      } catch (e) {
        callLog('screen_share#2', e);
      }
    }
    _set(ScreenShareState.idle);
  }

  /// One-tap Stop (bar, notification, or the call ended). Idempotent.
  Future<void> stop() async {
    if (state != ScreenShareState.sharing) {
      if (state == ScreenShareState.consent) _set(ScreenShareState.idle);
      return;
    }
    final m = media;
    _set(ScreenShareState.idle);
    try {
      if (m is ScreenShareMedia) await m.stopScreenShare();
    } catch (e) {
      callLog('screen_share#3', e);
    }
    try {
      await service.stop();
    } catch (e) {
      callLog('screen_share#4', e);
    }
    for (final c in links()) {
      if (!c.isEnded) unawaited(c.setScreenSharing(false));
    }
    log.add('stopped');
  }

  @override
  void dispose() {
    if (state == ScreenShareState.sharing) {
      // the call screen went away while sharing: never leave it running
      unawaited(service.stop().catchError((Object e) {
        callLog('screen_share#5', e);
      }));
    }
    _disposed = true;
    _stopSub?.cancel();
    super.dispose();
  }
}

/// The real native service (lazy: the channel is touched only on Share).
class NativeScreenShareService implements ScreenShareService {
  NativeScreenShareService._() {
    try {
      _ch.setMethodCallHandler((call) async {
        if (call.method == 'stopRequested') _stops.add(null);
        return null;
      });
    } catch (e) {
      callLog('screen_share#6', e);
    }
  }
  static NativeScreenShareService? _i;
  factory NativeScreenShareService() => _i ??= NativeScreenShareService._();

  static const _ch = MethodChannel('com.assisto/screenshare');
  final _stops = StreamController<void>.broadcast();

  @override
  Stream<void> get stopRequests => _stops.stream;

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
