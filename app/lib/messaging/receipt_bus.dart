import 'dart:async';

import 'package:flutter/foundation.dart';

import '../realtime/realtime_transport.dart';
import 'msg_ticks.dart';
import 'receipt_ack.dart';

/// One `receipt.update` from the server: the SENDER's chat key
/// ('member:<my edge id>' | 'group:<id>') and the new status per message id
/// (server-decided, reciprocal read-receipt privacy already applied).
@immutable
class ReceiptUpdate {
  final String chat;
  final Map<String, String> statuses;
  final DateTime at;
  const ReceiptUpdate(this.chat, this.statuses, this.at);
}

/// x2-ticks — live ticks on the app's ONE realtime loop (c2-calls'
/// PollRealtimeTransport, GET rt/events).
///
///   * `receipt.update` (I am the SENDER) → [updates]; an open chat and the
///     chat list apply it at once (never downgrading a tick — [applyTo]).
///   * `msg.new` (I am the RECIPIENT, app open) → DELIVERED ack right away
///     (ReceiptAck — no waiting for FCM) and [newMessages] so an open chat
///     refreshes now instead of at its next 7 s poll.
///
/// SPEED: a sender waiting for ✓✓ / blue ✓✓ in an open chat asks for a
/// boost window ([expect]) — the shared loop then polls every 1 s
/// (PollRealtimeTransport.setBoost) for [boostFor] after the last SEND, else
/// it stays at its idle cadence (2.5 s while a My Circle screen is visible).
///
/// circle2 (owner: ~1,350 rt/events in 15 min from 3 phones): this used to
/// be the CALL cadence (0.3 s) for 90 s, re-armed by every chat refresh while
/// any of my messages was unread — an open chat whose peer was away polled
/// ~3 times a second for as long as it stayed open. Now a send arms 20 s at
/// 1 s; a re-check ([expect] with `fresh: false`: chat opened, receipt,
/// refresh) arms at most ONE such window per [watchEvery] and never extends
/// one.
class ReceiptBus {
  ReceiptBus._();
  static final ReceiptBus instance = ReceiptBus._();

  static const topicReceipt = 'receipt.update';
  static const topicNew = 'msg.new';
  static const boostFor = Duration(seconds: 20);
  static const watchEvery = Duration(minutes: 2);

  @visibleForTesting
  DateTime Function() clock = DateTime.now;
  DateTime? _lastWatch;

  final _updates = StreamController<ReceiptUpdate>.broadcast();
  final _new = StreamController<String>.broadcast();
  Stream<ReceiptUpdate> get updates => _updates.stream;
  Stream<String> get newMessages => _new.stream;

  StreamSubscription<RealtimeEvent>? _sub;
  Stream<RealtimeEvent>? _attached;
  ReceiptAck Function()? _ack;
  void Function(bool fast)? _setFast;
  bool _fast = false;
  Timer? _boost;

  /// Wire the shared stream once (idempotent per stream).
  void attach(Stream<RealtimeEvent> events,
      {ReceiptAck Function()? ack, void Function(bool fast)? setFast}) {
    if (ack != null) _ack = ack;
    if (setFast != null) _setFast = setFast;
    // (a broadcast controller's .stream is a new object with == by controller)
    if (_attached == events && _sub != null) return;
    _sub?.cancel();
    _attached = events;
    try {
      _sub = events.where((e) => e.topic == topicReceipt || e.topic == topicNew)
          .listen(onEvent, onError: (_) {});
    } catch (_) {}
  }

  /// Public for tests / an FCM mirror.
  void onEvent(RealtimeEvent e) {
    try {
      final chat = '${e.payload['chat'] ?? ''}';
      if (e.topic == topicReceipt) {
        final raw = e.payload['statuses'];
        if (chat.isEmpty || raw is! Map) return;
        _updates.add(ReceiptUpdate(
            chat, {for (final kv in raw.entries) '${kv.key}': '${kv.value}'},
            e.ts));
      } else if (e.topic == topicNew) {
        final id = int.tryParse('${e.payload['message_id'] ?? ''}');
        if (id != null) {
          final a = _ack?.call();
          if (a != null) unawaited(a.delivered([id]));
        }
        if (chat.isNotEmpty) _new.add(chat);
      }
    } catch (_) {}
  }

  /// "I'm waiting for ticks in an open chat": fast realtime polling for
  /// [boostFor] (extended by every call). Cheap no-op without a transport.
  void expect({bool fresh = true}) {
    if (!fresh) {
      if (_fast) return; // a window is already open — never extend it
      final now = clock();
      final last = _lastWatch;
      if (last != null && now.difference(last) < watchEvery) return;
      _lastWatch = now;
    }
    _boost?.cancel();
    if (!_fast) {
      _fast = true;
      try {
        _setFast?.call(true);
      } catch (_) {}
    }
    _boost = Timer(boostFor, relax);
  }

  /// Back to the idle cadence (chat closed / backgrounded / all read).
  void relax() {
    _boost?.cancel();
    _boost = null;
    if (!_fast) return;
    _fast = false;
    try {
      _setFast?.call(false);
    } catch (_) {}
  }

  @visibleForTesting
  bool get boosted => _fast;

  @visibleForTesting
  void reset() {
    relax();
    _lastWatch = null;
    clock = DateTime.now;
    _sub?.cancel();
    _sub = null;
    _attached = null;
    _ack = null;
    _setFast = null;
  }
}

/// Apply a receipt update to a status, never downgrading (a late "sent"
/// after "read" is ignored). Pure.
String mergeStatus(String current, String incoming) {
  final a = tickFrom(current), b = tickFrom(incoming);
  if (a == MsgTick.failed || a == MsgTick.pending) return current;
  return maxTick(a, b) == b ? (b == a ? current : incoming) : current;
}
