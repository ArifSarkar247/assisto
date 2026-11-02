import 'dart:convert';

import 'dest_alarm_decide.dart';
import 'dest_alarm_math.dart';

/// sjalarm PROOF (owner order 3 Nov, Card 2): one recorded GPS trace —
/// the owner's real trip (trip recorder) or a clearly marked SYNTHETIC one.
/// The SAME JSON shape is saved on the phone, uploaded privately and replayed
/// in CI (test/dest_trace_replay_test.dart), so a real trace drops straight
/// into app/test/testdata/dest_traces/.
const String kTraceFormat = 'assisto-trip-trace/1';

class TracePoint {
  final DateTime at;
  final double lat, lng, acc;
  final double? speed, bearing;
  const TracePoint(this.at, this.lat, this.lng, this.acc, {this.speed, this.bearing});

  Map<String, dynamic> toJson() => {
        't': at.toUtc().toIso8601String(),
        'lat': double.parse(lat.toStringAsFixed(7)),
        'lng': double.parse(lng.toStringAsFixed(7)),
        'acc': double.parse(acc.toStringAsFixed(1)),
        'speed': speed == null ? null : double.parse(speed!.toStringAsFixed(2)),
        if (bearing != null) 'bearing': double.parse(bearing!.toStringAsFixed(1)),
      };

  static TracePoint? fromJson(Object? j) {
    if (j is! Map) return null;
    final at = DateTime.tryParse('${j['t']}');
    final lat = (j['lat'] as num?)?.toDouble(), lng = (j['lng'] as num?)?.toDouble();
    if (at == null || lat == null || lng == null) return null;
    return TracePoint(at, lat, lng, ((j['acc'] as num?) ?? 0).toDouble(),
        speed: (j['speed'] as num?)?.toDouble(), bearing: (j['bearing'] as num?)?.toDouble());
  }
}

class TripTrace {
  /// cityBus / longBus / train / metro / launch / walking
  final String mode;
  final bool synthetic;
  final String note;

  /// Where the traveller got off ("I got off here") — the stop the alarm
  /// must ring BEFORE. Null while recording.
  final double? stopLat, stopLng;
  final String stopName;
  final int setM;
  final List<TracePoint> points;

  /// Replay expectations: ring at least [minLeadS] and at most [maxLeadS]
  /// seconds before arriving at the stop.
  final int minLeadS, maxLeadS;
  const TripTrace(
      {required this.mode,
      required this.points,
      this.synthetic = false,
      this.note = '',
      this.stopLat,
      this.stopLng,
      this.stopName = '',
      this.setM = 10,
      this.minLeadS = 15,
      this.maxLeadS = 900});

  TransportMode get transport => switch (mode) {
        'longBus' => TransportMode.longBus,
        'train' => TransportMode.train,
        'launch' => TransportMode.launch,
        _ => TransportMode.cityBus, // walking / city bus: the distance setting
      };

  TripTrace withStop(double lat, double lng, String name) => TripTrace(
      mode: mode,
      points: points,
      synthetic: synthetic,
      note: note,
      stopLat: lat,
      stopLng: lng,
      stopName: name,
      setM: setM,
      minLeadS: minLeadS,
      maxLeadS: maxLeadS);

  Map<String, dynamic> toJson() => {
        'format': kTraceFormat,
        'synthetic': synthetic,
        'note': note,
        'mode': mode,
        'set_m': setM,
        'stop': stopLat == null ? null : {'name': stopName, 'lat': stopLat, 'lng': stopLng},
        'expect': {'min_lead_s': minLeadS, 'max_lead_s': maxLeadS},
        'points': [for (final p in points) p.toJson()],
      };

  String encode() => jsonEncode(toJson());

  static TripTrace? decode(String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! Map || j['format'] != kTraceFormat) return null;
      final stop = j['stop'] is Map ? j['stop'] as Map : null;
      final ex = j['expect'] is Map ? j['expect'] as Map : const {};
      return TripTrace(
        mode: '${j['mode'] ?? 'cityBus'}',
        synthetic: j['synthetic'] == true,
        note: '${j['note'] ?? ''}',
        setM: ((j['set_m'] as num?) ?? 10).toInt(),
        stopLat: (stop?['lat'] as num?)?.toDouble(),
        stopLng: (stop?['lng'] as num?)?.toDouble(),
        stopName: '${stop?['name'] ?? ''}',
        minLeadS: ((ex['min_lead_s'] as num?) ?? 15).toInt(),
        maxLeadS: ((ex['max_lead_s'] as num?) ?? 900).toInt(),
        points: [
          for (final p in (j['points'] as List? ?? const []))
            if (TracePoint.fromJson(p) case final tp?) tp
        ],
      );
    } catch (_) {
      return null; // not a trace file
    }
  }

  /// GPX 1.1 for map tools (Google Earth, OsmAnd); speed/accuracy kept as
  /// extensions.
  String toGpx() {
    String esc(String s) =>
        s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
    final b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<gpx version="1.1" creator="Assisto trip recorder" '
          'xmlns="http://www.topografix.com/GPX/1/1">');
    if (stopLat != null) {
      b.writeln('<wpt lat="$stopLat" lon="$stopLng"><name>${esc(stopName)}</name></wpt>');
    }
    b.writeln('<trk><name>${esc('$mode${synthetic ? ' SYNTHETIC' : ''}')}</name><trkseg>');
    for (final p in points) {
      b.writeln('<trkpt lat="${p.lat}" lon="${p.lng}"><time>${p.at.toUtc().toIso8601String()}</time>'
          '<extensions><acc>${p.acc}</acc>${p.speed == null ? '' : '<speed>${p.speed}</speed>'}'
          '</extensions></trkpt>');
    }
    b.writeln('</trkseg></trk></gpx>');
    return b.toString();
  }
}

/// Result of replaying one trace through the live decision code.
class ReplayResult {
  final DateTime? ringAt, arriveAt;
  final RingReason reason;
  final double? ringDistanceM;
  final int fixesUsed;
  const ReplayResult(this.ringAt, this.arriveAt, this.reason, this.ringDistanceM, this.fixesUsed);

  /// Seconds the alarm rang before arriving (negative = late; null = never).
  int? get leadS => ringAt == null || arriveAt == null ? null : arriveAt!.difference(ringAt!).inSeconds;
}

/// When the traveller reached the stop: the first recorded fix within
/// [arriveM] of it, else the closest approach.
DateTime? traceArrival(TripTrace t, {double arriveM = 20}) {
  if (t.stopLat == null || t.points.isEmpty) return null;
  TracePoint? best;
  var bestD = double.infinity;
  for (final p in t.points) {
    final d = haversineM(p.lat, p.lng, t.stopLat!, t.stopLng!);
    if (d <= arriveM) return p.at;
    if (d < bestD) {
      bestD = d;
      best = p;
    }
  }
  return best?.at;
}

/// Replays [t] exactly like the controller: it only "sees" the fix that is
/// current when its adaptive GPS interval comes due (sparse sampling far
/// away, every 5 s near), feeding [DestEngine] — the code the phone runs.
ReplayResult replayTrace(TripTrace t, {int? setM, int? batteryPct, int etaS = kEtaRingS}) {
  final arrive = traceArrival(t);
  if (t.stopLat == null || t.points.isEmpty) {
    return const ReplayResult(null, null, RingReason.none, null, 0);
  }
  final eng = DestEngine(t.transport, setM ?? t.setM, t.stopLat!, t.stopLng!, etaS: etaS);
  var due = t.points.first.at;
  var used = 0;
  for (final p in t.points) {
    if (p.at.isBefore(due)) continue;
    used++;
    final st = eng.step(p.lat, p.lng, p.acc, p.at, gpsSpeedMps: p.speed, batteryPct: batteryPct);
    if (st.event == AlarmEvent.ring) {
      return ReplayResult(p.at, arrive, st.reason, st.distanceM, used);
    }
    due = p.at.add(st.next);
  }
  return ReplayResult(null, arrive, RingReason.none, null, used);
}
