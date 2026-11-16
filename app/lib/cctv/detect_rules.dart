// cctvdet (CCTV Guard V3, part C, stage 1): ZONE DETECTIONS drawn by the
// owner on the camera picture — a line-for-line port of the Shop Box rules
// (edge/shopbox/shopbox/detect_rules.py). Both run the SAME cases
// (edge/shopbox/tests/fixtures/detect_cases.json, app/test/
// cctv_detect_parity_test.dart) and their constants equal
// edge/shopbox/shopbox/cctv_thresholds.json["detect"].
//
// Pure Dart (no Flutter, no plugins, no clock): the phone camera and the
// Android Guard Box feed it person boxes + the zone pictures.
//
//   gate  person at the shutter / gate (kGateConfirm checks in a row, once
//         per visit) + "gate left open" (opt-in: the zone picture no longer
//         matches the remembered CLOSED picture for open_min minutes)
//   post  counter / post empty for absent_min minutes inside its own hours
//   any   loitering: one visit in a zone with opts.dwell_s lasts that long
//
// Without the person model (boxes == null) the person rules stay silent —
// presence or absence is never guessed from motion. Never identity.
import 'dart:math' as math;

const kZoneHitPoints = 2;
const kGateConfirm = 2;
const kPresenceGapS = 10.0;
const kDwellSDefault = 120;
const kAbsentMinDefault = 5;
const kOpenMinDefault = 10;
const kPostCheckS = 30.0;
const kPresenceCheckS = 2.0;
const kPatchW = 16;
const kPatchH = 12;
const kGateClosedSim = 0.6;
const kTamperEveryS = 30.0;
const kBadPersistS = 60;
const kMovedMinGapS = 120;

// stage 2 (cctvdet)
const kPostPresenceScore = 0.25;
const kCrowdSDefault = 60;
const kVehGapS = 90.0;
const kVehCheckS = 10.0;
const kVehStill = 0.06;
const kOverstayMinDefault = 60;
const kWrongSDefault = 120;
const kTrackMaxJump = 0.25;
// cctvdet3: recall without losing precision (tuned on the CALIBRATION half of
// tools/e2e/cctv_detect_accuracy.py, reported on the HELD-OUT half)
const kTrackJumpCap = 0.5;
const kTrackCoastS = 3.0;
const kCrossMargin = 0.02;
const kDwellKeepScore = 0.25;
const kCrowdScore = 0.25;
const kCrowdKeepS = 10.0;
const kPostWeakHits = 2;
const kVehStartScore = 0.0;
const kMovedShapeSim = 0.35;
const kMovedShapeKeep = 0.6;
const kVehicleClasses = {1: 'cycle', 2: 'car', 3: 'motorbike', 5: 'bus', 7: 'truck'};

const kDetCrowd = 'crowd';
const kDetVehicleInOut = 'vehicle_in_out';
const kDetParkingOverstay = 'parking_overstay';
const kDetWrongParking = 'wrong_parking';

const kDetGatePerson = 'gate_person';
const kDetLoitering = 'loitering';
const kDetPostEmpty = 'post_empty';
const kDetGateOpen = 'gate_open';
const kDetCameraHealth = 'camera_health';

/// A 10 s clip per detection (owner order), 4 s before the moment.
const kDetClipS = 10.0;
const kDetClipPreS = 4.0;

// ---------------------------------------------------------------- geometry
bool detPointInPolygon(double x, double y, List<List<double>> poly) {
  var inside = false;
  final n = poly.length;
  if (n < 3) return false;
  var j = n - 1;
  for (var i = 0; i < n; i++) {
    final xi = poly[i][0], yi = poly[i][1], xj = poly[j][0], yj = poly[j][1];
    if ((yi > y) != (yj > y)) {
      final dy = (yj - yi) != 0 ? (yj - yi) : 1e-12;
      if (x < (xj - xi) * (y - yi) / dy + xi) inside = !inside;
    }
    j = i;
  }
  return inside;
}

/// >= [need] of the 3 x 3 grid points (1/6, 1/2, 5/6 of the box) inside.
bool detBoxInZone(List<double> box, List<List<double>> poly, {int need = kZoneHitPoints}) {
  if (poly.length < 3 || box.length < 4) return false;
  final x1 = box[0], y1 = box[1], x2 = box[2], y2 = box[3];
  var hits = 0;
  for (final fy in const [1.0 / 6, 0.5, 5.0 / 6]) {
    for (final fx in const [1.0 / 6, 0.5, 5.0 / 6]) {
      if (detPointInPolygon(x1 + (x2 - x1) * fx, y1 + (y2 - y1) * fy, poly)) {
        hits++;
        if (hits >= need) return true;
      }
    }
  }
  return false;
}

List<double> polyBbox(List<List<double>> poly) {
  var x1 = double.infinity, y1 = double.infinity, x2 = -double.infinity, y2 = -double.infinity;
  for (final p in poly) {
    x1 = math.min(x1, p[0]);
    y1 = math.min(y1, p[1]);
    x2 = math.max(x2, p[0]);
    y2 = math.max(y2, p[1]);
  }
  return [x1, y1, x2, y2];
}

/// The zone's bounding box of a row-major grey frame, block-averaged to
/// pw x ph (the same integer ranges as the Shop Box).
List<double> zonePatch(List<int> gray, int width, int height, List<List<double>> poly,
    {int pw = kPatchW, int ph = kPatchH}) {
  final b = polyBbox(poly);
  final x0 = (b[0] * width).floor();
  final y0 = (b[1] * height).floor();
  final x1 = math.max(x0 + 1, math.min(width, (b[2] * width).ceil()));
  final y1 = math.max(y0 + 1, math.min(height, (b[3] * height).ceil()));
  final bw = x1 - x0, bh = y1 - y0;
  final out = <double>[];
  for (var j = 0; j < ph; j++) {
    final ya = y0 + (bh * j) ~/ ph;
    final yb = math.max(ya + 1, y0 + (bh * (j + 1)) ~/ ph);
    for (var i = 0; i < pw; i++) {
      final xa = x0 + (bw * i) ~/ pw;
      final xb = math.max(xa + 1, x0 + (bw * (i + 1)) ~/ pw);
      var s = 0, n = 0;
      for (var yy = ya; yy < math.min(yb, height); yy++) {
        final row = yy * width;
        for (var xx = xa; xx < math.min(xb, width); xx++) {
          s += gray[row + xx];
          n++;
        }
      }
      out.add(n > 0 ? s / n : 0.0);
    }
  }
  return out;
}

double _ncc(List<double> a, List<double> b) {
  if (a.isEmpty || b.isEmpty || a.length != b.length) return 0.0;
  var ma = 0.0, mb = 0.0;
  for (var i = 0; i < a.length; i++) {
    ma += a[i];
    mb += b[i];
  }
  ma /= a.length;
  mb /= b.length;
  var num = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    final dx = a[i] - ma, dy = b[i] - mb;
    num += dx * dy;
    na += dx * dx;
    nb += dy * dy;
  }
  if (na < 1e-6 || nb < 1e-6) {
    return (na < 1e-6 && nb < 1e-6 && (ma - mb).abs() < 12) ? 1.0 : 0.0;
  }
  return num / math.sqrt(na * nb);
}

List<double> _grad(List<double> p, {int pw = kPatchW, int ph = kPatchH}) {
  final out = <double>[];
  for (var j = 0; j < ph; j++) {
    for (var i = 0; i < pw; i++) {
      final v = p[j * pw + i];
      final dx = (p[j * pw + math.min(i + 1, pw - 1)] - v).abs();
      final dy = (p[math.min(j + 1, ph - 1) * pw + i] - v).abs();
      out.add(dx + dy);
    }
  }
  return out;
}

double _r4(double v) => (v * 10000).roundToDouble() / 10000;

/// How much the zone picture looks like the remembered one (-1..1).
double detSimilarity(List<double> patch, List<double> ref, {bool gradOnly = false}) {
  final g = _ncc(_grad(patch), _grad(ref));
  if (gradOnly) return _r4(g);
  return _r4(math.max(_ncc(patch, ref), g));
}

double _dist(List<double> a, List<double> b) {
  final dx = a[0] - b[0], dy = a[1] - b[1];
  return math.sqrt(dx * dx + dy * dy);
}

double _orient(List<double> a, List<double> b, List<double> c) =>
    (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);

/// p1->p2 properly crosses q1-q2 (touching / along it does not count).
bool detSegmentsCross(List<double> p1, List<double> p2, List<double> q1, List<double> q2) {
  final d1 = _orient(q1, q2, p1), d2 = _orient(q1, q2, p2);
  final d3 = _orient(p1, p2, q1), d4 = _orient(p1, p2, q2);
  return ((d1 > 0 && 0 > d2) || (d1 < 0 && 0 < d2)) && ((d3 > 0 && 0 > d4) || (d3 < 0 && 0 < d4));
}

// ---------------------------------------------------------------- schedule
int? _hhmm(Object? v) {
  final p = (v ?? '').toString().split(':');
  if (p.length != 2) return null;
  final h = int.tryParse(p[0]), m = int.tryParse(p[1]);
  if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) return null;
  return h * 60 + m;
}

/// The server's is_armed on (weekday Mon=0, minute of the day). null = always.
bool scheduleArmed(Map? sched, int weekday, int minute) {
  if (sched == null) return true;
  final days = <int>{
    for (final d in (sched['days'] as List? ?? const []))
      if (d is num) d.toInt() else if (int.tryParse('$d') != null) int.parse('$d')
  };
  final s = _hhmm(sched['start']), e = _hhmm(sched['end']);
  if (s == null || e == null) return true;
  if (s == e) return days.contains(weekday);
  if (s < e) return days.contains(weekday) && s <= minute && minute < e;
  if (minute >= s) return days.contains(weekday);
  if (minute < e) return days.contains((weekday - 1) % 7);
  return false;
}

// ---------------------------------------------------------------- rules
double _optNum(Map? opts, String key, num def, num lo, num hi) {
  final raw = opts?[key];
  var v = raw is num ? raw.toDouble() : double.tryParse('${raw ?? def}') ?? def.toDouble();
  if (v.isNaN) v = def.toDouble();
  return math.min(math.max(v, lo.toDouble()), hi.toDouble());
}

class DetZone {
  final String id, type, label;
  final List<List<double>> points;
  final Map? schedule;
  final Map opts;
  DetZone(this.id, this.type, this.points, {this.label = '', this.schedule, this.opts = const {}});

  static DetZone? fromJson(Object? z) {
    if (z is! Map) return null;
    final type = '${z['type']}';
    if (!const {'gate', 'post', 'restricted', 'parking', 'no_parking', 'entry_line'}.contains(type)) {
      return null;
    }
    final id = '${z['id'] ?? ''}';
    final pts = [
      for (final p in (z['points'] as List? ?? const []))
        if (p is List && p.length >= 2 && p[0] is num && p[1] is num)
          [(p[0] as num).toDouble(), (p[1] as num).toDouble()]
    ];
    final opts = z['opts'] is Map ? z['opts'] as Map : const {};
    if (type == 'entry_line') {
      // people on the line are the analyzer's; vehicles in / out are here
      if (id.isEmpty || pts.length != 2 || opts['vehicles'] != true) return null;
    } else if (id.isEmpty || pts.length < 3) {
      return null;
    }
    // restricted zones are the analyzer's — here only when they time a dwell
    // or count a crowd
    if (type == 'restricted' &&
        _optNum(opts, 'dwell_s', 0, 0, 3600) <= 0 &&
        _optNum(opts, 'crowd_n', 0, 0, 50) <= 0) {
      return null;
    }
    final label = '${z['label'] ?? ''}';
    return DetZone(id, type, pts,
        label: label.length > 40 ? label.substring(0, 40) : label,
        schedule: z['schedule'] is Map ? z['schedule'] as Map : null,
        opts: opts);
  }
}

class _ZoneState {
  int hits = 0;
  double? since, lastSeen, absentSince, openSince, refAt, refFor;
  bool gateFired = false, dwellFired = false, absentFired = false, openFired = false;
  double? crowdSince, vehSince, vehLast;
  bool crowdFired = false, vehFired = false;
  double? crowdLow; // cctvdet3: first check below crowd_n
  int weakHits = 0; // cctvdet3: weak-only post checks in a row
  List<double>? vehAnchor;
  List<double>? refDay, refNight;
}

class ZoneRules {
  List<DetZone> zones = [];
  Map? camSchedule;
  Map<String, _ZoneState> state = {};

  ZoneRules([List<DetZone> zones = const [], Map? camSchedule]) {
    configure(zones, camSchedule);
  }

  void configure(List<DetZone> zs, [Map? camSchedule]) {
    this.camSchedule = camSchedule;
    final keep = <String, _ZoneState>{};
    zones = [];
    for (final z in zs) {
      zones.add(z);
      keep[z.id] = state[z.id] ?? _ZoneState();
    }
    state = keep;
  }

  /// The zones of a server zone config ({"zones": [...], "schedule": ...}).
  void configureFromJson(Map? zoneConfig) {
    final zs = <DetZone>[];
    for (final z in (zoneConfig?['zones'] as List? ?? const [])) {
      final d = DetZone.fromJson(z);
      if (d != null) zs.add(d);
    }
    configure(zs, zoneConfig?['schedule'] is Map ? zoneConfig!['schedule'] as Map : null);
  }

  bool needsPersonCheck(double t, int weekday, int minute, double? lastCheck) {
    final since = lastCheck == null ? null : t - lastCheck;
    for (final z in zones) {
      final st = state[z.id]!;
      if (z.type == 'post' && _armed(z, weekday, minute)) {
        if (since == null || since >= kPostCheckS) return true;
      }
      if (st.lastSeen != null && t - st.lastSeen! <= kPresenceGapS) {
        if (since == null || since >= kPresenceCheckS) return true;
      }
    }
    return false;
  }

  bool get hasPost => zones.any((z) => z.type == 'post');
  bool get wantsVehicles => zones.any((z) => z.type == 'parking' || z.type == 'no_parking' || z.type == 'entry_line');

  bool needsVehicleCheck(double t, double? lastCheck) {
    if (!zones.any((z) => z.type == 'parking' || z.type == 'no_parking')) return false;
    return lastCheck == null || t - lastCheck >= kVehCheckS;
  }

  final List<Map<String, Object>> _tracks = [];

  /// Nearest-centre tracking -> [(track, cur, cls, box)]. cctvdet3: a track
  /// unseen for dt s may move kTrackMaxJump per second (cap kTrackJumpCap);
  /// it keeps where it started ('first') and, per line, where it last
  /// crossed ('o').
  List<(Map<String, Object>, List<double>, int, List<double>)> _track(double t, List<List<double>> vehicles) {
    final moves = <(Map<String, Object>, List<double>, int, List<double>)>[];
    final used = <int>{};
    final fresh = <Map<String, Object>>[];
    for (final v in vehicles) {
      final c = [(v[0] + v[2]) / 2.0, (v[1] + v[3]) / 2.0];
      final cls = v.length > 5 ? v[5].toInt() : 2;
      final sc = v.length > 4 ? v[4] : 1.0;
      final box = [for (final x in v.take(4)) (x * 10000).roundToDouble() / 10000];
      int? best;
      double? bd;
      for (var i = 0; i < _tracks.length; i++) {
        final tr = _tracks[i];
        final dt = t - (tr['t'] as double);
        if (used.contains(i) || dt > kVehGapS) continue;
        final d = _dist(tr['c'] as List<double>, c);
        final lim = dt <= kTrackCoastS ? math.min(kTrackJumpCap, kTrackMaxJump * math.max(1.0, dt)) : kTrackMaxJump;
        if (d <= lim && (bd == null || d < bd)) {
          best = i;
          bd = d;
        }
      }
      if (best == null) {
        fresh.add({'c': c, 't': t, 'cls': cls, 'first': c, 'o': <String, List<double>>{}, 'best': sc});
      } else {
        used.add(best);
        final tr = _tracks[best];
        moves.add((tr, c, cls, box));
        tr['c'] = c;
        tr['t'] = t;
        tr['cls'] = cls;
        tr['best'] = math.max((tr['best'] as double?) ?? 0.0, sc);
      }
    }
    final keep = [for (final tr in _tracks) if (t - (tr['t'] as double) <= kVehGapS) tr, ...fresh];
    _tracks
      ..clear()
      ..addAll(keep.length > 32 ? keep.sublist(keep.length - 32) : keep);
    return moves;
  }

  Map<String, Object>? _vehicleZone(DetZone z, _ZoneState st, double t, int weekday, int minute,
      List<List<double>>? vehicles) {
    if (vehicles == null) return null;
    final vin = [for (final v in vehicles) if (detBoxInZone(v, z.points)) v];
    if (vin.isEmpty) {
      if (st.vehLast != null && t - st.vehLast! > kVehGapS) {
        st.vehAnchor = null;
        st.vehSince = null;
        st.vehLast = null;
        st.vehFired = false;
      }
      return null;
    }
    final cs = [for (final v in vin) [(v[0] + v[2]) / 2.0, (v[1] + v[3]) / 2.0]];
    var same = st.vehAnchor != null && st.vehLast != null && t - st.vehLast! <= kVehGapS;
    if (same) same = cs.map((c) => _dist(c, st.vehAnchor!)).reduce(math.min) <= kVehStill;
    if (!same) {
      // cctvdet3: a NEW stay starts only on a confident box
      var best = 0;
      for (var i = 1; i < vin.length; i++) {
        final si = vin[i].length > 4 ? vin[i][4] : 1.0;
        final sb = vin[best].length > 4 ? vin[best][4] : 1.0;
        if (si > sb) best = i;
      }
      final sc = vin[best].length > 4 ? vin[best][4] : 1.0;
      if (sc < kVehStartScore) return null;
      st.vehAnchor = cs[best];
      st.vehSince = t;
      st.vehFired = false;
    }
    st.vehLast = t;
    if (!_openArmed(z, weekday, minute)) return null;
    final cls = kVehicleClasses[vin.first.length > 5 ? vin.first[5].toInt() : 2] ?? 'vehicle';
    final parking = z.type == 'parking';
    final need = parking
        ? _optNum(z.opts, 'overstay_min', kOverstayMinDefault, 5, 1440) * 60
        : _optNum(z.opts, 'wrong_s', kWrongSDefault, 30, 3600);
    if (t - st.vehSince! >= need && !st.vehFired) {
      st.vehFired = true;
      return {
        'type': parking ? kDetParkingOverstay : kDetWrongParking,
        'cls': cls,
        'seconds': (t - st.vehSince!).toInt(),
        if (parking) 'minutes': (t - st.vehSince!) ~/ 60,
        'box': [for (final x in vin.first.take(4)) (x * 10000).roundToDouble() / 10000],
      };
    }
    return null;
  }

  List<DetZone> gateZones() =>
      [for (final z in zones) if (z.type == 'gate' && z.opts['watch_open'] == true) z];

  double _closedAt(String zid) {
    final i = zones.indexWhere((z) => z.id == zid);
    if (i < 0) return 0.0;
    final ca = zones[i].opts['closed_at'];
    return ca is num ? ca.toDouble() : (double.tryParse('${ca ?? 0}') ?? 0.0);
  }

  /// Once per new "the gate is closed now" tap (compared with the tap it
  /// answered, never with this device's clock).
  bool wantsRef(String zid) {
    final st = state[zid];
    if (st == null) return false;
    final closedAt = _closedAt(zid);
    if (closedAt <= 0) return false;
    return st.refFor == null || st.refFor! < closedAt;
  }

  void setRef(String zid, List<double> patch, bool night, double t) {
    final st = state[zid];
    if (st == null || patch.isEmpty) return;
    if (night) {
      st.refNight = List.of(patch);
      st.refDay = null;
    } else {
      st.refDay = List.of(patch);
      st.refNight = null;
    }
    st.refAt = t;
    st.refFor = _closedAt(zid);
    st.openSince = null;
    st.openFired = false;
  }

  Map<String, Map<String, Object?>> refs() => {
        for (final e in state.entries)
          if (e.value.refAt != null)
            e.key: {'day': e.value.refDay, 'night': e.value.refNight, 'at': e.value.refAt, 'for': e.value.refFor}
      };

  void loadRefs(Map? d) {
    for (final e in (d ?? const {}).entries) {
      final st = state['${e.key}'];
      final r = e.value;
      if (st == null || r is! Map) continue;
      List<double>? l(Object? v) => v is List ? [for (final x in v) (x as num).toDouble()] : null;
      st.refDay = l(r['day']);
      st.refNight = l(r['night']);
      st.refAt = (r['at'] as num?)?.toDouble();
      st.refFor = (r['for'] as num?)?.toDouble();
    }
  }

  bool _armed(DetZone z, int weekday, int minute) {
    if (z.type == 'post') return z.schedule != null && scheduleArmed(z.schedule, weekday, minute);
    return scheduleArmed(z.schedule ?? camSchedule, weekday, minute);
  }

  bool _openArmed(DetZone z, int weekday, int minute) => scheduleArmed(z.schedule, weekday, minute);

  /// One analysed frame. boxes: [[x1, y1, x2, y2, score], ...] from the
  /// person model THIS frame, or null when it did not run.
  List<Map<String, Object>> step(double t, int weekday, int minute, List<List<double>>? boxes,
      {bool night = false,
      Map<String, List<double>>? patches,
      double minScore = 0.0,
      List<List<double>>? vehicles}) {
    final out = <Map<String, Object>>[];
    final moves = vehicles != null ? _track(t, vehicles) : const <(Map<String, Object>, List<double>, int, List<double>)>[];
    for (final z in zones) {
      final st = state[z.id]!;
      final opts = z.opts;
      if (z.type == 'entry_line') {
        final a = z.points[0], b = z.points[1];
        final ln = math.max(1e-9, _dist(a, b));
        for (final (tr, cur, cls, box) in moves) {
          final os = tr['o'] as Map<String, List<double>>;
          final o = os[z.id] ?? tr['first'] as List<double>;
          if (((tr['best'] as double?) ?? 1.0) >= kVehStartScore &&
              _orient(a, b, o).abs() / ln >= kCrossMargin &&
              _orient(a, b, cur).abs() / ln >= kCrossMargin &&
              detSegmentsCross(o, cur, a, b)) {
            os[z.id] = cur;
            final left = _orient(a, b, cur) > 0;
            final inward = (opts['in_side'] ?? 'left') == 'left' ? left : !left;
            out.add({
              'type': kDetVehicleInOut,
              'zone': z.id,
              'label': z.label,
              'dir': inward ? 'in' : 'out',
              'cls': kVehicleClasses[cls] ?? 'vehicle',
              'box': box,
            });
          }
        }
        continue;
      }
      if (z.type == 'parking' || z.type == 'no_parking') {
        final d = _vehicleZone(z, st, t, weekday, minute, vehicles);
        if (d != null) out.add({...d, 'zone': z.id, 'label': z.label});
        continue;
      }
      var inZone = const <List<double>>[];
      var strong = const <List<double>>[];
      List<List<double>>? crowdBoxes = const <List<double>>[];
      if (boxes != null) {
        final floor = z.type == 'post' ? kPostPresenceScore : minScore;
        final allIn = [for (final b in boxes) if (detBoxInZone(b, z.points)) b];
        strong = [for (final b in allIn) if (b.length < 5 || b[4] >= minScore) b];
        inZone = [for (final b in allIn) if (b.length < 5 || b[4] >= floor) b];
        final crowdFloor = math.min(minScore, kCrowdScore);
        crowdBoxes = [for (final b in allIn) if (b.length < 5 || b[4] >= crowdFloor) b];
        if (z.type == 'post') {
          // cctvdet3: a lone weak box must be seen kPostWeakHits checks in a row
          if (strong.isNotEmpty) {
            st.weakHits = 0;
          } else if (inZone.isNotEmpty) {
            st.weakHits++;
            if (st.weakHits < kPostWeakHits) inZone = const <List<double>>[];
          } else {
            st.weakHits = 0;
          }
        } else if (z.type != 'gate' && inZone.isEmpty && st.lastSeen != null && t - st.lastSeen! <= kPresenceGapS) {
          // cctvdet3: a visit under way keeps going on a weaker box
          final keep = math.min(minScore, kDwellKeepScore);
          inZone = [for (final b in allIn) if (b.length < 5 || b[4] >= keep) b];
        }
        if (inZone.isNotEmpty) {
          st.hits++;
          if (st.lastSeen == null || t - st.lastSeen! > kPresenceGapS) {
            st.since = t;
            st.gateFired = false;
            st.dwellFired = false;
          }
          st.lastSeen = t;
        } else {
          st.hits = 0;
          if (st.lastSeen != null && t - st.lastSeen! > kPresenceGapS) st.since = null;
        }
      }
      final presentNow = inZone.isNotEmpty;
      final armed = _armed(z, weekday, minute);
      double? conf;
      for (final b in inZone) {
        if (b.length > 4 && (conf == null || b[4] > conf)) conf = b[4];
      }

      if (z.type == 'gate' && armed && presentNow && st.hits >= kGateConfirm && !st.gateFired) {
        st.gateFired = true;
        out.add({
          'type': kDetGatePerson,
          'zone': z.id,
          'label': z.label,
          if (conf != null) 'conf': (conf * 1000).roundToDouble() / 1000,
        });
      }

      final dwell = _optNum(opts, 'dwell_s', 0, 0, 3600);
      if (dwell > 0 && armed && presentNow && st.since != null && t - st.since! >= dwell && !st.dwellFired) {
        st.dwellFired = true;
        out.add({
          'type': kDetLoitering,
          'zone': z.id,
          'label': z.label,
          'seconds': (t - st.since!).toInt(),
          if (conf != null) 'conf': (conf * 1000).roundToDouble() / 1000,
        });
      }

      final crowdN = _optNum(opts, 'crowd_n', 0, 0, 50).toInt();
      if (crowdN > 0 && boxes != null) {
        if (crowdBoxes.length < crowdN && st.crowdSince != null) {
          // cctvdet3: a short dip below crowd_n does not end the queue
          st.crowdLow ??= t;
          if (t - st.crowdLow! <= kCrowdKeepS) crowdBoxes = null;
        }
        if (crowdBoxes == null) {
          // hold
        } else if (crowdBoxes.length >= crowdN) {
          st.crowdLow = null;
          st.crowdSince ??= t;
          final need = _optNum(opts, 'crowd_s', kCrowdSDefault, 10, 1800);
          if (_openArmed(z, weekday, minute) && t - st.crowdSince! >= need && !st.crowdFired) {
            st.crowdFired = true;
            out.add({'type': kDetCrowd, 'zone': z.id, 'label': z.label, 'count': crowdBoxes.length});
          }
        } else {
          st.crowdSince = null;
          st.crowdFired = false;
          st.crowdLow = null;
        }
      }

      if (z.type == 'post') {
        if (!armed) {
          st.absentSince = null;
          st.absentFired = false;
        } else if (boxes != null) {
          if (presentNow) {
            st.absentSince = null;
            st.absentFired = false;
          } else {
            st.absentSince ??= t;
            final need = _optNum(opts, 'absent_min', kAbsentMinDefault, 1, 240) * 60;
            if (t - st.absentSince! >= need && !st.absentFired) {
              st.absentFired = true;
              out.add({
                'type': kDetPostEmpty,
                'zone': z.id,
                'label': z.label,
                'minutes': (t - st.absentSince!) ~/ 60,
              });
            }
          }
        }
      }

      final patch = patches?[z.id];
      if (z.type == 'gate' && opts['watch_open'] == true && patch != null &&
          (st.refDay != null || st.refNight != null)) {
        final recent = st.lastSeen != null && t - st.lastSeen! <= kPresenceGapS;
        if (!presentNow && !recent) {
          final same = night ? st.refNight : st.refDay;
          double sim;
          if (same != null) {
            sim = detSimilarity(patch, same);
          } else {
            final other = night ? st.refDay! : st.refNight!;
            sim = detSimilarity(patch, other, gradOnly: true);
            if (sim >= kGateClosedSim) {
              if (night) {
                st.refNight = List.of(patch);
              } else {
                st.refDay = List.of(patch);
              }
            }
          }
          if (sim >= kGateClosedSim) {
            st.openSince = null;
            st.openFired = false;
          } else if (_openArmed(z, weekday, minute)) {
            st.openSince ??= t;
            final need = _optNum(opts, 'open_min', kOpenMinDefault, 1, 720) * 60;
            if (t - st.openSince! >= need && !st.openFired) {
              st.openFired = true;
              out.add({
                'type': kDetGateOpen,
                'zone': z.id,
                'label': z.label,
                'minutes': (t - st.openSince!) ~/ 60,
                'sim': (sim * 1000).roundToDouble() / 1000,
              });
            }
          } else {
            st.openSince = null;
          }
        }
      }
    }
    return out;
  }
}

// ---------------------------------------------------------------- tamper
double _corr(List<double> a, List<double> b) {
  if (a.isEmpty || b.isEmpty || a.length != b.length) return 0.0;
  final ma = a.reduce((x, y) => x + y) / a.length;
  final mb = b.reduce((x, y) => x + y) / b.length;
  var na = 0.0, nb = 0.0, num = 0.0;
  for (var i = 0; i < a.length; i++) {
    final da = a[i] - ma, db = b[i] - mb;
    num += da * db;
    na += da * da;
    nb += db * db;
  }
  na = math.sqrt(na);
  nb = math.sqrt(nb);
  if (na < 1e-6 || nb < 1e-6) return 0.0;
  return num / (na * nb);
}

String? stillKind(double mean, double std) {
  if (mean < 20 && std < 8) return 'dark';
  if (std < 4) return 'covered';
  return null;
}

double _r1(double v) => (v * 10).roundToDouble() / 10;

/// = the server's core/logic/cctv_rules.assess_still (same cases).
(Map<String, dynamic>, String?) assessStill(
    Map<String, dynamic> state, List<double> grid, double mean, double std, bool ir, double ts) {
  final st = Map<String, dynamic>.of(state);
  final kind = stillKind(mean, std);
  if (kind != null) {
    final prev = st['bad'] as Map?;
    st.remove('pending');
    if (prev != null && prev['kind'] == kind) {
      final first = (prev['ts'] as num? ?? ts).toDouble();
      if (ts - first >= kBadPersistS) {
        st['bad'] = {'kind': kind, 'ts': ts};
        return (st, kind);
      }
      return (st, null);
    }
    st['bad'] = {'kind': kind, 'ts': ts};
    return (st, null);
  }
  st.remove('bad');
  final key = ir ? 'ref_ir' : 'ref_day';
  final ref = (st[key] as List?)?.map((e) => (e as num).toDouble()).toList();
  if (ref == null || ref.isEmpty) {
    st[key] = [for (final v in grid) _r1(v)];
    return (st, null);
  }
  final c = _corr(grid, ref);
  if (c >= 0.6) {
    st[key] = [for (var i = 0; i < ref.length; i++) _r1(0.8 * ref[i] + 0.2 * grid[i])];
    st.remove('pending');
    return (st, null);
  }
  if (c < 0.35) {
    final p = st['pending'] as Map?;
    final pg = (p?['grid'] as List?)?.map((e) => (e as num).toDouble()).toList() ?? const <double>[];
    if (p != null && p['ir'] == ir && ts - ((p['ts'] as num?) ?? 0).toDouble() >= kMovedMinGapS &&
        _corr(grid, pg) >= 0.7) {
      st[key] = [for (final v in grid) _r1(v)];
      st.remove('pending');
      return (st, 'moved');
    }
    if (p == null || p['ir'] != ir) {
      st['pending'] = {'grid': [for (final v in grid) _r1(v)], 'ts': ts, 'ir': ir};
    }
  }
  return (st, null);
}

/// (8 x 8 grid, mean, std) of a row-major grey frame.
(List<double>, double, double) stillStats(List<int> gray, int width, int height) {
  final grid = zonePatch(gray, width, height, const [
    [0.0, 0.0],
    [1.0, 0.0],
    [1.0, 1.0],
    [0.0, 1.0]
  ], pw: 8, ph: 8);
  final n = math.max(1, width * height);
  var s = 0.0, s2 = 0.0;
  for (var i = 0; i < n && i < gray.length; i++) {
    s += gray[i];
    s2 += gray[i] * gray[i];
  }
  final mean = s / n;
  return (grid, mean, math.sqrt(math.max(0.0, s2 / n - mean * mean)));
}

double _r2(double v) => (v * 100).roundToDouble() / 100;

/// Stage 2: CAMERA MOVED by the scene's shapes (= detect_rules.assess_shape).
(Map<String, dynamic>, String?) assessShape(Map<String, dynamic> state, List<double> shape, bool ir, double ts) {
  final st = Map<String, dynamic>.of(state);
  final key = ir ? 'shape_ir' : 'shape_day';
  final ref = (st[key] as List?)?.map((e) => (e as num).toDouble()).toList();
  if (ref == null || ref.isEmpty) {
    st[key] = [for (final v in shape) _r2(v)];
    return (st, null);
  }
  final sim = detSimilarity(shape, ref, gradOnly: true);
  if (sim >= kMovedShapeKeep) {
    st[key] = [for (var i = 0; i < ref.length; i++) _r2(0.8 * ref[i] + 0.2 * shape[i])];
    st.remove('shape_pending');
    return (st, null);
  }
  if (sim < kMovedShapeSim) {
    final p = st['shape_pending'] as Map?;
    final ps = (p?['shape'] as List?)?.map((e) => (e as num).toDouble()).toList() ?? const <double>[];
    if (p != null && p['ir'] == ir && ts - ((p['ts'] as num?) ?? 0).toDouble() >= kMovedMinGapS &&
        ps.isNotEmpty && detSimilarity(shape, ps, gradOnly: true) >= 0.7) {
      st[key] = [for (final v in shape) _r2(v)];
      st.remove('shape_pending');
      return (st, 'moved');
    }
    if (p == null || p['ir'] != ir) {
      st['shape_pending'] = {'shape': [for (final v in shape) _r2(v)], 'ts': ts, 'ir': ir};
    }
  }
  return (st, null);
}

class TamperCheck {
  Map<String, dynamic> state = {};
  Map<String, dynamic> shapeState = {};
  double? last;
  bool due(double t) => last == null || t - last! >= kTamperEveryS;

  /// 'covered' | 'moved' | null (dark alone is a night, not tamper).
  String? check(List<double> grid, double mean, double std, bool ir, double t, [List<double>? shape]) {
    last = t;
    final (st, kind) = assessStill(state, grid, mean, std, ir, t);
    state = st;
    if (kind == 'covered' || kind == 'moved') {
      if (kind == 'moved') {
        shapeState.remove('shape_pending');
        shapeState.remove(ir ? 'shape_ir' : 'shape_day');
      }
      return kind;
    }
    if (kind == null && shape != null && shape.isNotEmpty && stillKind(mean, std) == null) {
      final (ss, sk) = assessShape(shapeState, shape, ir, t);
      shapeState = ss;
      if (sk == 'moved') return 'moved';
    }
    return null;
  }
}

/// The signals of one detection (= shopbox.payload.detection_signals).
Map<String, dynamic> detectionSignals(Map<String, Object?> det,
    {required String detector, required String source}) {
  final type = det['type'];
  final s = <String, dynamic>{'detector': detector, 'source': 'edge', 'device': source};
  final zone = '${det['zone'] ?? ''}';
  if (zone.isNotEmpty) s['zone'] = zone;
  final label = '${det['label'] ?? ''}';
  if (label.isNotEmpty) s['zone_label'] = label;
  if (det['conf'] is num) s['conf'] = det['conf'];
  switch (type) {
    case kDetGatePerson:
      s.addAll({'person': true, 'zone_breach': true, 'kind': 'gate'});
    case kDetLoitering:
      s.addAll({
        'kind': 'loiter',
        'object': 'person',
        'human': true,
        'zone_dwell': true,
        'seconds': det['seconds'] ?? 0
      });
    case kDetPostEmpty:
      s.addAll({'absent': true, 'minutes': det['minutes'] ?? 0});
    case kDetGateOpen:
      s.addAll({'gate_open': true, 'minutes': det['minutes'] ?? 0});
      if (det['sim'] is num) s['sim'] = det['sim'];
    case kDetCameraHealth:
      s.addAll({'kind': '${det['kind'] ?? ''}', 'health': true});
    case kDetCrowd:
      s.addAll({'crowd': true, 'count': det['count'] ?? 0});
    case kDetVehicleInOut || kDetParkingOverstay || kDetWrongParking:
      s.addAll({'vehicle': true, 'object': 'vehicle', 'cls': '${det['cls'] ?? 'vehicle'}'});
      if (type == kDetVehicleInOut) s['dir'] = det['dir'] == 'in' ? 'in' : 'out';
      if (det['minutes'] is num) s['minutes'] = det['minutes'];
      if (det['seconds'] is num) s['seconds'] = det['seconds'];
  }
  return s;
}
