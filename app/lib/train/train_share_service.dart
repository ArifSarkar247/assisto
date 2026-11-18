import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'train_fgs.dart';
import 'train_v2_native.dart';

/// train: "I am on this train" — the passenger's location is shared ONLY
/// while sharing is on (location foreground service with a visible
/// notification and a Stop button), and stops by itself at the last
/// station / when the server says arrived or ended. Never silent, never in
/// the background without that notification (no background-location
/// permission).
///
/// train-app (Train Tracker V2):
///  * one point every 30 s (60 s + medium accuracy when the battery is under
///    20 % and not charging);
///  * each point says whether Android marked it as a MOCK location (the
///    server refuses those);
///  * with the rider's extra yes, the serving cell tower goes with the
///    point (teaches the tower-to-track map; no READ_PHONE_STATE);
///  * points made without internet are SAVED on the phone (up to 2 h) and
///    sent, marked `queued`, when the internet returns — even after a
///    restart of the app;
///  * auto-stop: within 800 m of the last station, or at the trip's end time.
class TrainFix {
  final double lat, lng, acc;
  final double? speedKmh, bearing;
  final DateTime at;
  final bool mock;
  final TrainCell? cell;
  const TrainFix(this.lat, this.lng, this.acc, this.at,
      {this.speedKmh, this.bearing, this.mock = false, this.cell});

  TrainFix withCell(TrainCell? c) =>
      TrainFix(lat, lng, acc, at, speedKmh: speedKmh, bearing: bearing, mock: mock, cell: c);

  Map<String, dynamic> toJson({bool queued = false}) => {
        'lat': lat,
        'lng': lng,
        'acc': acc,
        'at': at.toUtc().toIso8601String(),
        if (speedKmh != null) 'speed_kmh': speedKmh,
        if (bearing != null) 'bearing': bearing,
        'mock': mock,
        if (cell != null) 'cell': cell!.toJson(),
        if (queued) 'queued': true,
      };

  static TrainFix? fromJson(Map j) {
    final lat = (j['lat'] as num?)?.toDouble(), lng = (j['lng'] as num?)?.toDouble();
    final at = DateTime.tryParse('${j['at']}');
    if (lat == null || lng == null || at == null) return null;
    return TrainFix(lat, lng, (j['acc'] as num?)?.toDouble() ?? 0, at.toLocal(),
        speedKmh: (j['speed_kmh'] as num?)?.toDouble(),
        bearing: (j['bearing'] as num?)?.toDouble(),
        mock: j['mock'] == true,
        cell: TrainCell.fromMap(j['cell']));
  }
}

typedef TrainPositionFn = Future<TrainFix?> Function();
typedef TrainSendFn = Future<Map<String, dynamic>> Function(
    int shareId, List<Map<String, dynamic>> points);

@immutable
class TrainShareState {
  final int? shareId;
  final String trainNo;
  final String status; // off | active | arrived | ended
  final int accepted, rejected, queued;
  final bool offline;

  /// battery saver on (60 s)
  final bool saver;

  /// why it started: user | alarm | ask (the "Are you on this train?" prompt)
  final String by;
  final DateTime? lastSentAt;
  const TrainShareState(
      {this.shareId,
      this.trainNo = '',
      this.status = 'off',
      this.accepted = 0,
      this.rejected = 0,
      this.queued = 0,
      this.offline = false,
      this.saver = false,
      this.by = 'user',
      this.lastSentAt});

  TrainShareState copyWith(
          {String? status,
          int? accepted,
          int? rejected,
          int? queued,
          bool? offline,
          bool? saver,
          DateTime? lastSentAt}) =>
      TrainShareState(
          shareId: shareId,
          trainNo: trainNo,
          status: status ?? this.status,
          accepted: accepted ?? this.accepted,
          rejected: rejected ?? this.rejected,
          queued: queued ?? this.queued,
          offline: offline ?? this.offline,
          saver: saver ?? this.saver,
          by: by,
          lastSentAt: lastSentAt ?? this.lastSentAt);
}

double trainDistM(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final dLat = (lat2 - lat1) * math.pi / 180, dLng = (lng2 - lng1) * math.pi / 180;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) * math.cos(lat2 * math.pi / 180) * math.sin(dLng / 2) * math.sin(dLng / 2);
  return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
}

class TrainShareController extends ValueNotifier<TrainShareState> {
  TrainShareController(
      {TrainPositionFn? position, this.useService = true, TrainNative? native, bool persist = true})
      : _position = position ?? _gps,
        _native = native,
        _persist = persist,
        super(const TrainShareState());

  static TrainShareController I = TrainShareController();
  static const Duration every = Duration(seconds: 30);
  static const Duration everySaver = Duration(seconds: 60);

  /// 2 h of points at 30 s
  static const int maxQueue = 240;

  /// auto-stop this close to the last station
  static const double arriveM = 800;
  static const String _key = 'train_share_q_v2';

  final TrainPositionFn _position;
  final TrainNative? _native;
  final bool _persist;
  final bool useService;
  TrainSendFn? _send;
  Future<void> Function(int shareId)? _stopRemote;
  Timer? _timer;
  bool _busy = false;
  final List<TrainFix> _q = [];
  bool _cellOptIn = false;
  (double, double)? _last;
  DateTime? _endsAt;
  Duration _period = every;

  TrainNative get _nat => _native ?? TrainNative.I;
  bool get sharing => value.status == 'active';
  bool get cellOptIn => _cellOptIn;

  /// [lastStop] (lat, lng) of the final station: auto-stop there.
  /// [endsAt]: the server's end of the trip window.
  /// [cell]: the rider also said yes to sending the mobile tower.
  Future<void> start(int shareId, String trainNo, TrainSendFn send,
      {required Future<void> Function(int shareId) stopRemote,
      required String title,
      required String text,
      required String stopLabel,
      bool cell = false,
      (double, double)? lastStop,
      DateTime? endsAt,
      String by = 'user'}) async {
    await stop(remote: false);
    _send = send;
    _stopRemote = stopRemote;
    _cellOptIn = cell;
    _last = lastStop;
    _endsAt = endsAt;
    value = TrainShareState(shareId: shareId, trainNo: trainNo, status: 'active', by: by);
    if (useService) {
      await TrainFgs.I.acquire('share', _onFgs, title: title, text: text, stopLabel: stopLabel);
    }
    await _schedule();
    await tick();
  }

  Future<void> _schedule() async {
    var saver = false;
    if (useService) {
      try {
        saver = (await _nat.power()).low;
      } catch (_) {
        saver = false;
      }
    }
    final p = saver ? everySaver : every;
    if (value.saver != saver) value = value.copyWith(saver: saver);
    if (_timer != null && p == _period) return;
    _period = p;
    _timer?.cancel();
    _timer = Timer.periodic(p, (_) => tick());
  }

  void _onFgs(String msg) {
    if (msg == kTrainStopMsg) unawaited(stop());
  }

  Future<void> tick() async {
    final id = value.shareId, send = _send;
    if (_busy || id == null || send == null || value.status != 'active') return;
    _busy = true;
    try {
      if (_endsAt != null && DateTime.now().isAfter(_endsAt!)) {
        await _end('ended');
        return;
      }
      TrainFix? f;
      try {
        f = await _position();
        if (f != null && _cellOptIn) f = f.withCell(await _nat.servingCell());
      } catch (_) {
        f = null; // best-effort: no fix this round
      }
      var arrived = false;
      if (f != null) {
        _q.add(f);
        if (_q.length > maxQueue) _q.removeAt(0);
        final l = _last;
        if (l != null && !f.mock && trainDistM(f.lat, f.lng, l.$1, l.$2) <= arriveM) arrived = true;
      }
      if (_q.isEmpty) return;
      final batch = List<TrainFix>.of(_q);
      Map<String, dynamic> r;
      try {
        r = await send(id, [
          for (var i = 0; i < batch.length; i++)
            // everything but the newest point waited on the phone
            batch[i].toJson(queued: i < batch.length - 1 && value.offline)
        ]);
      } catch (_) {
        value = value.copyWith(offline: true, queued: _q.length);
        await _save();
        if (arrived) await _end('arrived');
        return; // keep the queue for the next round
      }
      _q.removeRange(0, batch.length);
      final status = '${r['status'] ?? 'active'}';
      value = value.copyWith(
          status: status,
          accepted: value.accepted + ((r['accepted'] as num?)?.toInt() ?? 0),
          rejected: value.rejected + ((r['rejected'] as num?)?.toInt() ?? 0),
          queued: 0,
          offline: false,
          lastSentAt: DateTime.now());
      await _save();
      if (status != 'active') {
        await _end(status);
      } else if (arrived) {
        await _end('arrived', tellServer: true);
      } else {
        unawaited(_schedule());
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _end(String status, {bool tellServer = false}) async {
    _timer?.cancel();
    _timer = null;
    final id = value.shareId;
    if (_q.isEmpty) await _clearSaved();
    if (useService) await TrainFgs.I.release('share');
    value = value.copyWith(status: status, queued: _q.length);
    if (tellServer && id != null) {
      try {
        await _stopRemote?.call(id);
      } catch (_) {
        // best-effort: the server also ends it after the trip
      }
    }
  }

  /// One tap: stop sharing now (tells the server, best-effort).
  Future<void> stop({bool remote = true}) async {
    final id = value.shareId;
    if (value.status != 'active') {
      _timer?.cancel();
      _timer = null;
      return;
    }
    await _end('ended');
    if (remote && id != null) {
      try {
        await _stopRemote?.call(id);
      } catch (_) {
        // best-effort: the server also ends it after the trip
      }
    }
  }

  // ---- the saved queue (survives an app restart)
  Future<void> _save() async {
    if (!_persist) return;
    try {
      final p = await SharedPreferences.getInstance();
      final id = value.shareId;
      if (_q.isEmpty || id == null) {
        await p.remove(_key);
        return;
      }
      await p.setString(
          _key, jsonEncode({'id': id, 'no': value.trainNo, 'pts': [for (final f in _q) f.toJson()]}));
    } catch (_) {
      // best-effort
    }
  }

  Future<void> _clearSaved() async {
    if (!_persist) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_key);
    } catch (_) {
      // best-effort
    }
  }

  /// On app start / when the internet returns: send points saved by an
  /// earlier run (marked queued; the server keeps those under 24 h only).
  Future<int> flushSaved(TrainSendFn send) async {
    if (!_persist || sharing) return 0;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw == null) return 0;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final pts = [
        for (final e in (j['pts'] as List? ?? const []))
          if (e is Map) TrainFix.fromJson(e)
      ].whereType<TrainFix>().where((f) => DateTime.now().difference(f.at).inHours < 24).toList();
      if (pts.isNotEmpty) {
        await send((j['id'] as num).toInt(), [for (final f in pts) f.toJson(queued: true)]);
      }
      await p.remove(_key);
      return pts.length;
    } catch (_) {
      return 0; // still offline: try next time
    }
  }
}

Future<TrainFix?> _gps() async {
  if (!await Geolocator.isLocationServiceEnabled()) return null;
  final perm = await Geolocator.checkPermission();
  if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
    return null;
  }
  final saver = TrainShareController.I.value.saver;
  final p = await Geolocator.getCurrentPosition(
      locationSettings: LocationSettings(
          accuracy: saver ? LocationAccuracy.medium : LocationAccuracy.high,
          timeLimit: const Duration(seconds: 20)));
  return TrainFix(p.latitude, p.longitude, p.accuracy, DateTime.now(),
      speedKmh: p.speed >= 0 ? p.speed * 3.6 : null,
      bearing: p.heading >= 0 ? p.heading : null,
      mock: p.isMocked);
}
