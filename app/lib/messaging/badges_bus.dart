import 'dart:async';

import 'package:flutter/foundation.dart';

import '../realtime/realtime_transport.dart';

/// b2-badges — "the home badges are stale, re-fetch GET /home/badges".
///
/// The home My Circle + bell icons listen to [tick]. It is poked when:
///   * a chat was opened and the server accepted the seen call (1:1 + group),
///   * the notification centre / one of its tabs was opened,
///   * the server queued `badges.update` on the shared real-time loop
///     (a new message for me, a new notification, my other device read a
///     chat) — [attach] wires the stream once, after sign-in.
///
/// Pokes in the same event-loop turn are coalesced (one microtask, never a
/// Timer — nothing is left pending when a screen closes). The
/// counts themselves always come from the SERVER, so they survive an app
/// kill / relaunch.
class BadgesBus {
  BadgesBus._();
  static final BadgesBus instance = BadgesBus._();

  static const String topic = 'badges.update';

  /// Incremented once per (debounced) refresh request.
  final ValueNotifier<int> tick = ValueNotifier<int>(0);

  bool _scheduled = false;
  StreamSubscription<RealtimeEvent>? _sub;

  void poke() {
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      tick.value++;
    });
  }

  /// Listen to the shared real-time loop for `badges.update` (idempotent).
  void attach(Stream<RealtimeEvent> events) {
    if (_sub != null) return;
    try {
      _sub = events
          .where((e) => e.topic == topic)
          .listen((_) => poke(), onError: (_) {});
    } catch (_) {}
  }

  @visibleForTesting
  void reset() {
    _scheduled = false;
    _sub?.cancel();
    _sub = null;
    tick.value = 0;
  }
}
