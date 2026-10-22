import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api.dart';

/// One event from the server's real-time queue (backend RtEvent).
///
/// Envelope (backend core/views_c2_calls.py, GET /rt/events):
///   {"seq": int, "topic": "call.signal" | "call.state" | "call.incoming" |
///    "presence.*" | "typing.*", "payload": {...}, "ts": iso8601}
class RealtimeEvent {
  const RealtimeEvent(this.seq, this.topic, this.payload, this.ts);
  final int seq;
  final String topic;
  final Map<String, dynamic> payload;
  final DateTime ts;

  factory RealtimeEvent.fromJson(Map<String, dynamic> j) => RealtimeEvent(
        (j['seq'] as num?)?.toInt() ?? 0,
        '${j['topic'] ?? ''}',
        (j['payload'] is Map)
            ? (j['payload'] as Map).cast<String, dynamic>()
            : const <String, dynamic>{},
        DateTime.tryParse('${j['ts'] ?? ''}') ?? DateTime.now(),
      );

  @override
  String toString() => 'RealtimeEvent($seq $topic)';
}

typedef RtGet = Future<Map<String, dynamic>> Function(String path);
typedef RtPost = Future<Map<String, dynamic>> Function(
    String path, Map<String, dynamic> body);

/// The app's ONE real-time loop: call signalling (c2-calls) AND My Circle
/// presence/typing (c3-msg's RealtimeChannel reaches it through
/// SharedPollTransport in realtime_channel.dart).
///
/// WHY POLLING: the backend runs on gunicorn sync workers without Django
/// Channels, so a WebSocket would hold a worker per phone. This transport
/// SHORT-polls `GET /rt/events?after=<seq>` (the server answers at once) with
/// sequence numbers, so nothing is lost or duplicated across reconnects:
///   * fast (0.5 s) while a call is being set up / in a call
///     ([setFast] — reference counted, several users may ask),
///   * normal ([idleInterval], 2.5 s) while the app is open,
///   * paused while the app is in the background (FCM rings instead).
/// Errors back off exponentially (max 15 s) and [connected] goes false so
/// the UI can say "connecting…". The WebSocket upgrade is described in
/// .phaseB/proposals/c2-calls.md; it would replace only this class.
class PollRealtimeTransport {
  PollRealtimeTransport({
    required RtGet get,
    required RtPost post,
    this.fastInterval = const Duration(milliseconds: 500),
    this.idleInterval = const Duration(milliseconds: 2500),
  })  : _get = get,
        _post = post;

  /// Convenience constructor over the app's [ApiClient].
  factory PollRealtimeTransport.forApi(ApiClient api) => PollRealtimeTransport(
      get: api.getJson, post: (p, b) => api.postJson(p, b));

  final RtGet _get;
  final RtPost _post;
  final Duration fastInterval;
  Duration idleInterval;

  final _controller = StreamController<RealtimeEvent>.broadcast();
  final ValueNotifier<bool> connected = ValueNotifier<bool>(false);
  final Set<String> _topics = {};

  int _seq = 0;
  bool _running = false;
  bool _paused = false;
  bool _primed = false;
  int _fast = 0;
  int _failures = 0;
  Timer? _timer;
  bool _inFlight = false;

  /// c3-msg presence heartbeat rides THIS poll (`&online=1`) while a My
  /// Circle screen is visible — set by RealtimeChannel, no extra request.
  bool heartbeat = false;

  int get seq => _seq;
  bool get running => _running && !_paused;
  Stream<RealtimeEvent> get events => _controller.stream;

  /// Topic prefixes this phone listens to (empty = everything for me).
  void subscribe(String topicPrefix) => _topics.add(topicPrefix);
  void unsubscribe(String topicPrefix) => _topics.remove(topicPrefix);

  /// Start polling. The FIRST poll only learns the current sequence number
  /// (old events are not replayed into listeners) unless [replay] is true.
  Future<void> connect({bool replay = false}) async {
    if (_running) return;
    _running = true;
    _primed = replay;
    await _tick();
  }

  /// Drop the timer and poll now (network came back, app resumed).
  Future<void> reconnect() async {
    if (!_running) return;
    _failures = 0;
    _timer?.cancel();
    await _tick();
  }

  void setFast(bool fast) {
    _fast = (fast ? _fast + 1 : _fast - 1).clamp(0, 1 << 20);
    if (fast && _running && !_paused) {
      _timer?.cancel();
      unawaited(_tick());
    }
  }

  /// App went to the background / came back.
  void setPaused(bool paused) {
    if (_paused == paused) return;
    _paused = paused;
    _timer?.cancel();
    if (!paused) unawaited(reconnect());
  }

  /// POST /rt/send {topic, payload}. Throws [ApiException] on refusal.
  Future<Map<String, dynamic>> send(
          String topic, Map<String, dynamic> payload) =>
      _post('/rt/send', {'topic': topic, 'payload': payload});

  /// One-off fetch of retained events (e.g. a call's offer that arrived
  /// before the call screen existed). Does not move [seq].
  Future<List<RealtimeEvent>> backlog(
      {int after = 0, String topics = ''}) async {
    final q = topics.isEmpty ? '' : '&topics=$topics';
    final r = await _get('/rt/events?after=$after$q');
    return _parse(r);
  }

  List<RealtimeEvent> _parse(Map<String, dynamic> r) =>
      ((r['events'] ?? const []) as List)
          .whereType<Map>()
          .map((e) => RealtimeEvent.fromJson(e.cast<String, dynamic>()))
          .toList();

  /// Feed events in directly (tests, or an FCM data push mirrored in).
  @visibleForTesting
  void inject(RealtimeEvent e) => _controller.add(e);

  Future<void> _tick() async {
    if (!_running || _paused || _inFlight) return;
    _inFlight = true;
    var more = false;
    try {
      final q = (_topics.isEmpty ? '' : '&topics=${_topics.join(',')}') +
          (heartbeat ? '&online=1' : '');
      final r = await _get('/rt/events?after=$_seq$q');
      final evs = _parse(r);
      final latest = (r['seq'] as num?)?.toInt() ?? _seq;
      if (_primed) {
        for (final e in evs) {
          if (e.seq > _seq) {
            _seq = e.seq;
            _controller.add(e);
          }
        }
        more = r['more'] == true;
      }
      if (!more && latest > _seq) _seq = latest;
      _primed = true;
      _failures = 0;
      connected.value = true;
    } catch (_) {
      _failures++;
      connected.value = false;
    } finally {
      _inFlight = false;
    }
    _schedule(more ? Duration.zero : null);
  }

  Duration get currentInterval {
    if (_failures > 0) {
      final ms = (500 * (1 << (_failures - 1).clamp(0, 5))).clamp(500, 15000);
      return Duration(milliseconds: ms);
    }
    return _fast > 0 ? fastInterval : idleInterval;
  }

  void _schedule([Duration? d]) {
    _timer?.cancel();
    if (!_running || _paused) return;
    _timer = Timer(d ?? currentInterval, () => unawaited(_tick()));
  }

  Future<void> close() async {
    _running = false;
    _timer?.cancel();
    connected.value = false;
  }
}
