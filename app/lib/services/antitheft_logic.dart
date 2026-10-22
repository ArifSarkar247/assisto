import 'dart:math' as math;

/// b6-antitheft — PURE, testable logic shared by the UI and mirrored by the
/// native engine (app/android_overlay/.../antitheft/*.kt). No Flutter, no
/// plugins, no platform calls, so it runs in a plain Dart unit test.
///
/// The native Kotlin SnatchDetector + store-and-forward queue implement the
/// SAME rules; keeping an authoritative copy here means the conservative
/// thresholds and the dedupe/ordering behaviour are tested without an
/// emulator (the brief's "Kotlin-free logic test where possible").
library antitheft_logic;

/// Battery-aware heartbeat interval (minutes). MUST match
/// core/logic/antitheft.heartbeat_interval_min and HeartbeatPolicy.kt.
int heartbeatIntervalMin(
    {required int? batteryPct, required bool charging, required bool lostMode}) {
  if (charging) return lostMode ? 5 : 10;
  if (batteryPct != null && batteryPct <= 15) return 60; // critical wins
  if (lostMode) return 5;
  if (batteryPct != null && batteryPct <= 30) return 30;
  return 15;
}

/// Conservative snatch detector. A "snatch" is a sudden strong jerk (a grab)
/// immediately followed by sustained motion (running away) WHILE the phone is
/// unlocked. We deliberately require BOTH halves so an ordinary drop, a bump,
/// or putting the phone down does not fire — false theft alarms erode trust.
class SnatchDetector {
  /// Linear-acceleration magnitude (m/s^2, gravity removed) that counts as a
  /// sudden grab. ~2.5g. High on purpose: everyday handling rarely reaches it.
  static const double grabThreshold = 25.0;

  /// After a grab, this much sustained motion (average magnitude over the
  /// follow window) counts as "running away".
  static const double runThreshold = 6.0;

  /// Window after a grab in which we look for the run, in milliseconds.
  static const int followWindowMs = 2500;

  /// Minimum fraction of follow-window samples that must be "moving".
  static const double runSampleFraction = 0.6;

  int? _grabAtMs;
  int _followSamples = 0;
  int _movingSamples = 0;

  /// Feed one sample. Returns true exactly once when a snatch pattern
  /// completes. [unlocked] gates it: a snatch only matters while the screen is
  /// unlocked (a thief grabbing a phone the owner was using).
  bool onSample(
      {required double magnitude, required int tMs, required bool unlocked}) {
    if (!unlocked) {
      _reset();
      return false;
    }
    if (_grabAtMs == null) {
      if (magnitude >= grabThreshold) {
        _grabAtMs = tMs;
        _followSamples = 0;
        _movingSamples = 0;
      }
      return false;
    }
    // in the follow window
    if (tMs - _grabAtMs! > followWindowMs) {
      final fired = _followSamples > 0 &&
          _movingSamples / _followSamples >= runSampleFraction;
      _reset();
      return fired;
    }
    _followSamples++;
    if (magnitude >= runThreshold) _movingSamples++;
    return false;
  }

  void _reset() {
    _grabAtMs = null;
    _followSamples = 0;
    _movingSamples = 0;
  }

  /// Magnitude of a 3-axis linear-acceleration reading.
  static double magnitude(double x, double y, double z) =>
      math.sqrt(x * x + y * y + z * z);
}

/// A store-and-forward event queued on the device until the server accepts it.
class QueuedEvent {
  final String id; // stable per captured event → server dedupe key
  final String kind;
  final int atMs; // when it happened (device clock); server corrects skew
  final Map<String, dynamic> data;
  final double? lat;
  final double? lng;
  final int? battery;
  QueuedEvent({
    required this.id,
    required this.kind,
    required this.atMs,
    this.data = const {},
    this.lat,
    this.lng,
    this.battery,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'at': atMs,
        if (data.isNotEmpty) 'data': data,
        if (lat != null) 'lat': lat,
        if (lng != null) 'lng': lng,
        if (battery != null) 'battery': battery,
      };
}

/// Pure model of the on-device queue (the native engine persists the same
/// shape to a small SQLite/file). Dedupes by id, caps size (oldest dropped),
/// and hands out time-ordered batches so a backlog uploads in order.
class StoreAndForwardQueue {
  final int maxSize;
  final List<QueuedEvent> _items = [];
  final Set<String> _ids = {};
  StoreAndForwardQueue({this.maxSize = 500});

  int get length => _items.length;
  bool get isEmpty => _items.isEmpty;

  /// Add an event; a repeated id is ignored (idempotent capture). Returns true
  /// if it was newly queued.
  bool add(QueuedEvent e) {
    if (_ids.contains(e.id)) return false;
    _items.add(e);
    _ids.add(e.id);
    if (_items.length > maxSize) {
      final dropped = _items.removeAt(0);
      _ids.remove(dropped.id);
    }
    return true;
  }

  /// Oldest-first batch of up to [limit] events, ready to POST.
  List<QueuedEvent> batch({int limit = 100}) {
    final sorted = [..._items]..sort((a, b) => a.atMs.compareTo(b.atMs));
    return sorted.take(limit).toList();
  }

  /// Drop events the server confirmed it accepted or already had.
  void ack(Iterable<String> acceptedOrDuplicateIds) {
    final done = acceptedOrDuplicateIds.toSet();
    _items.removeWhere((e) => done.contains(e.id));
    _ids.removeWhere(done.contains);
  }
}
