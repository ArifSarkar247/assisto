import 'dart:convert';
import 'dart:math' as math;

/// train: destination-alarm maths — pure, offline, unit-tested with fixed
/// coordinates. No network: stations come from the bundled
/// assets/train/stations_bd.json (OpenStreetMap, ODbL).

/// The radius choices on screen; "custom" is any value in [kCustomMin, kCustomMax].
const List<int> kRadiusPresets = [1000, 500, 300, 100];
const int kCustomMin = 50;
const int kCustomMax = 5000;

/// GPS interval bounds (battery): never faster than [kMinInterval], never
/// slower than [kMaxInterval]; on low battery the far-away interval is
/// stretched but the near zone stays fast (safety first).
const Duration kMinInterval = Duration(seconds: 5);
const Duration kMaxInterval = Duration(seconds: 120);
const int kLowBatteryPct = 15;

/// Assumed fastest approach (a train at ~110 km/h) when GPS gives no speed.
const double kAssumeSpeedMps = 30.0;

double haversineM(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
  final dp = p2 - p1, dl = (lng2 - lng1) * math.pi / 180;
  final h = math.pow(math.sin(dp / 2), 2) +
      math.cos(p1) * math.cos(p2) * math.pow(math.sin(dl / 2), 2);
  return 2 * r * math.asin(math.min(1.0, math.sqrt(h)));
}

int clampRadius(int m) => m.clamp(kCustomMin, kCustomMax);

/// Inside the alarm zone? A fix whose accuracy is worse than the zone itself
/// (and worse than 300 m) is not trusted to fire.
bool insideZone(double distanceM, int radiusM, {double accuracyM = 0}) {
  if (accuracyM > math.max(300, radiusM)) return false;
  return distanceM <= radiusM;
}

/// Adaptive GPS interval: far = slow, near = fast. Next check at a third of
/// the fastest time to reach the zone edge, within the bounds.
Duration adaptiveInterval(double distanceM, int radiusM,
    {double? speedMps, int? batteryPct}) {
  final toEdge = distanceM - radiusM;
  if (toEdge <= radiusM) return kMinInterval; // within 2x radius: fast
  final v = math.max(speedMps ?? 0, kAssumeSpeedMps);
  var s = (toEdge / v / 3).round();
  if (batteryPct != null && batteryPct <= kLowBatteryPct) s = (s * 1.5).round();
  s = s.clamp(kMinInterval.inSeconds, kMaxInterval.inSeconds);
  return Duration(seconds: s);
}

/// Total GPS checks for a straight approach from [startM] at [speedMps]
/// (used by the battery test: far trips must stay cheap).
int checksForTrip(double startM, int radiusM, double speedMps, {int? batteryPct}) {
  var d = startM;
  var n = 0;
  while (d > radiusM && n < 100000) {
    final dt = adaptiveInterval(d, radiusM, speedMps: speedMps, batteryPct: batteryPct);
    d -= speedMps * dt.inSeconds;
    n++;
  }
  return n;
}

class DestStation {
  final String id, en, bn;
  final double lat, lng;
  const DestStation(this.id, this.en, this.bn, this.lat, this.lng);

  String name(bool bnLang) => bnLang && bn.isNotEmpty ? bn : en;
}

List<DestStation> parseStations(String raw) {
  final j = jsonDecode(raw) as Map<String, dynamic>;
  final out = <DestStation>[];
  for (final s in (j['stations'] as List? ?? const [])) {
    if (s is! Map) continue;
    final lat = (s['lat'] as num?)?.toDouble(), lng = (s['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) continue;
    out.add(DestStation('${s['id']}', '${s['en'] ?? ''}', '${s['bn'] ?? ''}', lat, lng));
  }
  return out;
}

/// Name search (Bangla or English, case-insensitive), nearest first when a
/// position is known.
List<DestStation> searchStations(List<DestStation> all, String q,
    {double? lat, double? lng, int limit = 40}) {
  final k = q.trim().toLowerCase();
  final hits = all
      .where((s) => k.isEmpty || s.en.toLowerCase().contains(k) || s.bn.contains(k))
      .toList();
  if (lat != null && lng != null) {
    hits.sort((a, b) =>
        haversineM(lat, lng, a.lat, a.lng).compareTo(haversineM(lat, lng, b.lat, b.lng)));
  } else {
    hits.sort((a, b) => a.en.compareTo(b.en));
  }
  return hits.take(limit).toList();
}
