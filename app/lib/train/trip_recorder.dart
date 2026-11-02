import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';

import 'train_fgs.dart';
import 'trip_trace.dart';

/// sjalarm PROOF: the OWNER-ONLY trip recorder (flag `trip_recorder`, shown
/// only as an owner / staff / allow-list preview). Records the real GPS of a
/// trip — time, position, accuracy, speed, bearing — ON THE PHONE, in the
/// same JSON the CI replay reads (+ GPX). Nothing leaves the phone unless the
/// owner taps Share or "Upload privately". Keeps running with the screen off
/// through the existing train location service (with a Stop button).
typedef TracePointStream = Stream<TracePoint> Function();
typedef TraceDirFn = Future<Directory> Function();

@immutable
class TripRecState {
  final bool recording;
  final String mode;
  final int points;
  final double? lastAcc;
  final bool stopMarked;
  final bool serviceOn;
  const TripRecState(
      {this.recording = false,
      this.mode = 'cityBus',
      this.points = 0,
      this.lastAcc,
      this.stopMarked = false,
      this.serviceOn = false});
}

class TripRecorder extends ValueNotifier<TripRecState> {
  TripRecorder({TracePointStream? stream, TraceDirFn? dir, this.useService = true})
      : _stream = stream ?? _gpsStream,
        _dir = dir ?? _docsDir,
        super(const TripRecState());

  static TripRecorder I = TripRecorder();

  final TracePointStream _stream;
  final TraceDirFn _dir;
  final bool useService;
  StreamSubscription<TracePoint>? _sub;
  final List<TracePoint> _pts = [];
  TracePoint? _stop;
  File? _file;
  Timer? _flush;

  List<TracePoint> get points => List.unmodifiable(_pts);

  Future<Directory> folder() async {
    final d = Directory('${(await _dir()).path}/trip_traces');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  Future<void> start(String mode, {String title = '', String text = '', String stopLabel = ''}) async {
    if (value.recording) return;
    _pts.clear();
    _stop = null;
    final now = DateTime.now().toUtc();
    final stamp = now.toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    _file = File('${(await folder()).path}/trip_${stamp}_$mode.json');
    var svc = false;
    if (useService) {
      svc = await TrainFgs.I.acquire('recorder', (msg) {
        if (msg == kTrainStopMsg) unawaited(stop());
      }, title: title, text: text, stopLabel: stopLabel);
    }
    value = TripRecState(recording: true, mode: mode, serviceOn: svc);
    _sub = _stream().listen((p) {
      _pts.add(p);
      value = TripRecState(
          recording: true,
          mode: mode,
          points: _pts.length,
          lastAcc: p.acc,
          stopMarked: _stop != null,
          serviceOn: value.serviceOn);
    }, onError: (Object _) {
      // best-effort: GPS hiccup; the stream keeps the points it has
    });
    // never lose a long trip to a crash: write what we have every 30 s
    _flush = Timer.periodic(const Duration(seconds: 30), (_) => unawaited(_write()));
  }

  /// "I got off here (my stop)": the newest fix becomes the stop.
  bool markStop() {
    if (_pts.isEmpty) return false;
    _stop = _pts.last;
    value = TripRecState(
        recording: value.recording,
        mode: value.mode,
        points: _pts.length,
        lastAcc: value.lastAcc,
        stopMarked: true,
        serviceOn: value.serviceOn);
    return true;
  }

  TripTrace _trace() {
    final t = TripTrace(mode: value.mode, points: List.of(_pts), setM: _setFor(value.mode),
        note: 'REAL trip recorded with the Assisto trip recorder (owner).');
    final s = _stop;
    return s == null ? t : t.withStop(s.lat, s.lng, 'stop');
  }

  Future<void> _write() async {
    final f = _file;
    if (f == null || _pts.isEmpty) return;
    try {
      await f.writeAsString(_trace().encode(), flush: true);
    } catch (_) {
      // best-effort: the next flush / stop writes again
    }
  }

  /// Stops and saves JSON + GPX. Returns the JSON file (null: no points).
  Future<File?> stop() async {
    if (!value.recording) return null;
    _flush?.cancel();
    _flush = null;
    await _sub?.cancel();
    _sub = null;
    final f = _file;
    File? out;
    if (f != null && _pts.isNotEmpty) {
      await _write();
      try {
        await File(f.path.replaceAll(RegExp(r'\.json$'), '.gpx')).writeAsString(_trace().toGpx());
      } catch (_) {
        // best-effort: JSON is the proof file; GPX is a convenience
      }
      out = f;
    }
    if (useService) await TrainFgs.I.release('recorder');
    value = const TripRecState();
    return out;
  }

  /// Saved trips on this phone, newest first.
  Future<List<File>> saved() async {
    final d = await folder();
    final l = d.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    return l;
  }

  Future<void> delete(File f) async {
    for (final x in [f, File(f.path.replaceAll(RegExp(r'\.json$'), '.gpx'))]) {
      try {
        if (x.existsSync()) await x.delete();
      } catch (_) {
        // best-effort: already gone
      }
    }
  }
}

int _setFor(String mode) => switch (mode) {
      'longBus' || 'train' || 'launch' => 2000,
      'walking' => 100,
      _ => 10,
    };

Future<Directory> _docsDir() => getApplicationDocumentsDirectory();

Stream<TracePoint> _gpsStream() {
  final LocationSettings settings = defaultTargetPlatform == TargetPlatform.android
      ? AndroidSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 0,
          intervalDuration: const Duration(seconds: 1))
      : const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 0);
  return Geolocator.getPositionStream(locationSettings: settings).map((p) => TracePoint(
      p.timestamp.toUtc(), p.latitude, p.longitude, p.accuracy,
      speed: (p.speed.isFinite && p.speed >= 0) ? p.speed : null,
      bearing: (p.heading.isFinite && p.heading >= 0) ? p.heading : null));
}
