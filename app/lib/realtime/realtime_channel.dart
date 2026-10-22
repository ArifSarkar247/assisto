import 'dart:async';

import 'package:flutter/foundation.dart';

/// c3-msg — the app's ONE real-time channel for My Circle.
///
/// Presence ("online" / "last seen"), typing / recording-audio, and — once
/// c2-calls plugs in — call signaling all travel over the same channel, so
/// the phone keeps at most one live connection (battery).
///
/// The transport is behind [RealtimeTransport]:
///   * [PollingTransport] (here, now): a sparse HTTP poll of GET
///     /circle/rt/state that ONLY runs while a My Circle screen is visible
///     and the app is foregrounded (refcounted [acquire]/[release]). The poll
///     doubles as the presence heartbeat (`?online=1`), so there is no extra
///     heartbeat request.
///   * a WebSocket transport (c2-calls): implement [RealtimeTransport] and
///     call [RealtimeChannel.useTransport]; screens don't change. Call
///     signaling events ride [send]/[events] with `type: 'call.*'`.
///
/// Event shapes (identical for every transport):
///   {type: 'state', chats: {'member:12': {online, last_seen, activity, who}}}
///   {type: 'call.offer' | 'call.answer' | 'call.ice' | …}   (c2-calls)
abstract class RealtimeTransport {
  /// Fetch one snapshot of chat states (polling) — a push transport may
  /// return the last cached snapshot.
  Future<Map<String, dynamic>> snapshot({required bool online});

  /// Fire-and-forget outbound event (typing, presence away, call signaling).
  Future<void> send(Map<String, dynamic> event);

  /// Push-style transports emit inbound events here; polling emits nothing.
  Stream<Map<String, dynamic>> get inbound => const Stream.empty();

  /// Polling cadence; a push transport returns null (no polling).
  Duration? get pollInterval;

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

  const RtChatState(
      {this.online, this.lastSeen, this.activity = '', this.who = ''});

  bool get typing => activity == 'typing';
  bool get recording => activity == 'recording';
  bool get active => activity.isNotEmpty;

  factory RtChatState.fromJson(Map<String, dynamic> j) => RtChatState(
        online: j['online'] is bool ? j['online'] as bool : null,
        lastSeen: DateTime.tryParse('${j['last_seen'] ?? ''}')?.toLocal(),
        activity: '${j['activity'] ?? ''}',
        who: '${j['who'] ?? ''}',
      );

  @override
  bool operator ==(Object other) =>
      other is RtChatState &&
      other.online == online &&
      other.lastSeen == lastSeen &&
      other.activity == activity &&
      other.who == who;

  @override
  int get hashCode => Object.hash(online, lastSeen, activity, who);
}

/// Key for a chat in the state map: 'member:<edge id>' / 'group:<group id>'.
String rtKey(String kind, int id) => '${kind == 'group' ? 'group' : 'member'}:$id';

class RealtimeChannel {
  RealtimeChannel._();
  static final RealtimeChannel instance = RealtimeChannel._();

  RealtimeTransport? _transport;
  Timer? _timer;
  int _refs = 0;
  bool _busy = false;
  bool _foreground = true;
  StreamSubscription<Map<String, dynamic>>? _inSub;

  /// Live chat states, keyed by [rtKey].
  final ValueNotifier<Map<String, RtChatState>> states =
      ValueNotifier<Map<String, RtChatState>>(const {});

  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Every inbound event (state snapshots + whatever a push transport sends,
  /// e.g. call signaling for c2-calls).
  Stream<Map<String, dynamic>> get events => _events.stream;

  // typing throttle: one "typing" per chat per [typingEvery]
  static const typingEvery = Duration(seconds: 3);
  final Map<String, DateTime> _lastTyping = {};
  final Map<String, String> _lastTypingState = {};

  @visibleForTesting
  DateTime Function() now = DateTime.now;

  RtChatState stateOf(String kind, int id) =>
      states.value[rtKey(kind, id)] ?? const RtChatState();

  /// Install / replace the transport (the polling one by default; c2-calls'
  /// WebSocket later).
  void useTransport(RealtimeTransport t) {
    _transport?.close();
    _inSub?.cancel();
    _transport = t;
    _inSub = t.inbound.listen(_onInbound, onError: (_) {});
    _reschedule();
  }

  bool get hasTransport => _transport != null;

  /// A My Circle screen became visible.
  void acquire() {
    _refs++;
    if (_refs == 1) {
      _reschedule();
      unawaited(refresh());
    }
  }

  /// …and went away. At 0 the poll stops and we tell the server "away".
  void release() {
    if (_refs == 0) return;
    _refs--;
    if (_refs == 0) {
      _stop();
      unawaited(_sendSafe({'type': 'presence', 'state': 'away'}));
    }
  }

  /// App lifecycle: polling only while foregrounded.
  void setForeground(bool fg) {
    if (_foreground == fg) return;
    _foreground = fg;
    if (!fg) {
      _stop();
      if (_refs > 0) {
        unawaited(_sendSafe({'type': 'presence', 'state': 'away'}));
      }
    } else if (_refs > 0) {
      _reschedule();
      unawaited(refresh());
    }
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _reschedule() {
    _stop();
    final t = _transport;
    if (t == null || _refs == 0 || !_foreground) return;
    final every = t.pollInterval;
    if (every == null) return;
    _timer = Timer.periodic(every, (_) => unawaited(refresh()));
  }

  /// One snapshot now (also the presence heartbeat). Silent on failure.
  Future<void> refresh() async {
    final t = _transport;
    if (t == null || _busy) return;
    _busy = true;
    try {
      final s = await t.snapshot(online: _foreground && _refs > 0);
      _onInbound({'type': 'state', ...s});
    } catch (_) {
    } finally {
      _busy = false;
    }
  }

  void _onInbound(Map<String, dynamic> e) {
    try {
      if (e['type'] == 'state' && e['chats'] is Map) {
        final next = <String, RtChatState>{};
        (e['chats'] as Map).forEach((k, v) {
          if (v is Map) {
            next['$k'] = RtChatState.fromJson(v.cast<String, dynamic>());
          }
        });
        if (!mapEquals(next, states.value)) states.value = next;
      }
      _events.add(e);
    } catch (_) {}
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
    unawaited(_sendSafe(
        {'type': 'typing', 'chat_kind': kind, 'chat_id': id, 'state': state}));
    return true;
  }

  /// Generic outbound (c2-calls signaling uses this too).
  Future<void> send(Map<String, dynamic> event) => _sendSafe(event);

  Future<void> _sendSafe(Map<String, dynamic> e) async {
    try {
      await _transport?.send(e);
    } catch (_) {}
  }

  @visibleForTesting
  void resetForTest() {
    _stop();
    _inSub?.cancel();
    _inSub = null;
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
  @visibleForTesting
  bool get polling => _timer != null;
}

/// HTTP polling transport over the c3 endpoints. [get]/[post] are injected
/// (ApiClient.getJson/postJson) so tests use a fake.
class PollingTransport extends RealtimeTransport {
  final Future<Map<String, dynamic>> Function(String path) get;
  final Future<Map<String, dynamic>> Function(
      String path, Map<String, dynamic> body) post;
  @override
  final Duration? pollInterval;

  PollingTransport(
      {required this.get,
      required this.post,
      this.pollInterval = const Duration(seconds: 4)});

  @override
  Future<Map<String, dynamic>> snapshot({required bool online}) =>
      get(online ? '/circle/rt/state?online=1' : '/circle/rt/state');

  @override
  Future<void> send(Map<String, dynamic> event) async {
    switch (event['type']) {
      case 'typing':
        await post('/circle/rt/typing', {
          'chat_kind': event['chat_kind'],
          'chat_id': event['chat_id'],
          'state': event['state'],
        });
        return;
      case 'presence':
        await post('/circle/rt/presence', {'state': event['state']});
        return;
      default:
        return; // call.* events need the WebSocket transport (c2-calls)
    }
  }
}
