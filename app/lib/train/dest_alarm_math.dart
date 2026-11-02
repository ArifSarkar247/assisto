import 'dart:convert';
import 'dart:math' as math;

/// train: destination-alarm maths (owner final order 2 Nov) — pure, offline,
/// unit-tested with fixed coordinates. The alarm rings BEFORE the vehicle
/// reaches the stop. No network: stations / bus stops / metro order are
/// bundled in assets/train/ (OpenStreetMap ODbL; metro order Wikipedia).

enum TransportMode { cityBus, longBus, train, metro, launch }

class ModeSpec {
  final int defaultM, minM, maxM;

  /// City bus: one gentle vibration this many metres before the set distance.
  final int gentleBeforeM;

  /// Long bus / launch: a "get ready" notice at [readyAtM] on trips longer
  /// than [readyMinTripM].
  final int readyAtM, readyMinTripM;
  const ModeSpec(this.defaultM, this.minM, this.maxM,
      {this.gentleBeforeM = 0, this.readyAtM = 0, this.readyMinTripM = 0});
}

const Map<TransportMode, ModeSpec> kModeSpecs = {
  TransportMode.cityBus: ModeSpec(10, 10, 5000, gentleBeforeM: 200),
  TransportMode.longBus: ModeSpec(2000, 500, 20000, readyAtM: 10000, readyMinTripM: 30000),
  // train: rings when the train LEAVES the station before yours; this
  // distance is only the GPS fallback
  TransportMode.train: ModeSpec(2000, 500, 20000),
  // metro: counts stations + time (no GPS needed); distance not used
  TransportMode.metro: ModeSpec(0, 0, 0),
  TransportMode.launch: ModeSpec(2000, 500, 20000, readyAtM: 10000, readyMinTripM: 30000),
};

int clampFor(TransportMode m, int metres) {
  final s = kModeSpecs[m]!;
  return s.maxM == 0 ? 0 : metres.clamp(s.minM, s.maxM);
}

/// GPS interval bounds (battery): never faster than [kMinInterval], never
/// slower than [kMaxInterval]; low battery stretches only the far checks.
const Duration kMinInterval = Duration(seconds: 5);
const Duration kMaxInterval = Duration(seconds: 120);
const int kLowBatteryPct = 15;
const double kAssumeSpeedMps = 30.0;

double haversineM(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
  final dp = p2 - p1, dl = (lng2 - lng1) * math.pi / 180;
  final h = math.pow(math.sin(dp / 2), 2) +
      math.cos(p1) * math.cos(p2) * math.pow(math.sin(dl / 2), 2);
  return 2 * r * math.asin(math.min(1.0, math.sqrt(h)));
}

/// NEVER-LATE rule: a GPS fix is a circle; the user may be anywhere in it.
/// Ring as soon as the NEAREST possible position is within the set distance:
/// (distance − accuracy) ≤ set. Poor accuracy therefore rings EARLY, never late.
bool neverLate(double distanceM, double accuracyM, int setM) =>
    distanceM - math.max(0.0, accuracyM) <= setM;

/// Adaptive GPS interval: far = slow, near = fast (by the nearest possible
/// position, so poor accuracy also checks faster).
Duration adaptiveInterval(double distanceM, int setM,
    {double accuracyM = 0, double? speedMps, int? batteryPct}) {
  final toEdge = distanceM - math.max(0.0, accuracyM) - setM;
  final near = math.max(setM, 300);
  if (toEdge <= near) return kMinInterval;
  final v = math.max(speedMps ?? 0, kAssumeSpeedMps);
  var s = (toEdge / v / 3).round();
  if (batteryPct != null && batteryPct <= kLowBatteryPct) s = (s * 1.5).round();
  return Duration(seconds: s.clamp(kMinInterval.inSeconds, kMaxInterval.inSeconds));
}

/// Total GPS checks for a straight approach (battery test).
int checksForTrip(double startM, int setM, double speedMps, {int? batteryPct}) {
  var d = startM;
  var n = 0;
  while (d > setM && n < 100000) {
    d -= speedMps * adaptiveInterval(d, setM, speedMps: speedMps, batteryPct: batteryPct).inSeconds;
    n++;
  }
  return n;
}

enum AlarmEvent { none, gentle, ready, ring }

/// Distance modes (city bus / long bus / launch / train fallback): one step
/// per GPS fix. Each pre-alert fires once.
class DistanceWatch {
  final TransportMode mode;
  final int setM;
  double? tripStartM;
  bool gentleDone = false, readyDone = false, rung = false;
  DistanceWatch(this.mode, this.setM);

  AlarmEvent update(double distanceM, double accuracyM) {
    tripStartM ??= distanceM;
    if (rung) return AlarmEvent.none;
    if (neverLate(distanceM, accuracyM, setM)) {
      rung = true;
      return AlarmEvent.ring;
    }
    final s = kModeSpecs[mode]!;
    if (s.gentleBeforeM > 0 && !gentleDone &&
        neverLate(distanceM, accuracyM, setM + s.gentleBeforeM)) {
      gentleDone = true;
      return AlarmEvent.gentle;
    }
    if (s.readyAtM > 0 && !readyDone && tripStartM! > s.readyMinTripM &&
        neverLate(distanceM, accuracyM, s.readyAtM)) {
      readyDone = true;
      return AlarmEvent.ready;
    }
    return AlarmEvent.none;
  }
}

/// Train: ring when the train LEAVES the station before yours (the next
/// station is yours). "At the previous station" = its circle reached
/// (distance − accuracy ≤ [atM]); "left" = afterwards clearly away from it
/// (distance − accuracy > [leftM]) and closer to yours than that station is.
/// GPS fallback: the never-late distance rule to your own station.
class TrainLegWatch {
  static const int atM = 500, leftM = 700;
  final double prevToTargetM;
  final int fallbackM;
  bool seenPrev = false, rung = false;
  TrainLegWatch(this.prevToTargetM, {this.fallbackM = 2000});

  AlarmEvent update(double toPrevM, double toTargetM, double accuracyM) {
    if (rung) return AlarmEvent.none;
    if (neverLate(toPrevM, accuracyM, atM)) seenPrev = true;
    final left = seenPrev && toPrevM - math.max(0.0, accuracyM) > leftM &&
        toTargetM < prevToTargetM;
    if (left || neverLate(toTargetM, accuracyM, fallbackM)) {
      rung = true;
      return AlarmEvent.ring;
    }
    return AlarmEvent.none;
  }
}

// ------------------------------------------------------------ metro (no GPS)
class MetroStation {
  final String en, bn;
  final double lat, lng;
  final double nextMin; // minutes to the next station in list order (estimate)
  const MetroStation(this.en, this.bn, this.lat, this.lng, this.nextMin);
  String name(bool bnLang) => bnLang ? bn : en;
}

List<MetroStation> parseMetro(String raw) {
  final j = jsonDecode(raw) as Map<String, dynamic>;
  return [
    for (final s in (j['stations'] as List? ?? const []))
      MetroStation('${s['en']}', '${s['bn']}', (s['lat'] as num).toDouble(),
          (s['lng'] as num).toDouble(), ((s['next_min'] as num?) ?? 0).toDouble())
  ];
}

/// Minutes from leaving [from] until the train LEAVES station [k] (k between
/// from and target, either direction), by the published order + estimated
/// minutes between stations.
double metroMinutes(List<MetroStation> st, int from, int k) {
  if (k == from) return 0;
  final step = k > from ? 1 : -1;
  var m = 0.0;
  for (var i = from; i != k; i += step) {
    // segment between i and i+step: its time is stored on the lower index
    m += st[math.min(i, i + step)].nextMin;
  }
  return m;
}

/// When to ring: the train leaves the station BEFORE yours.
DateTime metroRingAt(List<MetroStation> st, int from, int to, DateTime leftFromAt) {
  if ((to - from).abs() <= 1) return leftFromAt; // yours is the next one already
  final before = to > from ? to - 1 : to + 1;
  final mins = metroMinutes(st, from, before);
  return leftFromAt.add(Duration(seconds: (mins * 60).round()));
}

/// Which station the train should be at / just left by the clock.
int metroStationAt(List<MetroStation> st, int from, int to, DateTime leftFromAt, DateTime now) {
  final step = to > from ? 1 : -1;
  var cur = from;
  while (cur != to) {
    final nxt = cur + step;
    if (leftFromAt.add(Duration(seconds: (metroMinutes(st, from, nxt) * 60).round())).isAfter(now)) {
      break;
    }
    cur = nxt;
  }
  return cur;
}

// ------------------------------------------------------------ alerts
enum AlertKind { voice, sound, vibrate }

/// Voice (Bangla voice says stop name + distance) default ON, alarm sound
/// default OFF, vibration default ON. At least one must stay ON. A personal
/// voice clip (recorded and kept ON THE PHONE only) counts as Voice.
class AlertPrefs {
  final bool voice, sound, vibrate;
  final String? personalClip;
  const AlertPrefs({this.voice = true, this.sound = false, this.vibrate = true, this.personalClip});

  bool get(AlertKind k) => k == AlertKind.voice ? voice : (k == AlertKind.sound ? sound : vibrate);
  int get onCount => [voice, sound, vibrate].where((x) => x).length;

  /// Would turning [k] off leave nothing on? Then the UI disables it.
  bool isLastOn(AlertKind k) => get(k) && onCount == 1;

  /// Returns the new prefs; turning off the last one is refused (unchanged).
  AlertPrefs toggle(AlertKind k, bool on) {
    if (!on && isLastOn(k)) return this;
    return AlertPrefs(
        voice: k == AlertKind.voice ? on : voice,
        sound: k == AlertKind.sound ? on : sound,
        vibrate: k == AlertKind.vibrate ? on : vibrate,
        personalClip: personalClip);
  }

  AlertPrefs withClip(String? path) =>
      AlertPrefs(voice: voice, sound: sound, vibrate: vibrate, personalClip: path);

  Map<String, dynamic> toJson() =>
      {'voice': voice, 'sound': sound, 'vibrate': vibrate, if (personalClip != null) 'clip': personalClip};

  factory AlertPrefs.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const AlertPrefs();
    final p = AlertPrefs(
        voice: j['voice'] != false,
        sound: j['sound'] == true,
        vibrate: j['vibrate'] != false,
        personalClip: j['clip'] as String?);
    return p.onCount == 0 ? const AlertPrefs() : p;
  }
}

/// Settings key for one mode's remembered distance + alerts.
String modeKey(TransportMode m) => 'dest_alarm_mode_${m.name}';

// ------------------------------------------------------------ places
class DestStation {
  final String id, en, bn;
  final double lat, lng;
  const DestStation(this.id, this.en, this.bn, this.lat, this.lng);

  String name(bool bnLang) => bnLang && bn.isNotEmpty ? bn : en;
}

/// stations_bd.json ("stations") or bus_stops_bd.json ("stops").
List<DestStation> parseStations(String raw) {
  final j = jsonDecode(raw) as Map<String, dynamic>;
  final out = <DestStation>[];
  for (final s in (j['stations'] as List? ?? j['stops'] as List? ?? const [])) {
    if (s is! Map) continue;
    final lat = (s['lat'] as num?)?.toDouble(), lng = (s['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) continue;
    out.add(DestStation('${s['id']}', '${s['en'] ?? ''}', '${s['bn'] ?? ''}', lat, lng));
  }
  return out;
}

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

/// Distance for the voice: (is kilometres, number text in ASCII digits).
/// The screen turns it into words with its ARB strings (and Bangla digits).
(bool, String) spokenDistanceParts(double m) {
  if (m >= 1000) {
    final km = (m / 1000).toStringAsFixed(m >= 10000 ? 0 : 1);
    return (true, km.endsWith('.0') ? km.substring(0, km.length - 2) : km);
  }
  return (false, '${(m / 10).round() * 10}');
}
