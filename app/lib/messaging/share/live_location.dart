import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api.dart';
import '../../services/error_report.dart';
import 'share_payload.dart';

/// mc-media2 — LIVE location, honestly FOREGROUND-ONLY.
///
/// While Assisto is open on the sender's phone, every [tick] the phone reads
/// one position (the existing location permission; never in the background,
/// no new permission) and — when it moved or a while passed — re-encrypts it
/// into the SAME message for every recipient (POST /circle/live/<id>). When
/// Assisto is closed or in the background nothing is read or sent; the
/// receivers see "updated N min ago". The share ends by itself at `until` on
/// every phone; "Stop sharing" sends one last "stopped" update.
class LiveSession {
  final String chatKind; // member | group
  final int chatId;
  final String messageId;
  final String fallback; // the readable first line of the message
  LocationShare last;
  int lastPushMs;
  bool stopping;

  LiveSession({
    required this.chatKind,
    required this.chatId,
    required this.messageId,
    required this.fallback,
    required this.last,
    this.lastPushMs = 0,
    this.stopping = false,
  });

  int get until => last.until;

  Map<String, dynamic> toJson() => {
        'ck': chatKind,
        'chat': chatId,
        'mid': messageId,
        'fb': fallback,
        'loc': last.toJson(),
        'push': lastPushMs,
        if (stopping) 'stop': 1,
      };

  static LiveSession? fromJson(Map j) {
    final loc = j['loc'] is Map ? LocationShare.fromJson(j['loc'] as Map) : null;
    final chat = j['chat'] is num ? (j['chat'] as num).toInt() : null;
    final mid = '${j['mid'] ?? ''}';
    if (loc == null || !loc.live || chat == null || mid.isEmpty) return null;
    return LiveSession(
      chatKind: '${j['ck']}' == 'group' ? 'group' : 'member',
      chatId: chat,
      messageId: mid,
      fallback: '${j['fb'] ?? ''}',
      last: loc,
      lastPushMs: j['push'] is num ? (j['push'] as num).toInt() : 0,
      stopping: j['stop'] == 1,
    );
  }
}

/// Reads ONE position (null = no permission / GPS off / timed out).
typedef LivePositionSource = Future<LocationShare?> Function();

/// Sends the newest plaintext into the live message.
typedef LiveTransport = Future<void> Function(LiveSession s, String plaintext);

/// Metres between two points (haversine).
double distanceM(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLng = rad(lng2 - lng1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.sin(dLng / 2) * math.sin(dLng / 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}

class LiveLocation with WidgetsBindingObserver {
  LiveLocation({
    this.positions,
    this.transport,
    DateTime Function()? clock,
    this.tick = const Duration(seconds: 30),
    this.minMoveM = 15,
    this.maxQuiet = const Duration(minutes: 2),
    this.persist = true,
  }) : clock = clock ?? DateTime.now;

  static LiveLocation instance = LiveLocation();

  LivePositionSource? positions;
  LiveTransport? transport;
  final DateTime Function() clock;
  final Duration tick;
  final double minMoveM;
  final Duration maxQuiet;
  final bool persist;

  static const _kPrefs = 'mc2_live_sessions_v1';

  /// Active sessions on THIS phone, by message id (the cards listen).
  final ValueNotifier<Map<String, LiveSession>> sessions = ValueNotifier(const {});

  Timer? _timer;
  bool _observing = false;
  bool _restored = false;
  bool _busy = false;
  bool _foreground = true;

  bool isActive(String messageId) => sessions.value.containsKey(messageId);

  /// Wire the real position reader + sender (lazy: the first chat that
  /// opens, or the first live share).
  void configure({required LivePositionSource positions, required LiveTransport transport}) {
    this.positions ??= positions;
    this.transport ??= transport;
  }

  /// Load persisted sessions (an app restart during a share) and drop the
  /// ones that ended. Safe to call often.
  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    _observe();
    if (!persist) return;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kPrefs);
      if (raw == null || raw.isEmpty) return;
      final out = <String, LiveSession>{...sessions.value};
      for (final j in (jsonDecode(raw) as List).whereType<Map>()) {
        final s = LiveSession.fromJson(j);
        if (s != null && !_ended(s)) out[s.messageId] = s;
      }
      sessions.value = out;
      _arm();
    } catch (e) {
      reportNonFatal('mc2_live_restore', e);
    }
  }

  bool _ended(LiveSession s) => clock().millisecondsSinceEpoch >= s.until;

  /// Start updating a just-sent live message ([first] = the sent point).
  Future<void> start(LiveSession s) async {
    _observe();
    s.lastPushMs = clock().millisecondsSinceEpoch;
    sessions.value = {...sessions.value, s.messageId: s};
    await _save();
    _arm();
  }

  /// "Stop sharing": one last update with `stop` (retried on the next ticks
  /// while offline; given up at the share's own end time).
  Future<bool> stop(String messageId) async {
    final s = sessions.value[messageId];
    if (s == null) return true;
    s.stopping = true;
    await _save();
    final ok = await _push(s, s.last.copyWith(stopped: true, seq: s.last.seq + 1));
    if (ok) _remove(messageId);
    return ok;
  }

  /// One update round (also called by the timer). Visible for tests.
  Future<void> runOnce() async {
    if (_busy || sessions.value.isEmpty) return;
    _busy = true;
    try {
      LocationShare? pos;
      var asked = false;
      for (final s in sessions.value.values.toList()) {
        if (_ended(s)) {
          _remove(s.messageId);
          continue;
        }
        if (s.stopping) {
          if (await _push(s, s.last.copyWith(stopped: true, seq: s.last.seq + 1))) {
            _remove(s.messageId);
          }
          continue;
        }
        if (!asked) {
          asked = true;
          try {
            pos = await positions?.call();
          } catch (e) {
            pos = null;
          }
        }
        final p = pos;
        if (p == null) continue; // no fix this round: try again next tick
        final now = clock().millisecondsSinceEpoch;
        final moved = distanceM(s.last.lat, s.last.lng, p.lat, p.lng);
        final quiet = now - s.lastPushMs >= maxQuiet.inMilliseconds;
        if (moved < minMoveM && !quiet) continue;
        await _push(
            s,
            s.last.copyWith(
                lat: p.lat, lng: p.lng, accuracy: p.accuracy, at: now, seq: s.last.seq + 1));
      }
      await _save();
    } finally {
      _busy = false;
    }
  }

  Future<bool> _push(LiveSession s, LocationShare next) async {
    final t = transport;
    if (t == null) return false;
    try {
      await t(s, encodeLocation(next, s.fallback));
      s.last = next;
      s.lastPushMs = clock().millisecondsSinceEpoch;
      sessions.value = {...sessions.value};
      return true;
    } on ApiException catch (e) {
      // the message can't be updated any more (deleted / left / past 8 h)
      if (e.status == 404 || e.status == 403 || e.status == 409) {
        _remove(s.messageId);
        return true;
      }
      return false; // 429 / offline: next tick
    } catch (e) {
      reportNonFatal('mc2_live_push', e);
      return false;
    }
  }

  void _remove(String id) {
    if (!sessions.value.containsKey(id)) return;
    sessions.value = {...sessions.value}..remove(id);
    unawaited(_save());
    if (sessions.value.isEmpty) _disarm();
  }

  Future<void> _save() async {
    if (!persist) return;
    try {
      final p = await SharedPreferences.getInstance();
      final list = [for (final s in sessions.value.values) s.toJson()];
      if (list.isEmpty) {
        await p.remove(_kPrefs);
      } else {
        await p.setString(_kPrefs, jsonEncode(list));
      }
    } catch (e) {
      reportNonFatal('mc2_live_save', e);
    }
  }

  void _observe() {
    if (_observing) return;
    _observing = true;
    try {
      WidgetsBinding.instance.addObserver(this);
      final ls = WidgetsBinding.instance.lifecycleState;
      _foreground = ls == null || ls == AppLifecycleState.resumed;
    } catch (_) {}
  }

  void _arm() {
    if (sessions.value.isEmpty || !_foreground) return;
    _timer ??= Timer.periodic(tick, (_) => unawaited(runOnce()));
  }

  void _disarm() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // FOREGROUND ONLY: nothing is read or sent while Assisto is not open.
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _arm();
      unawaited(runOnce());
    } else {
      _disarm();
    }
  }

  @visibleForTesting
  bool get timerArmed => _timer != null;

  @visibleForTesting
  void reset() {
    _disarm();
    sessions.value = const {};
    _restored = false;
  }
}
