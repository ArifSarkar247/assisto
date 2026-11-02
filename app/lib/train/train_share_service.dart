import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'train_fgs.dart';

/// train: "I am on this train" — the passenger's location is shared ONLY
/// while sharing is on (location foreground service with a Stop button),
/// and stops by itself when the server says arrived / ended. Fixes are sent
/// in small batches; the server validates every one (rail line, speed,
/// direction, timetable) and keeps only the last accepted fix.
class TrainFix {
  final double lat, lng, acc;
  final double? speedKmh, bearing;
  final DateTime at;
  const TrainFix(this.lat, this.lng, this.acc, this.at, {this.speedKmh, this.bearing});

  Map<String, dynamic> toJson() => {
        'lat': lat,
        'lng': lng,
        'acc': acc,
        'at': at.toUtc().toIso8601String(),
        if (speedKmh != null) 'speed_kmh': speedKmh,
        if (bearing != null) 'bearing': bearing,
      };
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
  const TrainShareState(
      {this.shareId,
      this.trainNo = '',
      this.status = 'off',
      this.accepted = 0,
      this.rejected = 0,
      this.queued = 0,
      this.offline = false});
}

class TrainShareController extends ValueNotifier<TrainShareState> {
  TrainShareController({TrainPositionFn? position, this.useService = true})
      : _position = position ?? _gps,
        super(const TrainShareState());

  static TrainShareController I = TrainShareController();
  static const Duration every = Duration(seconds: 20);
  static const int maxQueue = 90;

  final TrainPositionFn _position;
  final bool useService;
  TrainSendFn? _send;
  Future<void> Function(int shareId)? _stopRemote;
  Timer? _timer;
  bool _busy = false;
  final List<TrainFix> _q = [];

  bool get sharing => value.status == 'active';

  Future<void> start(int shareId, String trainNo, TrainSendFn send,
      {required Future<void> Function(int shareId) stopRemote,
      required String title,
      required String text,
      required String stopLabel}) async {
    await stop(remote: false);
    _send = send;
    _stopRemote = stopRemote;
    value = TrainShareState(shareId: shareId, trainNo: trainNo, status: 'active');
    if (useService) {
      await TrainFgs.I.acquire('share', _onFgs, title: title, text: text, stopLabel: stopLabel);
    }
    _timer = Timer.periodic(every, (_) => tick());
    await tick();
  }

  void _onFgs(String msg) {
    if (msg == kTrainStopMsg) unawaited(stop());
  }

  Future<void> tick() async {
    final id = value.shareId, send = _send;
    if (_busy || id == null || send == null || value.status != 'active') return;
    _busy = true;
    try {
      TrainFix? f;
      try {
        f = await _position();
      } catch (_) {
        f = null; // best-effort: no fix this round
      }
      if (f != null) {
        _q.add(f);
        if (_q.length > maxQueue) _q.removeAt(0);
      }
      if (_q.isEmpty) return;
      final batch = List<TrainFix>.of(_q);
      Map<String, dynamic> r;
      try {
        r = await send(id, batch.map((x) => x.toJson()).toList());
      } catch (_) {
        value = _copy(offline: true);
        return; // keep the queue for the next round
      }
      _q.removeRange(0, batch.length);
      final status = '${r['status'] ?? 'active'}';
      value = TrainShareState(
          shareId: id,
          trainNo: value.trainNo,
          status: status,
          accepted: value.accepted + ((r['accepted'] as num?)?.toInt() ?? 0),
          rejected: value.rejected + ((r['rejected'] as num?)?.toInt() ?? 0));
      if (status != 'active') await _end(status);
    } finally {
      _busy = false;
    }
  }

  TrainShareState _copy({bool? offline}) => TrainShareState(
      shareId: value.shareId,
      trainNo: value.trainNo,
      status: value.status,
      accepted: value.accepted,
      rejected: value.rejected,
      queued: _q.length,
      offline: offline ?? value.offline);

  Future<void> _end(String status) async {
    _timer?.cancel();
    _timer = null;
    _q.clear();
    if (useService) await TrainFgs.I.release('share');
    value = TrainShareState(
        shareId: value.shareId,
        trainNo: value.trainNo,
        status: status,
        accepted: value.accepted,
        rejected: value.rejected);
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
}

Future<TrainFix?> _gps() async {
  if (!await Geolocator.isLocationServiceEnabled()) return null;
  final perm = await Geolocator.checkPermission();
  if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
    return null;
  }
  final p = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)));
  return TrainFix(p.latitude, p.longitude, p.accuracy, DateTime.now(),
      speedKmh: p.speed >= 0 ? p.speed * 3.6 : null,
      bearing: p.heading >= 0 ? p.heading : null);
}
