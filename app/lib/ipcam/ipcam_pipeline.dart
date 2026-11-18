// cctvbox — camera -> pictures: RTSP session + decoder + reconnects.
// No Flutter widgets; the decoder and the session opener are injected, so
// the reconnect / feeding rules run in unit tests with fakes.
import 'dart:async';
import 'dart:math';

import 'ipcam_decoder.dart';
import 'rtsp_client.dart';

typedef SessionOpener = Future<RtspSession> Function(String url);

Future<RtspSession> openRtsp(String url) async {
  final u = RtspUrl.parse(url);
  if (u == null) throw const RtspException(RtspFail.notFound, 'not an rtsp:// address');
  final s = RtspSession(u);
  await s.open();
  return s;
}

enum PipeState { idle, connecting, playing, waiting, stopped }

class IpCamPipeline {
  final String url;
  final IpDecoder dec;
  final SessionOpener opener;
  final Duration Function(int attempt) backoff;
  final FeedGate gate;

  PipeState state = PipeState.idle;
  RtspFail? lastFail;
  String codec = '';
  int width = 0, height = 0;
  int reconnects = 0;
  int unitsIn = 0, unitsFed = 0, decodeFails = 0;
  DateTime? lostSince; // camera unreachable since (null = fine)

  RtspSession? _s;
  StreamSubscription<AccessUnit>? _sub;
  final _q = <AccessUnit>[];
  bool _pumping = false;
  bool _decOpen = false;
  int _feedFailsInRow = 0;
  bool _stopped = false;
  Timer? _retry;
  int _attempt = 0;
  final _clock = Stopwatch()..start();
  int _bytesMark = 0;
  DateTime _bytesAt = DateTime.now();
  double kbps = 0; // camera -> phone, kilobytes per second
  int _bytesDone = 0; // cctv-accuracy: bytes of the sessions already closed

  /// cctv-accuracy: every byte this camera sent this phone (all sessions) —
  /// the LAN grid's "data per minute".
  int get bytesIn => _bytesDone + (_s?.bytesIn ?? 0);

  IpCamPipeline(this.url, this.dec,
      {SessionOpener? opener, Duration Function(int)? backoff, FeedGate? gate})
      : opener = opener ?? openRtsp,
        backoff = backoff ?? defaultBackoff,
        gate = gate ?? FeedGate();

  static Duration defaultBackoff(int attempt) => Duration(seconds: min(60, 2 << min(attempt, 5)));

  bool get decoding => _decOpen;

  /// First connection. Null = playing; else why it failed (no retry — the
  /// setup screen shows the reason). [run] keeps retrying instead.
  Future<RtspFail?> start() async {
    _stopped = false;
    return _connect();
  }

  /// Keep the camera connected until [stop] (reconnect with backoff).
  Future<void> run() async {
    _stopped = false;
    final f = await _connect();
    if (f != null) _scheduleRetry();
  }

  Future<RtspFail?> _connect() async {
    state = PipeState.connecting;
    try {
      final s = await opener(url);
      if (_stopped) {
        await s.close();
        return RtspFail.closed;
      }
      _s = s;
      codec = s.video.codec;
      _attempt = 0;
      lostSince = null;
      lastFail = null;
      state = PipeState.playing;
      gate.restart();
      _sub = s.units.listen(_onUnit, onError: (Object e) {
        lastFail = e is RtspException ? e.kind : RtspFail.closed;
        _lost();
      }, onDone: () {
        if (!_stopped) _lost();
      });
      return null;
    } on RtspException catch (e) {
      lastFail = e.kind;
    } catch (_) {
      lastFail = RtspFail.protocol;
    }
    lostSince ??= DateTime.now();
    state = PipeState.waiting;
    return lastFail;
  }

  void _lost() {
    if (_stopped || state == PipeState.waiting) return;
    _sub?.cancel();
    _sub = null;
    _bytesDone += _s?.bytesIn ?? 0;
    _s = null;
    lostSince ??= DateTime.now();
    state = PipeState.waiting;
    _q.clear();
    if (_decOpen) {
      // the next session may bring other parameter sets: start clean
      _decOpen = false;
      unawaited(dec.close());
    }
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_stopped) return;
    _retry?.cancel();
    final d = backoff(_attempt++);
    _retry = Timer(d, () async {
      if (_stopped) return;
      reconnects++;
      final f = await _connect();
      if (f != null) _scheduleRetry();
    });
  }

  void _onUnit(AccessUnit au) {
    unitsIn++;
    if (!gate.accept(au, _q.length)) {
      if (_q.length >= gate.maxBacklog) _q.clear();
      return;
    }
    _q.add(au);
    if (!_pumping) unawaited(_pump());
  }

  Future<void> _pump() async {
    _pumping = true;
    try {
      while (_q.isNotEmpty && !_stopped) {
        final au = _q.removeAt(0);
        if (!_decOpen) {
          if (!au.key) continue;
          final s = _s;
          if (s == null) break;
          final err = await dec.open(s.video.mime, s.assembler.paramList);
          if (err != null) {
            decodeFails++;
            gate.restart();
            _q.clear();
            continue;
          }
          _decOpen = true;
        }
        final ok = await dec.feed(au.data, _clock.elapsedMicroseconds);
        if (ok) {
          unitsFed++;
          _feedFailsInRow = 0;
        } else if (++_feedFailsInRow >= 5) {
          // a stuck / broken decoder: reopen on the next key picture
          decodeFails++;
          _feedFailsInRow = 0;
          await dec.close();
          _decOpen = false;
          gate.restart();
        }
      }
    } finally {
      _pumping = false;
    }
  }

  /// The next decoded picture (null while not decoding / on timeout).
  Future<IpFrame?> grab({int maxW = 640, int timeoutMs = 3000}) async {
    if (!_decOpen) return null;
    final f = await dec.grab(maxW: maxW, timeoutMs: gate.keyOnly ? max(timeoutMs, 6000) : timeoutMs);
    if (f != null) {
      width = f.w;
      height = f.h;
    }
    final s = _s;
    if (s != null) {
      final now = DateTime.now();
      final ms = now.difference(_bytesAt).inMilliseconds;
      if (ms >= 2000) {
        kbps = (s.bytesIn - _bytesMark) / ms;
        _bytesMark = s.bytesIn;
        _bytesAt = now;
      }
    }
    return f;
  }

  Future<void> stop() async {
    _stopped = true;
    state = PipeState.stopped;
    _retry?.cancel();
    await _sub?.cancel();
    _sub = null;
    final s = _s;
    _bytesDone += s?.bytesIn ?? 0;
    _s = null;
    _q.clear();
    if (s != null) await s.close();
    if (_decOpen) {
      _decOpen = false;
      await dec.close();
    }
  }
}
