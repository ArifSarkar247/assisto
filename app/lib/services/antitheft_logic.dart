import 'dart:math' as math;

/// b6-antitheft — PURE, testable logic shared by the UI and mirrored by the
/// native engine (app/android_overlay/.../antitheft/*.kt). No Flutter, no
/// plugins, no platform calls, so it runs in a plain Dart unit test.
///
/// The native Kotlin SnatchDetector + store-and-forward queue implement the
/// SAME rules; keeping an authoritative copy here means the conservative
/// thresholds and the dedupe/ordering behaviour are tested without an
/// emulator (the brief's "Kotlin-free logic test where possible").

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

/// grab-guard (owner 25 Oct: "sudden grab" alerts at 01:54 AM while the phone
/// lay by the bed) — the facts around ONE accelerometer sample that decide
/// whether a grab may count at all. Mirror of SnatchPolicy.kt (keep in sync).
class SnatchContext {
  const SnatchContext({
    this.charging = false,
    this.screenOn = false,
    this.unlocked = false,
    this.msSinceUnlock,
    this.hour = 12,
    this.faceDown = false,
    this.onHomeWifi = false,
    this.nightGuard = false,
  });

  /// antitheft2: lying screen-down (gravity on -z). With [restBefore] =
  /// "face-down and still" — a drop/toss, never a snatch.
  final bool faceDown;

  /// antitheft2: connected to one of the owner's saved home Wi-Fi networks.
  final bool onHomeWifi;

  /// antitheft2: "Night guard" ON = keep watching at night even at home.
  final bool nightGuard;

  /// On the charger: the owner put it there — never a snatch.
  final bool charging;
  final bool screenOn;

  /// Keyguard dismissed (or no screen lock at all).
  final bool unlocked;

  /// Milliseconds since the last USER_PRESENT (unlock); null = not seen.
  final int? msSinceUnlock;

  /// Local hour 0-23 (night quiet profile).
  final int hour;
}

/// One detection profile: how hard the grab and how sustained the run.
class SnatchProfile {
  const SnatchProfile({
    required this.name,
    required this.grabThreshold,
    required this.runThreshold,
    required this.followWindowMs,
    required this.runFraction,
    required this.lateRunFraction,
    required this.minFollowSamples,
  });

  final String name;

  /// Linear-acceleration magnitude (m/s^2, gravity removed) of the grab.
  final double grabThreshold;

  /// A follow-window sample at/above this counts as "moving away".
  final double runThreshold;
  final int followWindowMs;

  /// Fraction of ALL follow samples that must be moving …
  final double runFraction;

  /// … and of the LATER half too (the motion must be sustained — walking /
  /// running away — not a jolt that settles, like a pick-up or put-down).
  final double lateRunFraction;

  /// Too few samples (sensor batching / a stalled stream) -> no verdict.
  final int minFollowSamples;
}

/// Pure decision rules for the snatch (grab) detector. Mirror of
/// android_overlay/.../antitheft/SnatchPolicy.kt 1:1 (keep in sync).
///
///   * charging                       -> off (the owner plugged it in)
///   * unlocked < [inHandMs] ago      -> off (picked up to use it)
///   * night 23:00-06:00              -> ONLY a screen-off phone that was
///                                       lying still, [night] (strongest)
///                                       pattern
///   * day, screen off                -> only if it was lying still
///                                       (moving in a pocket / bag -> off),
///                                       [night] (strongest) pattern
///   * day otherwise                  -> [day] pattern
/// A grab = two samples >= the grab threshold within [debounceMs]; after a
/// snatch fired there is a [cooldownMs] pause.
class SnatchPolicy {
  SnatchPolicy._();

  static const day = SnatchProfile(
    name: 'day',
    grabThreshold: 25.0,
    runThreshold: 6.0,
    followWindowMs: 3500,
    runFraction: 0.6,
    lateRunFraction: 0.5,
    minFollowSamples: 15,
  );

  static const night = SnatchProfile(
    name: 'night',
    grabThreshold: 32.0,
    runThreshold: 7.0,
    followWindowMs: 5000,
    runFraction: 0.7,
    lateRunFraction: 0.6,
    minFollowSamples: 25,
  );

  static const inHandMs = 60000;
  static const nightStartHour = 23;
  static const nightEndHour = 6;
  static const restMax = 1.2;
  static const restMs = 3000;
  static const debounceMs = 300;
  static const cooldownMs = 5 * 60000;

  /// The owner gets this long to answer "Are you OK?" on his own phone;
  /// antitheft2: the grab reaches the server at once (held there) and the
  /// SERVER escalates it to the trusted contacts when this window passes.
  static const confirmWindowMs = 60000;

  static bool isNight(int hour) =>
      hour >= nightStartHour || hour < nightEndHour;

  static bool freshUnlock(SnatchContext c) =>
      c.unlocked && c.msSinceUnlock != null && c.msSinceUnlock! < inHandMs;

  /// The profile a grab NOW must meet, or null = a grab cannot count now.
  /// [restBefore]: the phone lay still for [restMs] before the jolt.
  static SnatchProfile? profileFor(SnatchContext c,
      {required bool restBefore}) {
    if (c.charging) return null;
    if (freshUnlock(c)) return null;
    // antitheft2 (owner 27 Oct): face-down and still -> a drop / toss
    if (c.faceDown && restBefore) return null;
    // antitheft2: at night at home (saved Wi-Fi) unless Night guard is ON
    if (homeNight(c)) return null;
    if (isNight(c.hour)) {
      if (c.screenOn || !restBefore) return null;
      return night;
    }
    if (!c.screenOn) return restBefore ? night : null; // strongest pattern
    return day;
  }

  /// antitheft2: night + the owner's home Wi-Fi + Night guard OFF.
  static bool homeNight(SnatchContext c) =>
      isNight(c.hour) && c.onHomeWifi && !c.nightGuard;

  /// Abort an armed grab mid-window (plugged in / unlocked meanwhile).
  static bool abort(SnatchContext c) => c.charging || freshUnlock(c);
}

/// antitheft2 (owner 27 Oct: alerts arrived hours late) — WHEN the native
/// engine retries sending its store-and-forward queue. Mirror of
/// FlushPolicy.kt (keep in sync):
///   * connectivity comes back with something queued -> flush after
///     [connectivityDelayMs] (the network needs a moment to be usable);
///   * a failed upload with something queued -> retry with backoff
///     30 s, 60 s, 120 s, 240 s, then every 300 s — never just "next
///     heartbeat" (15-60 min) or "next app open".
class FlushPolicy {
  FlushPolicy._();

  static const connectivityDelayMs = 3000;
  static const firstRetryMs = 30000;
  static const maxRetryMs = 300000;

  /// Delay before retry number [attempt] (1-based) after a failed upload.
  static int retryDelayMs(int attempt) {
    if (attempt < 1) attempt = 1;
    var d = firstRetryMs;
    for (var i = 1; i < attempt && d < maxRetryMs; i++) {
      d *= 2;
    }
    return d > maxRetryMs ? maxRetryMs : d;
  }

  /// Should a connectivity broadcast trigger a flush now?
  static bool flushOnConnectivity(
          {required bool connected, required int queued}) =>
      connected && queued > 0;

  /// Should a failed/finished upload schedule a retry?
  static bool scheduleRetry({required bool uploadOk, required int queued}) =>
      !uploadOk && queued > 0;
}

/// Conservative snatch detector (Kotlin mirror: SnatchDetector.kt). A
/// "snatch" = a sudden strong jerk (two samples over the profile's grab
/// threshold) followed by SUSTAINED motion (moving away) through the whole
/// follow window, allowed by [SnatchPolicy] at that moment. An ordinary
/// pick-up, put-down, bump, in-hand use or charging never fires.
class SnatchDetector {
  SnatchProfile? _profile;
  int? _grabAtMs;
  int? _spikeAtMs;
  bool _spikeRest = false;
  int? _lastActiveMs;
  int? _firstMs;
  int? _cooldownUntil;
  int _early = 0, _earlyMoving = 0, _late = 0, _lateMoving = 0;

  /// Feed one sample. Returns true exactly once when a snatch completes.
  bool onSample(
      {required double magnitude,
      required int tMs,
      required SnatchContext ctx}) {
    _firstMs ??= tMs;
    final restBefore =
        (tMs - (_lastActiveMs ?? _firstMs!)) >= SnatchPolicy.restMs;
    if (magnitude >= SnatchPolicy.restMax) _lastActiveMs = tMs;

    final cd = _cooldownUntil;
    if (cd != null && tMs < cd) return false;

    final p = _profile;
    if (p != null) {
      if (SnatchPolicy.abort(ctx)) {
        reset();
        return false;
      }
      final g = _grabAtMs!;
      if (tMs - g > p.followWindowMs) {
        final total = _early + _late;
        final fired = total >= p.minFollowSamples &&
            _late > 0 &&
            (_earlyMoving + _lateMoving) / total >= p.runFraction &&
            _lateMoving / _late >= p.lateRunFraction;
        reset();
        if (fired) _cooldownUntil = tMs + SnatchPolicy.cooldownMs;
        return fired;
      }
      final moving = magnitude >= p.runThreshold;
      if (tMs - g <= p.followWindowMs ~/ 2) {
        _early++;
        if (moving) _earlyMoving++;
      } else {
        _late++;
        if (moving) _lateMoving++;
      }
      return false;
    }

    // Not armed: look for a debounced grab (2 strong samples close together).
    final spike = _spikeAtMs;
    if (spike != null && tMs - spike > SnatchPolicy.debounceMs) {
      _spikeAtMs = null;
    }
    final first = _spikeAtMs == null;
    final want = SnatchPolicy.profileFor(ctx,
        restBefore: first ? restBefore : _spikeRest);
    if (want == null || magnitude < want.grabThreshold) return false;
    if (first) {
      _spikeAtMs = tMs;
      _spikeRest = restBefore;
      return false;
    }
    _profile = want;
    _grabAtMs = tMs;
    _spikeAtMs = null;
    _early = 0;
    _earlyMoving = 0;
    _late = 0;
    _lateMoving = 0;
    return false;
  }

  void reset() {
    _profile = null;
    _grabAtMs = null;
    _spikeAtMs = null;
    _early = 0;
    _earlyMoving = 0;
    _late = 0;
    _lateMoving = 0;
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

/// at-falsealarm — Dart mirror of the native SIM-baseline rules
/// (android_overlay/.../antitheft/SimBaseline.kt). Keep both in sync; this
/// copy is what the unit test exercises (no kotlinc on the build box).
///
/// Slot identity: '' = empty slot, null = not readable yet (skip this round,
/// never guess), 's<subId>:<mccmnc>' on Android 10+, 'op:<mccmnc>' on 8–9.
class SimBaselineRules {
  static const int absent = 1; // TelephonyManager.SIM_STATE_ABSENT
  static const int ready = 5; // SIM_STATE_READY
  static const int loaded = 10; // SIM_STATE_LOADED (hidden on some levels)

  static String? slotIdentity(int state, List<int>? subIds, String? mccmnc) {
    if (state == absent) return '';
    if (state != ready && state != loaded) return null;
    final op = (mccmnc ?? '').trim();
    if (subIds == null) return op.isEmpty ? null : 'op:$op';
    final valid = subIds.where((s) => s >= 0);
    if (valid.isEmpty) return null;
    return 's${valid.first}:${op.isEmpty ? '?' : op}';
  }

  static Set<String>? snapshot(List<String?> slots) {
    final out = <String>{};
    for (final s in slots) {
      if (s == null) return null;
      if (s.isNotEmpty) out.add(s);
    }
    return out;
  }

  static String encode(Set<String> s) => (s.toList()..sort()).join(',');

  static Set<String> decode(String? s) => (s ?? '')
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toSet();

  /// Returns 'inserted', 'removed' or null (no alert).
  static String? evaluate(
      Set<String> baseline, Set<String> lastSeen, Set<String> current) {
    final inserted =
        current.where((x) => !baseline.contains(x) && !lastSeen.contains(x));
    final removed =
        baseline.where((x) => lastSeen.contains(x) && !current.contains(x));
    if (inserted.isNotEmpty) return 'inserted';
    if (removed.isNotEmpty) return 'removed';
    return null;
  }
}

/// at-falsealarm — the native engine's SIM pipeline as a pure state machine
/// (mirrors AntiTheftService.checkSim + its receiver). The tests use it to
/// prove the end-to-end rules: the initial sticky broadcast is ignored, the
/// first readable snapshot is a SILENT baseline, transitions are debounced,
/// and only a real change vs the baseline alerts.
class SimEngineModel {
  String? base; // null = no baseline stored (first arm / reinstall)
  String? seen;
  final List<String> alerts = [];
  bool _pending = false;

  /// Switching protection on (Dart passes rebaseline: true).
  void armRebaseline() {
    base = null;
    seen = null;
    _pending = true;
  }

  /// A fresh service start (relaunch re-arm): compares, never re-baselines.
  void serviceStart() => _pending = true;

  /// A SIM_STATE_CHANGED broadcast. [initialSticky] = the copy Android hands
  /// a newly registered receiver (the current state, not an event).
  void onBroadcast({bool initialSticky = false}) {
    if (initialSticky) return;
    _pending = true; // debounced: evaluated once, ~8 s after the last one
  }

  /// The debounce timer fired; [slots] = per-slot identities now.
  void debounceFired(List<String?> slots) {
    if (!_pending) return;
    final cur = SimBaselineRules.snapshot(slots);
    if (cur == null) return; // unreadable: stays pending, retried later
    _pending = false;
    final enc = SimBaselineRules.encode(cur);
    if (base == null) {
      base = enc;
      seen = enc;
      return; // silent baseline
    }
    final b = SimBaselineRules.decode(base);
    final v = SimBaselineRules.evaluate(
        b, seen == null ? b : SimBaselineRules.decode(seen), cur);
    seen = enc;
    if (v != null) alerts.add(v);
  }
}

/// at-heartbeat — when may the always-on engine be brought back? Mirrors
/// android_overlay/.../antitheft/RestartPolicy.kt 1:1 (keep in sync).
///   'app'    the owner opened / resumed Assisto: always.
///   'update' MY_PACKAGE_REPLACED, 'boot' BOOT_COMPLETED: Android 8-13 yes;
///            Android 14+ only with background location (a location
///            foreground service can't start from the background without it),
///            otherwise a "tap to resume" notification.
/// A background restart never declares the camera type, and NO restart ever
/// re-records the SIM baseline (only switching protection on does).
class RestartRules {
  static const app = 'app';
  static const update = 'update';
  static const boot = 'boot';

  static bool canStart(String trigger, int sdk, bool hasBackgroundLocation) {
    if (trigger == app) return true;
    if (trigger != update && trigger != boot) return false;
    if (sdk >= 34) return hasBackgroundLocation;
    return true;
  }

  static bool allowCamera(String trigger) => trigger == app;

  static bool needsTapToResume(
          String trigger, int sdk, bool hasBackgroundLocation) =>
      (trigger == update || trigger == boot) &&
      !canStart(trigger, sdk, hasBackgroundLocation);
}
