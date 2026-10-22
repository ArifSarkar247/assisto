import 'dart:async';

import 'package:flutter/foundation.dart';

import 'realtime_transport.dart';

/// c3-msg — My Circle's live presence ("online" / "last seen") and
/// typing / recording-audio, on the app's ONE real-time loop.
///
/// mc-int unification: there is NO second poll loop. Live events arrive on
/// c2-calls' shared [PollRealtimeTransport] (GET rt/events?after=<seq>, the
/// same queue that carries call signalling; 2.5 s app open / 5 s with FCM,
/// 0.5 s in a call, paused in background):
///   * presence.update {chat, online, last_seen, until}
///   * typing.update   {chat, activity, who, ttl_s}
/// Outbound goes through POST rt/send: `typing.set` (throttled here to one
/// per 3 s per chat, changes at once) and `presence.set {state: away}`.
///
/// Battery:
///   * the presence heartbeat is a FLAG on that same poll (`online=1`, only
///     while a My Circle screen is visible and the app is foregrounded); the
///     server writes it at most once per 30 s;
///   * GET /circle/rt/state (snapshot) runs only when a My Circle screen
///     appears, on resume, and once when a contact's `until` lapses (their
///     phone stopped heartbeating without saying "away").
///
/// [RealtimeTransport] is the seam: [SharedPollTransport] adapts the shared
/// poll loop; a WebSocket transport would implement the same four members.
abstract class RealtimeTransport {
  /// Snapshot of my chats' states. [online] = also count as a heartbeat.
  Future<Map<String, dynamic>> snapshot({required bool online});

  /// One event on the shared queue (POST rt/send {topic, payload}).
  Future<void> send(String topic, Map<String, dynamic> payload);

  /// Live presence.* / typing.* events from the shared loop.
  Stream<RealtimeEvent> get events;

  /// While true the shared poll carries the presence heartbeat.
  set heartbeat(bool on);

  void close() {}
}

/// The production transport: c2-calls' [PollRealtimeTransport] (owned by
/// CallRuntime — never closed from here) + the c3 snapshot endpoint.
class SharedPollTransport implements RealtimeTransport {
  SharedPollTransport(this.poll, {required this.get});

  final PollRealtimeTransport poll;
  final RtGet get;

  @override
  Future<Map<String, dynamic>> snapshot({required bool online}) =>
      get(online ? '/circle/rt/state?online=1' : '/circle/rt/state');

  @override
  Future<void> send(String topic, Map<String, dynamic> payload) async {
    await poll.send(topic, payload);
  }

  @override
  Stream<RealtimeEvent> get events => poll.events.where((e) =>
      e.topic.startsWith('presence.') || e.topic.startsWith('typing.'));

  @override
  set heartbeat(bool on) => poll.heartbeat = on;

  @override
  void close() {}
}

/// Live state of one chat as the viewer is allowed to see it.
@immutable
class RtChatState {
  /// null = hidden by the other person's privacy (show nothing).
  final bool? online;
  final DateTime? lastSeen;

  /// '' | 'typing' | 'recording'
  final String activity;

  /// Group: who is typing.
  final String who;

  /// When the server's "online" lapses unless the person's phone heartbeats
  /// again (a phone that died never says "away") — the channel re-checks
  /// with one snapshot then. null = not online / hidden.
  final DateTime? until;

  const RtChatState(
      {this.online,
      this.lastSeen,
      this.activity = '',
      this.who = '',
      this.until});

  RtChatState copyWith(
          {Object? online = _keep,
          Object? lastSeen = _keep,
          String? activity,
          String? who,
          Object? until = _keep}) =>
      RtChatState(
        online: identical(online, _keep) ? this.online : online as bool?,
        lastSeen:
            identical(lastSeen, _keep) ? this.lastSeen : lastSeen as DateTime?,
        activity: activity ?? this.activity,
        who: who ?? this.who,
        until: identical(until, _keep) ? this.until : until as DateTime?,
      );
  static const _keep = Object();

  bool get typing => activity == 'typing';
  bool get recording => activity == 'recording';
  bool get active => activity.isNotEmpty;

  factory RtChatState.fromJson(Map<String, dynamic> j) => RtChatState(
        online: j['online'] is bool ? j['online'] as bool : null,
        lastSeen: DateTime.tryParse('${j['last_seen'] ?? ''}')?.toLocal(),
        activity: '${j['activity'] ?? ''}',
        who: '${j['who'] ?? ''}',
        until: DateTime.tryParse('${j['until'] ?? ''}')?.toLocal(),
      );

  @override
  bool operator ==(Object other) =>
      other is RtChatState &&
      other.online == online &&
      other.lastSeen == lastSeen &&
      other.activity == activity &&
      other.who == who &&
      other.until == until;

  @override
  int get hashCode => Object.hash(online, lastSeen, activity, who, until);
}

/// Key for a chat in the state map: 'member:<edge id>' / 'group:<group id>'.
String rtKey(String kind, int id) => '${kind == 'group' ? 'group' : 'member'}:$id';

class RealtimeChannel {
  RealtimeChannel._();
  static final RealtimeChannel instance = RealtimeChannel._();

  RealtimeTransport? _transport;
  StreamSubscription<RealtimeEvent>? _sub;
  int _refs = 0;
  bool _busy = false;
  bool _foreground = true;
  Timer? _expiry;
  final Map<String, Timer> _typingTimers = {};

  /// Live chat states, keyed by [rtKey].
  final ValueNotifier<Map<String, RtChatState>> states =
      ValueNotifier<Map<String, RtChatState>>(const {});

  // typing throttle: one "typing" per chat per [typingEvery]
  static const typingEvery = Duration(seconds: 3);
  final Map<String, DateTime> _lastTyping = {};
  final Map<String, String> _lastTypingState = {};

  @visibleForTesting
  DateTime Function() now = DateTime.now;

  RtChatState stateOf(String kind, int id) =>
      states.value[rtKey(kind, id)] ?? const RtChatState();

  /// Install / replace the transport ([SharedPollTransport] in the app).
  void useTransport(RealtimeTransport t) {
    _transport?.close();
    _sub?.cancel();
    _transport = t;
    _sub = t.events.listen(onEvent, onError: (_) {});
    _applyHeartbeat();
  }

  bool get hasTransport => _transport != null;

  bool get _live => _refs > 0 && _foreground;

  void _applyHeartbeat() {
    try {
      _transport?.heartbeat = _live;
    } catch (_) {}
  }

  /// A My Circle screen became visible.
  void acquire() {
    _refs++;
    if (_refs == 1) {
      _applyHeartbeat();
      if (_foreground) unawaited(refresh());
    }
  }

  /// …and went away. At 0 the heartbeat stops and we tell the server "away".
  void release() {
    if (_refs == 0) return;
    _refs--;
    if (_refs == 0) {
      _applyHeartbeat();
      _cancelExpiry();
      if (_foreground) unawaited(_sendSafe('presence.set', {'state': 'away'}));
    }
  }

  /// App lifecycle (the shared poll itself is paused by CallRuntime).
  void setForeground(bool fg) {
    if (_foreground == fg) return;
    _foreground = fg;
    _applyHeartbeat();
    if (!fg) {
      _cancelExpiry();
      if (_refs > 0) {
        unawaited(_sendSafe('presence.set', {'state': 'away'}));
      }
    } else if (_refs > 0) {
      unawaited(refresh());
    }
  }

  /// One snapshot now (screen opened / resume / an `until` lapsed). Also
  /// counts as a heartbeat while a My Circle screen is visible.
  Future<void> refresh() async {
    final t = _transport;
    if (t == null || _busy) return;
    _busy = true;
    try {
      final s = await t.snapshot(online: _live);
      _applySnapshot(s);
    } catch (_) {
    } finally {
      _busy = false;
    }
  }

  void _applySnapshot(Map<String, dynamic> s) {
    if (s['chats'] is! Map) return;
    final next = <String, RtChatState>{};
    (s['chats'] as Map).forEach((k, v) {
      if (v is Map) {
        next['$k'] = RtChatState.fromJson(v.cast<String, dynamic>());
      }
    });
    _set(next);
  }

  /// A live event from the shared loop (public for tests / FCM mirroring).
  void onEvent(RealtimeEvent e) {
    try {
      final key = '${e.payload['chat'] ?? ''}';
      if (key.isEmpty) return;
      final cur = states.value[key] ?? const RtChatState();
      if (e.topic == 'presence.update') {
        final p = e.payload;
        _put(
            key,
            cur.copyWith(
              online: p['online'] is bool ? p['online'] as bool : null,
              lastSeen: DateTime.tryParse('${p['last_seen'] ?? ''}')?.toLocal(),
              until: DateTime.tryParse('${p['until'] ?? ''}')?.toLocal(),
            ));
      } else if (e.topic == 'typing.update') {
        final act = '${e.payload['activity'] ?? ''}';
        _typingTimers.remove(key)?.cancel();
        _put(key, cur.copyWith(activity: act, who: '${e.payload['who'] ?? ''}'));
        if (act.isNotEmpty) {
          final ttl = (e.payload['ttl_s'] as num?)?.toInt() ?? 8;
          _typingTimers[key] = Timer(Duration(seconds: ttl.clamp(1, 60)), () {
            _typingTimers.remove(key);
            final c = states.value[key];
            if (c != null && c.active) _put(key, c.copyWith(activity: ''));
          });
        }
      }
    } catch (_) {}
  }

  void _put(String key, RtChatState s) {
    final next = Map<String, RtChatState>.from(states.value)..[key] = s;
    _set(next);
  }

  void _set(Map<String, RtChatState> next) {
    if (!mapEquals(next, states.value)) states.value = next;
    _scheduleExpiry();
  }

  /// One timer for the earliest lapsing "online" (+2 s grace) -> snapshot.
  void _scheduleExpiry() {
    _cancelExpiry();
    if (!_live) return;
    DateTime? first;
    for (final s in states.value.values) {
      final u = s.until;
      if (s.online == true && u != null && (first == null || u.isBefore(first))) {
        first = u;
      }
    }
    if (first == null) return;
    var d = first.difference(now()) + const Duration(seconds: 2);
    if (d < const Duration(seconds: 5)) d = const Duration(seconds: 5);
    _expiry = Timer(d, () {
      _expiry = null;
      unawaited(refresh());
    });
  }

  void _cancelExpiry() {
    _expiry?.cancel();
    _expiry = null;
  }

  /// I am typing / recording / stopped in chat (kind,id). Throttled: the same
  /// state is sent at most once per [typingEvery]; a change (stop, typing →
  /// recording) goes out immediately. Returns true if an event was sent.
  bool typing(String kind, int id, String state) {
    final key = rtKey(kind, id);
    final t = now();
    final prevState = _lastTypingState[key];
    final prevAt = _lastTyping[key];
    if (state == 'stop') {
      if (prevState == null || prevState == 'stop') return false;
    } else if (prevState == state &&
        prevAt != null &&
        t.difference(prevAt) < typingEvery) {
      return false;
    }
    _lastTyping[key] = t;
    _lastTypingState[key] = state;
    unawaited(_sendSafe('typing.set',
        {'chat_kind': kind == 'group' ? 'group' : 'member', 'chat_id': id, 'state': state}));
    return true;
  }

  Future<void> _sendSafe(String topic, Map<String, dynamic> payload) async {
    try {
      await _transport?.send(topic, payload);
    } catch (_) {}
  }

  @visibleForTesting
  void resetForTest() {
    _cancelExpiry();
    for (final t in _typingTimers.values) {
      t.cancel();
    }
    _typingTimers.clear();
    _sub?.cancel();
    _sub = null;
    _transport = null;
    _refs = 0;
    _busy = false;
    _foreground = true;
    _lastTyping.clear();
    _lastTypingState.clear();
    states.value = const {};
    now = DateTime.now;
  }

  @visibleForTesting
  int get refs => _refs;

  /// The shared poll currently carries the presence heartbeat.
  @visibleForTesting
  bool get heartbeating => _live && _transport != null;

  @visibleForTesting
  bool get expiryArmed => _expiry != null;
}
