import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// offline1st — ONE honest answer to "can this phone reach Assisto right
/// now?", fed by every real API call (no extra traffic while online).
///
/// * A call that could not reach the server at all (no network, airplane
///   mode, DNS failure, connection refused / reset) -> [online] = false and a
///   tiny probe (GET /health, ~100 bytes) runs every few seconds while the
///   app is in the foreground, until the server answers again.
/// * ANY HTTP answer (even 4xx/5xx) means the network is up -> online.
/// * Back online fires [onBackOnline] listeners (the outbox flush, a quiet
///   session refresh, the chat list reload) — in registration order.
///
/// Pure Dart (dart:io + package:http) — no native plugin, nothing before the
/// first frame, so it can never block or crash the launch.
class NetStatus {
  NetStatus._();
  static final NetStatus instance = NetStatus._();

  /// true while the last real answer came from the server.
  final ValueNotifier<bool> online = ValueNotifier<bool>(true);

  /// The /health probe (set by AppState; null = no probing, e.g. tests).
  Future<bool> Function()? probe;

  final List<void Function()> _back = [];
  Timer? _timer;
  int _step = 0;
  bool _paused = false;

  static const probeCadence = <Duration>[
    Duration(seconds: 3),
    Duration(seconds: 5),
    Duration(seconds: 8),
    Duration(seconds: 15),
  ];

  /// Called when the server is reachable again (after an offline spell).
  void onBackOnline(void Function() cb) {
    if (!_back.contains(cb)) _back.add(cb);
  }

  void removeBackOnline(void Function() cb) => _back.remove(cb);

  /// True for failures that mean "the server could not be reached" (never
  /// for an HTTP answer: those are reported through [reportAnswer]).
  static bool isNetworkError(Object e) =>
      e is SocketException ||
      e is HandshakeException ||
      e is HttpException ||
      e is http.ClientException;

  /// The server answered (any status) -> online.
  void reportAnswer() {
    if (online.value) return;
    online.value = true;
    _timer?.cancel();
    _timer = null;
    _step = 0;
    for (final cb in List.of(_back)) {
      try {
        cb();
      } catch (_) {}
    }
  }

  /// A request failed before any answer. Only real network errors count.
  void reportFailure(Object e) {
    if (!isNetworkError(e)) return;
    if (online.value) online.value = false;
    _schedule();
  }

  /// App to background: stop probing (no battery / data in the background).
  void pause() {
    _paused = true;
    _timer?.cancel();
    _timer = null;
  }

  /// App to foreground: probe at once when we think we are offline.
  void resume() {
    _paused = false;
    if (!online.value) {
      _step = 0;
      _timer?.cancel();
      _timer = null;
      unawaited(_probeNow());
    }
  }

  void _schedule() {
    if (_paused || _timer != null || probe == null) return;
    final d = probeCadence[_step.clamp(0, probeCadence.length - 1)];
    _step++;
    _timer = Timer(d, () {
      _timer = null;
      unawaited(_probeNow());
    });
  }

  Future<void> _probeNow() async {
    final p = probe;
    if (p == null || online.value) return;
    var ok = false;
    try {
      ok = await p();
    } catch (_) {
      ok = false;
    }
    if (ok) {
      reportAnswer();
    } else {
      _schedule();
    }
  }

  @visibleForTesting
  void resetForTest() {
    _timer?.cancel();
    _timer = null;
    _step = 0;
    _paused = false;
    _back.clear();
    probe = null;
    online.value = true;
  }
}

/// Wraps the app's HTTP client: every answer / network failure feeds
/// [NetStatus]. Behaviour of the requests themselves is unchanged.
class NetWatchClient extends http.BaseClient {
  NetWatchClient(this._inner, {NetStatus? status})
      : _status = status ?? NetStatus.instance;
  final http.Client _inner;
  final NetStatus _status;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    try {
      final r = await _inner.send(request);
      _status.reportAnswer();
      return r;
    } catch (e) {
      _status.reportFailure(e);
      rethrow;
    }
  }

  @override
  void close() => _inner.close();
}
