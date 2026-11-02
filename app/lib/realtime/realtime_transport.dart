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
/// Channels, so a WebSocket (or a held long-poll) would hold a worker per
/// phone. This transport SHORT-polls `GET /rt/events?after=<seq>` (the server
/// answers at once) with sequence numbers, so nothing is lost or duplicated
/// across reconnects.
///
/// circle2 — cadence tiers (the FIRST that applies wins). Measured in
/// test/circle2_rt_test.dart (15-minute, 3-phone replay):
///   1. call being set up / reconnecting ([setFast])        [fastInterval] 0.3 s
///   2. call CONNECTED and quiet ([setSteady] by the call)  [steadyInterval] 0.8 s
///      — any event or [send] gives [burstFor] of 0.3 s again (video switch,
///      ICE restart answer), so hang-up / renegotiation stay < 1 s.
///   3. a sent message waits for ✓✓ ([setBoost], ReceiptBus) [boostInterval] 1 s
///   4. a My Circle screen is visible ([heartbeat])          [idleInterval] 2.5 s
///   5. anywhere else in the app, FCM live ([quietInterval]) 10 s — rings and
///      messages arrive by FCM (a foreground push also [reconnect]s at once)
///   6. background: paused (FCM rings instead).
/// Errors back off exponentially — capped at 2 s while a call or a tick wait
/// is on (1–4), else 15 s — and [connected] goes false so the UI can say
/// "connecting…". [networkChanged] (Wi-Fi <-> mobile data) drops the backoff
/// and polls now: a reconnecting call must not wait 8–15 s for the other
/// phone's ICE-restart answer. The WebSocket upgrade is described in
/// .phaseB/proposals/c2-calls.md; it would replace only this class.
class PollRealtimeTransport {
  PollRealtimeTransport({
    required RtGet get,
    required RtPost post,
    // x1-calls A1-c: ~0.3 s while a call is set up / live, so offer, answer,
    // ICE and hang-up reach the other phone in well under 1 s.
    this.fastInterval = const Duration(milliseconds: 300),
    this.idleInterval = const Duration(milliseconds: 2500),
    Duration? steadyInterval,
    Duration? boostInterval,
    this.quietInterval,
    this.burstFor = const Duration(seconds: 3),
    DateTime Function()? now,
  })  : _get = get,
        _post = post,
        steadyInterval = steadyInterval ?? const Duration(milliseconds: 800),
        boostInterval = boostInterval ?? const Duration(milliseconds: 1000),
        _now = now ?? DateTime.now;

  /// Convenience constructor over the app's [ApiClient].
  factory PollRealtimeTransport.forApi(ApiClient api) => PollRealtimeTransport(
      get: api.getJson, post: (p, b) => api.postJson(p, b));

  final RtGet _get;
  final RtPost _post;
  final Duration fastInterval;
  Duration idleInterval;

  /// circle2: a CONNECTED call with nothing happening (tier 2).
  final Duration steadyInterval;

  /// circle2: waiting for ✓✓ after a send (tier 3).
  final Duration boostInterval;

  /// circle2: no My Circle screen visible and FCM is live (tier 5). null =
  /// [idleInterval] (no FCM: the poll is the only in-app ring path).
  Duration? quietInterval;

  /// circle2: after an event / a send in a steady call, poll fast this long.
  final Duration burstFor;

  final DateTime Function() _now;

  final _controller = StreamController<RealtimeEvent>.broadcast();
  final ValueNotifier<bool> connected = ValueNotifier<bool>(false);
  final Set<String> _topics = {};

  int _seq = 0;
  bool _running = false;
  bool _paused = false;
  bool _primed = false;
  int _fast = 0;
  int _steady = 0;
  int _boost = 0;
  int _failures = 0;
  DateTime? _burstUntil;

  /// circle2 measurement: GET rt/events requests made by this loop (tests
  /// and the debug panel read it; never sent anywhere).
  int polls = 0;
  Timer? _timer;
  bool _inFlight = false;

  /// c3-msg presence heartbeat rides THIS poll (`&online=1`) while a My
  /// Circle screen is visible — set by RealtimeChannel, no extra request.
  bool get heartbeat => _heartbeat;
  set heartbeat(bool on) {
    if (on == _heartbeat) return;
    _heartbeat = on;
    // circle2: a My Circle screen just opened — never sit out a 10 s quiet
    // timer before the first typing / presence event.
    if (on && _running && !_paused && !_inFlight) {
      _schedule(const Duration(milliseconds: 50));
    }
  }

  bool _heartbeat = false;

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
    if (fast) _burst();
    if (fast && _running && !_paused) {
      _timer?.cancel();
      unawaited(_tick());
    }
  }

  /// circle2: the call is CONNECTED (media flowing) — the loop may relax to
  /// [steadyInterval] while nothing happens. Reference counted like
  /// [setFast]; the call sets it false again while reconnecting.
  void setSteady(bool steady) {
    _steady = (steady ? _steady + 1 : _steady - 1).clamp(0, 1 << 20);
    if (!steady) _burst();
  }

  /// circle2: a sent message is waiting for ✓✓ / blue ✓✓ (ReceiptBus) —
  /// [boostInterval], not the call cadence. Reference counted.
  void setBoost(bool on) {
    final was = _boost > 0;
    _boost = (on ? _boost + 1 : _boost - 1).clamp(0, 1 << 20);
    if (on && !was && _running && !_paused && _fast == 0) {
      _schedule(boostInterval); // never wait out a 10 s quiet timer
    }
  }

  /// circle2: the phone's network changed (Wi-Fi <-> mobile data) or came
  /// back: forget the error backoff and poll NOW.
  Future<void> networkChanged() async {
    if (!_running || _paused) return;
    _burst();
    await reconnect();
  }

  void _burst() => _burstUntil = _now().add(burstFor);

  bool get _bursting {
    final u = _burstUntil;
    return u != null && _now().isBefore(u);
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
      String topic, Map<String, dynamic> payload) {
    // a signal out = an answer is coming: poll fast for [burstFor]
    if (_fast > 0) _burst();
    return _post('/rt/send', {'topic': topic, 'payload': payload});
  }

  /// One-off fetch of retained events (e.g. a call's offer that arrived
  /// before the call screen existed). Does not move [seq].
  Future<List<RealtimeEvent>> backlog(
      {int after = 0, String topics = '', int? callId}) async {
    // x1-calls: `call_id` = only THAT call's signals (a busy queue can no
    // longer push a fresh offer past the 200-event batch).
    final q = (topics.isEmpty ? '' : '&topics=$topics') +
        (callId == null ? '' : '&call_id=$callId');
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
      polls++;
      final r = await _get('/rt/events?after=$_seq$q');
      final evs = _parse(r);
      final latest = (r['seq'] as num?)?.toInt() ?? _seq;
      if (_primed) {
        for (final e in evs) {
          if (e.seq > _seq) {
            _seq = e.seq;
            if (_fast > 0) _burst();
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
    final urgent = _fast > 0 || _boost > 0;
    if (_failures > 0) {
      final cap = urgent ? 2000 : 15000;
      final ms = (500 * (1 << (_failures - 1).clamp(0, 5))).clamp(500, cap);
      return Duration(milliseconds: ms);
    }
    if (_fast > 0) {
      return (_steady > 0 && !_bursting) ? steadyInterval : fastInterval;
    }
    if (_boost > 0) return boostInterval;
    if (heartbeat) return idleInterval;
    return quietInterval ?? idleInterval;
  }

  /// Which tier [currentInterval] is in (debug panel / tests).
  @visibleForTesting
  String get tier {
    if (_failures > 0) return 'backoff';
    if (_fast > 0) return (_steady > 0 && !_bursting) ? 'steady' : 'fast';
    if (_boost > 0) return 'boost';
    if (heartbeat) return 'circle';
    return quietInterval == null ? 'idle' : 'quiet';
  }

  /// Test seams: a failed poll / an event arriving, without the network.
  @visibleForTesting
  void debugFail() => _failures++;

  @visibleForTesting
  void debugEvent() {
    _failures = 0;
    if (_fast > 0) _burst();
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
