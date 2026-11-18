// cityapp (owner order 9 Nov, B14 "cache route data on the phone for offline
// use"): the city package (GET city/package) is kept on the phone. Without a
// network the phone can still show metro stations / exit gates and plan the
// simple trips itself — up to ONE change (two rides), walking up to 1.2 km to
// and from the stops, fares from the package's own rates (same labels and
// checked dates as the server). Planned trips are also remembered (last 12),
// so a trip planned at home opens again on the road with no signal.
//
// Pure Dart: no plugin calls in the router, so tests run it directly.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:path_provider/path_provider.dart';

import '../api.dart';
import 'city_api.dart';

// ------------------------------------------------------------------ storage

/// Where the package lives. Prod: files in the app documents folder. Tests:
/// [MemoryCityFiles].
abstract class CityFiles {
  Future<String?> read(String name);
  Future<void> write(String name, String data);
}

class DiskCityFiles implements CityFiles {
  Future<File> _f(String name) async {
    final dir = await getApplicationDocumentsDirectory();
    final d = Directory('${dir.path}/city');
    if (!await d.exists()) await d.create(recursive: true);
    return File('${d.path}/$name');
  }

  @override
  Future<String?> read(String name) async {
    try {
      final f = await _f(name);
      return await f.exists() ? await f.readAsString() : null;
    } catch (_) {
      return null; // best-effort: no offline copy
    }
  }

  @override
  Future<void> write(String name, String data) async {
    try {
      final f = await _f(name);
      await f.writeAsString(data, flush: true);
    } catch (_) {
      // best-effort: storage full / denied -> just no offline copy
    }
  }
}

class MemoryCityFiles implements CityFiles {
  final Map<String, String> files = {};
  @override
  Future<String?> read(String name) async => files[name];
  @override
  Future<void> write(String name, String data) async => files[name] = data;
}

Map<String, dynamic> _decode(String s) => jsonDecode(s) as Map<String, dynamic>;

/// The phone's copy of one city's package + remembered plans.
class CityStore {
  CityStore({CityFiles? files}) : files = files ?? DiskCityFiles();
  static CityStore I = CityStore();

  final CityFiles files;
  final Map<String, Map<String, dynamic>> _pkg = {};
  final Map<String, OfflineRouter> _routers = {};

  /// The saved package (null = none on this phone).
  Future<Map<String, dynamic>?> package(String city) async {
    final hit = _pkg[city];
    if (hit != null) return hit;
    final raw = await files.read('pkg_$city.json');
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = raw.length > 200000 ? await compute(_decode, raw) : _decode(raw);
      _pkg[city] = m;
      return m;
    } catch (_) {
      return null; // a broken file = no copy (the next sync replaces it)
    }
  }

  Future<String> version(String city) async => '${(await package(city))?['v'] ?? ''}';

  /// Fetch the package when the server has a newer one. Returns true when
  /// the phone now holds a current copy. Never throws.
  Future<bool> sync(ApiClient api, String city) async {
    try {
      final have = await version(city);
      final r = await api.cityPackage(city, have: have);
      if (r['unchanged'] == true) return have.isNotEmpty;
      if (r['net'] is! Map) return have.isNotEmpty;
      await files.write('pkg_$city.json', jsonEncode(r));
      _pkg[city] = r;
      _routers.remove(city);
      return true;
    } catch (_) {
      return (await version(city)).isNotEmpty;
    }
  }

  Future<OfflineRouter?> router(String city) async {
    final hit = _routers[city];
    if (hit != null) return hit;
    final p = await package(city);
    if (p == null) return null;
    try {
      return _routers[city] = OfflineRouter(p);
    } catch (_) {
      return null;
    }
  }

  // ---- remembered plans (online answers, for the same trip offline) ----
  static String planKey(double a, double b, double c, double d) =>
      [a, b, c, d].map((x) => x.toStringAsFixed(3)).join(',');

  Future<Map<String, dynamic>> _plans() async {
    final raw = await files.read('plans.json');
    if (raw == null) return {};
    try {
      return _decode(raw);
    } catch (_) {
      return {};
    }
  }

  Future<void> rememberPlan(String key, Map<String, dynamic> plan) async {
    final all = await _plans();
    all.remove(key);
    all[key] = {'at': DateTime.now().toUtc().toIso8601String(), 'plan': plan};
    while (all.length > 12) {
      all.remove(all.keys.first);
    }
    await files.write('plans.json', jsonEncode(all));
  }

  Future<({Map<String, dynamic> plan, DateTime at})?> rememberedPlan(String key) async {
    final e = (await _plans())[key];
    if (e is! Map || e['plan'] is! Map) return null;
    return (
      plan: (e['plan'] as Map).cast<String, dynamic>(),
      at: DateTime.tryParse('${e['at']}')?.toLocal() ?? DateTime.now()
    );
  }

  // ---- gap-city: last good directory answer (terminals / ghats / offices)
  // so the guide still opens offline (it is not in the routing package) ----
  static String _dirName(String city, String kind) =>
      'dir_${city.replaceAll(RegExp(r'[^a-z0-9_]'), '')}_${kind.replaceAll(RegExp(r'[^a-z0-9_]'), '')}.json';

  Future<void> rememberDir(String city, String kind, Map<String, dynamic> answer) =>
      files.write(_dirName(city, kind), jsonEncode({'at': DateTime.now().toUtc().toIso8601String(), 'r': answer}));

  Future<Map<String, dynamic>?> rememberedDir(String city, String kind) async {
    final raw = await files.read(_dirName(city, kind));
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = _decode(raw);
      return m['r'] is Map ? (m['r'] as Map).cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  void debugClear() {
    _pkg.clear();
    _routers.clear();
  }
}

// ------------------------------------------------------------------ router

double havM(double a, double b, double c, double d) {
  const r = 6371000.0;
  double rad(double x) => x * math.pi / 180;
  final dp = rad(c - a), dl = rad(d - b);
  final x = math.pow(math.sin(dp / 2), 2) + math.cos(rad(a)) * math.cos(rad(c)) * math.pow(math.sin(dl / 2), 2);
  return r * 2 * math.asin(math.min(1.0, math.sqrt(x)));
}

class _Stop {
  final String id, name, nameBn, kind, st, code;
  final double lat, lon;
  _Stop(this.id, this.name, this.nameBn, this.lat, this.lon, this.kind, this.st, this.code);
  Map<String, dynamic> pt() => {
        'id': id,
        'name': name,
        'name_bn': nameBn,
        'lat': lat,
        'lon': lon,
        'status': st == 'v' ? 'verified' : 'reported'
      };
}

class _Route {
  final String id, mode, name, nameBn, ref, st;
  final List<int> stops;
  final List<double> km;
  final double hw, spd, dwell;
  _Route(this.id, this.mode, this.name, this.nameBn, this.ref, this.st, this.stops, this.km, this.hw,
      this.spd, this.dwell);
  double t(int a, int b, double pf) {
    final sp = mode == 'metro' ? spd : spd * pf;
    return (km[b] - km[a]) * 3600.0 / sp + dwell * (b - a);
  }
}

class _Ride {
  final int route, from, to; // positions in the route
  _Ride(this.route, this.from, this.to);
}

class _Cand {
  final double sec;
  final int fareLo, fareHi;
  final int accessStop, egressStop, accessM, egressM;
  final List<_Ride> rides;
  final List<int> xferM; // walk between rides
  _Cand(this.sec, this.fareLo, this.fareHi, this.accessStop, this.egressStop, this.accessM, this.egressM,
      this.rides, this.xferM);
}

/// Offline trip planner over the saved package (the server's network format:
/// `net.stops {cols, rows}`, `net.routes [{id, mode, name, name_bn, ref, st,
/// stops, km, hw?, spd?}]`, `net.gates`, `rates`, `overrides`).
class OfflineRouter {
  static const walkMax = 1200.0, xferMax = 350.0, walkSpeed = 1.2, detour = 1.3;
  static const defaults = {
    'metro': [8.0, 38.0, 30.0],
    'bus': [10.0, 12.0, 25.0],
    'leguna': [10.0, 14.0, 20.0],
    'water': [30.0, 12.0, 60.0],
  };

  final List<_Stop> stops = [];
  final List<_Route> routes = [];
  final Map<String, dynamic> rates;
  final Map<String, dynamic> complaint;
  final Map<int, List<Map<String, dynamic>>> gates = {};
  final String attribution, version, city;
  late final List<List<(int, int)>> stopRoutes; // stop -> (route, pos)
  final Map<(int, int), List<int>> _grid = {};
  final Map<int, int> _routeOfNet = {}; // package route index -> ours

  OfflineRouter(Map<String, dynamic> pkg)
      : rates = (pkg['rates'] as Map?)?.cast<String, dynamic>() ?? const {},
        complaint = (pkg['complaint'] as Map?)?.cast<String, dynamic>() ?? const {},
        attribution = '${pkg['attribution'] ?? ''}',
        version = '${pkg['v'] ?? ''}',
        city = '${pkg['city'] ?? ''}' {
    final net = (pkg['net'] as Map).cast<String, dynamic>();
    final ov = (pkg['overrides'] as Map?)?.cast<String, dynamic>() ?? const {};
    final hideS = {...((ov['hide_stops'] as List?) ?? const []).map((e) => '$e')};
    final hideR = {...((ov['hide_routes'] as List?) ?? const []).map((e) => '$e')};
    final sm = (net['stops'] as Map).cast<String, dynamic>();
    final cols = [...(sm['cols'] as List).map((e) => '$e')];
    int ix(String c) => cols.indexOf(c);
    final iId = ix('id'), iN = ix('name'), iB = ix('name_bn'), iLa = ix('lat'), iLo = ix('lon');
    final iK = ix('kind'), iS = ix('st'), iC = ix('code');
    final hidden = <int>{};
    for (final row in (sm['rows'] as List)) {
      final r = row as List;
      String g(int i) => i >= 0 && i < r.length && r[i] != null ? '${r[i]}' : '';
      double n(int i) => i >= 0 && i < r.length && r[i] is num ? (r[i] as num).toDouble() : 0;
      if (hideS.contains(g(iId))) hidden.add(stops.length);
      stops.add(_Stop(g(iId), g(iN), g(iB), n(iLa), n(iLo), g(iK), g(iS), g(iC)));
    }
    final netRoutes = (net['routes'] as List? ?? const []);
    for (var n = 0; n < netRoutes.length; n++) {
      final r = (netRoutes[n] as Map).cast<String, dynamic>();
      if (hideR.contains('${r['id']}')) continue;
      final idx = [...((r['stops'] as List?) ?? const []).map((x) => (x as num).toInt())];
      if (idx.length < 2 || idx.any((i) => i < 0 || i >= stops.length)) continue;
      var km = [...((r['km'] as List?) ?? const []).map((x) => (x as num).toDouble())];
      if (km.length != idx.length) {
        km = [0.0];
        for (var k = 1; k < idx.length; k++) {
          final a = stops[idx[k - 1]], b = stops[idx[k]];
          km.add(km.last + havM(a.lat, a.lon, b.lat, b.lon) * 1.25 / 1000.0);
        }
      }
      final mode = '${r['mode'] ?? 'bus'}';
      final d = defaults[mode] ?? defaults['bus']!;
      _routeOfNet[n] = routes.length;
      routes.add(_Route('${r['id']}', mode, '${r['name'] ?? ''}', '${r['name_bn'] ?? ''}', '${r['ref'] ?? ''}',
          '${r['st'] ?? 'r'}', idx, km, (r['hw'] as num?)?.toDouble() ?? d[0],
          (r['spd'] as num?)?.toDouble() ?? d[1], (r['dwell'] as num?)?.toDouble() ?? d[2]));
    }
    for (final g in (net['gates'] as List? ?? const [])) {
      final m = (g as Map).cast<String, dynamic>();
      final st = (m['st'] as num?)?.toInt();
      if (st != null) gates.putIfAbsent(st, () => []).add(m);
    }
    stopRoutes = List.generate(stops.length, (_) => <(int, int)>[]);
    for (var ri = 0; ri < routes.length; ri++) {
      final rs = routes[ri].stops;
      for (var p = 0; p < rs.length; p++) {
        stopRoutes[rs[p]].add((ri, p));
      }
    }
    for (var i = 0; i < stops.length; i++) {
      if (hidden.contains(i) || stopRoutes[i].isEmpty) continue;
      _grid.putIfAbsent(_cell(stops[i].lat, stops[i].lon), () => []).add(i);
    }
  }

  static (int, int) _cell(double lat, double lon) => ((lat / 0.005).floor(), (lon / 0.005).floor());

  List<(int, double)> near(double lat, double lon, double radius) {
    final n = (radius / 500).ceil() + 1;
    final c = _cell(lat, lon);
    final out = <(int, double)>[];
    for (var a = c.$1 - n; a <= c.$1 + n; a++) {
      for (var b = c.$2 - n; b <= c.$2 + n; b++) {
        for (final i in _grid[(a, b)] ?? const <int>[]) {
          final d = havM(lat, lon, stops[i].lat, stops[i].lon);
          if (d <= radius) out.add((i, d));
        }
      }
    }
    out.sort((x, y) => x.$2.compareTo(y.$2));
    return out;
  }

  bool covers(double lat, double lon) => near(lat, lon, walkMax).isNotEmpty;

  // ---- fares (same rules as the server's fares.py) ----
  Map<String, dynamic> _r(String k) => (rates[k] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> _meta(Map<String, dynamic> r) => {
        'label': r['label'] ?? 'estimate',
        'checked': r['checked'] ?? '',
        'source': r['source'] ?? '',
        'source_url': r['source_url'] ?? ''
      };
  double _n(Map<String, dynamic> r, String k, double def) => (r[k] as num?)?.toDouble() ?? def;

  /// [a] / [b] = station codes (metro): the official chart wins over the
  /// per-km rule, exactly like the server (fares.py metro()).
  Map<String, dynamic> fare(String mode, double km, {String a = '', String b = ''}) {
    switch (mode) {
      case 'metro':
        final r = _r('metro');
        final step = _n(r, 'round_to', 10).clamp(1, 100);
        final hit = metroChartTk(r['chart'], a, b);
        num tk = hit ?? ((km * _n(r, 'per_km', 5)) / step).round() * step;
        if (hit == null) tk = tk.clamp(_n(r, 'min', 20), _n(r, 'max', 100));
        final disc = _n(r, 'card_discount_pct', 0);
        return {
          ..._meta(r),
          'low': tk.round(),
          'high': tk.round(),
          'basis': hit != null ? 'chart' : 'rate',
          'card': (tk - tk * disc / 100).round()
        };
      case 'bus':
        final r = _r('bus');
        final mn = _n(r, 'min', 10);
        final lo = math.max(mn, km * _n(r, 'per_km_low', 2.53)).round();
        final hi = math.max(mn, km * _n(r, 'per_km_high', 2.7)).round();
        return {..._meta(r), 'low': lo, 'high': math.max(lo, hi), 'basis': 'rate'};
      default:
        final r = _r(mode == 'water' ? 'water' : mode);
        if (r.isEmpty) return {'label': 'estimate', 'low': 0, 'high': 0, 'basis': 'estimate'};
        final lo = math.max(_n(r, 'min_low', 10), km * _n(r, 'per_km_low', 3));
        final hi = math.max(_n(r, 'min_high', 15), km * _n(r, 'per_km_high', 4));
        final l = (lo / 5).floor() * 5, h = (hi / 5).ceil() * 5;
        return {..._meta(r), 'low': l, 'high': math.max(l, h), 'basis': 'estimate'};
    }
  }

  static double peakFactor(int minute) {
    final h = (minute ~/ 60) % 24;
    if ((h >= 8 && h < 11) || (h >= 17 && h < 21)) return 0.75;
    if (h >= 22 || h < 6) return 1.35;
    return 1.0;
  }

  // ---- search ----
  /// Plans like the server (same JSON shape, `offline: true`). [minute] =
  /// minute of the day in Dhaka time.
  Map<String, dynamic> plan(double oLat, double oLon, double dLat, double dLon, {int? minute}) {
    final now = DateTime.now().toUtc().add(const Duration(hours: 6));
    final mi = minute ?? now.hour * 60 + now.minute;
    final pf = peakFactor(mi);
    final access = {for (final e in near(oLat, oLon, walkMax)) e.$1: e.$2 * detour};
    final egress = {for (final e in near(dLat, dLon, walkMax)) e.$1: e.$2 * detour};
    final cands = <_Cand>[];
    if (access.isEmpty || egress.isEmpty) return _answer(cands, oLat, oLon, dLat, dLon, mi);

    // round 1: best arrival per (stop) after one ride, and direct trips
    final reach = <int, (double, _Ride, int, int, int)>{}; // stop -> (sec, ride, accessStop, accessM, fareLo)
    final reachHi = <int, int>{};
    for (final a in access.entries) {
      for (final (ri, p) in stopRoutes[a.key]) {
        final r = routes[ri];
        final wait = r.hw * 30.0;
        for (var q = p + 1; q < r.stops.length; q++) {
          final s = r.stops[q];
          final sec = a.value / walkSpeed + wait + r.t(p, q, pf);
          final f = fare(r.mode, r.km[q] - r.km[p], a: stops[r.stops[p]].code, b: stops[s].code);
          final eg = egress[s];
          if (eg != null) {
            cands.add(_Cand(sec + eg / walkSpeed, f['low'] as int, f['high'] as int, a.key, s, a.value.round(),
                eg.round(), [_Ride(ri, p, q)], const []));
          }
          final cur = reach[s];
          if (cur == null || sec < cur.$1) {
            reach[s] = (sec, _Ride(ri, p, q), a.key, a.value.round(), f['low'] as int);
            reachHi[s] = f['high'] as int;
          }
        }
      }
    }
    // round 2: one change (same stop or a short walk), then ride to egress
    for (final e in reach.entries) {
      final (sec0, ride0, acc, accM, lo0) = e.value;
      final hi0 = reachHi[e.key] ?? lo0;
      final xs = <(int, double)>[(e.key, 0.0), ...near(stops[e.key].lat, stops[e.key].lon, xferMax).where((x) => x.$1 != e.key)];
      for (final (s2, dx) in xs) {
        final walk = dx * detour;
        for (final (ri, p) in stopRoutes[s2]) {
          if (ri == ride0.route) continue;
          final r = routes[ri];
          for (var q = p + 1; q < r.stops.length; q++) {
            final eg = egress[r.stops[q]];
            if (eg == null) continue;
            final f = fare(r.mode, r.km[q] - r.km[p], a: stops[r.stops[p]].code, b: stops[r.stops[q]].code);
            final sec = sec0 + walk / walkSpeed + r.hw * 30.0 + r.t(p, q, pf) + eg / walkSpeed;
            cands.add(_Cand(sec, lo0 + (f['low'] as int), hi0 + (f['high'] as int), acc, r.stops[q], accM,
                eg.round(), [ride0, _Ride(ri, p, q)], [walk.round()]));
          }
        }
      }
    }
    return _answer(cands, oLat, oLon, dLat, dLon, mi);
  }

  Map<String, dynamic> _walk(int m, Map<String, dynamic> a, Map<String, dynamic> b) => {
        'mode': 'walk',
        'meters': m,
        'minutes': math.max(1, (m / walkSpeed / 60).round()),
        'from': a,
        'to': b,
        'fare': null,
      };

  Map<String, dynamic> _option(_Cand c, double oLat, double oLon, double dLat, double dLon, double pf) {
    final legs = <Map<String, dynamic>>[];
    final first = routes[c.rides.first.route];
    if (c.accessM > 30) {
      legs.add(_walk(c.accessM, {'name': '', 'lat': oLat, 'lon': oLon, 'here': true},
          stops[first.stops[c.rides.first.from]].pt()));
    }
    for (var k = 0; k < c.rides.length; k++) {
      final rd = c.rides[k];
      final r = routes[rd.route];
      if (k > 0 && c.xferM[k - 1] > 30) {
        final prev = routes[c.rides[k - 1].route];
        legs.add(_walk(c.xferM[k - 1], stops[prev.stops[c.rides[k - 1].to]].pt(), stops[r.stops[rd.from]].pt()));
      }
      final km = r.km[rd.to] - r.km[rd.from];
      final via = [for (var p = rd.from + 1; p < rd.to; p++) stops[r.stops[p]]];
      final leg = <String, dynamic>{
        'mode': r.mode,
        'route_id': r.id,
        'route': r.name.isNotEmpty ? r.name : r.ref,
        'route_bn': r.nameBn,
        'ref': r.ref,
        'status': r.st == 'v' ? 'verified' : 'reported',
        'board': stops[r.stops[rd.from]].pt(),
        'alight': stops[r.stops[rd.to]].pt(),
        'towards': stops[r.stops.last].pt(),
        'stops': rd.to - rd.from,
        'via': [for (final s in via.take(12)) s.name],
        'via_bn': [for (final s in via.take(12)) s.nameBn],
        'wait_min': (r.hw / 2).round(),
        'minutes': (r.t(rd.from, rd.to, pf) / 60).round(),
        'km': double.parse(km.toStringAsFixed(1)),
        'fare': fare(r.mode, km, a: stops[r.stops[rd.from]].code, b: stops[r.stops[rd.to]].code),
        'headway_min': r.hw.round(),
      };
      if (r.mode == 'metro') {
        // which exit: nearest gate to the next ride's stop, else to the destination
        var tLat = dLat, tLon = dLon;
        if (k + 1 < c.rides.length) {
          final nx = routes[c.rides[k + 1].route];
          final s = stops[nx.stops[c.rides[k + 1].from]];
          tLat = s.lat;
          tLon = s.lon;
        }
        leg['exit_gate'] = bestGate(r.stops[rd.to], tLat, tLon);
      }
      legs.add(leg);
    }
    if (c.egressM > 30) {
      legs.add(_walk(c.egressM, stops[c.egressStop].pt(), {'name': '', 'lat': dLat, 'lon': dLon, 'dest': true}));
    }
    final veh = legs.where((l) => l['mode'] != 'walk').toList();
    final labels = {for (final l in veh) '${(l['fare'] as Map)['label']}'};
    return {
      'minutes': (c.sec / 60).round(),
      'fare': {
        'low': c.fareLo,
        'high': c.fareHi,
        'label': labels.length == 1 ? labels.first : 'mixed',
      },
      'changes': math.max(0, veh.length - 1),
      'walk_m': legs.where((l) => l['mode'] == 'walk').fold<int>(0, (s, l) => s + (l['meters'] as int)),
      'modes': [for (final l in legs) l['mode']],
      'status': veh.every((l) => l['status'] == 'verified') ? 'verified' : 'reported',
      'legs': legs,
    };
  }

  Map<String, dynamic>? bestGate(int stop, double lat, double lon) {
    final gs = gates[stop];
    if (gs == null || gs.isEmpty) return null;
    double d(Map<String, dynamic> g) =>
        havM((g['lat'] as num?)?.toDouble() ?? 0, (g['lon'] as num?)?.toDouble() ?? 0, lat, lon);
    final g = gs.reduce((a, b) => d(a) <= d(b) ? a : b);
    return {for (final k in ['ref', 'name', 'name_bn', 'side', 'lat', 'lon', 'near', 'status']) k: g[k]};
  }

  Map<String, dynamic> _answer(List<_Cand> cands, double oLat, double oLon, double dLat, double dLon, int mi) {
    final pf = peakFactor(mi);
    final base = {
      'offline': true,
      'city': city,
      'attribution': attribution,
      'data_version': version,
      'complaint': complaint,
      'google_maps': googleMapsTransit(oLat, oLon, dLat, dLon),
      'other_ways': otherWays(havM(oLat, oLon, dLat, dLon), pf),
    };
    if (cands.isEmpty) return {...base, 'ok': false, 'reason': 'no_route', 'options': {}};
    final fastest = cands.reduce((a, b) => a.sec <= b.sec ? a : b);
    final cap = fastest.sec * 1.6 + 1200;
    final ok = cands.where((c) => c.sec <= cap).toList();
    _Cand best(int Function(_Cand, _Cand) cmp) => ok.reduce((a, b) => cmp(a, b) <= 0 ? a : b);
    final cheapest = best((a, b) => a.fareHi != b.fareHi ? a.fareHi - b.fareHi : a.sec.compareTo(b.sec));
    final fewest = best((a, b) => a.rides.length != b.rides.length ? a.rides.length - b.rides.length : a.sec.compareTo(b.sec));
    // Safer at night: metro first, little walking, verified routes
    double night(_Cand c) {
      var cost = c.sec / 60 + (c.accessM + c.egressM + c.xferM.fold<int>(0, (s, x) => s + x)) / 40;
      for (final rd in c.rides) {
        final r = routes[rd.route];
        if (r.mode != 'metro') cost += 6 + (r.st == 'v' ? 0 : 4);
      }
      return cost;
    }

    final safer = ok.reduce((a, b) => night(a) <= night(b) ? a : b);
    return {
      ...base,
      'ok': true,
      'options': {
        'cheapest': _option(cheapest, oLat, oLon, dLat, dLon, pf),
        'fastest': _option(fastest, oLat, oLon, dLat, dLon, pf),
        'fewest_changes': _option(fewest, oLat, oLon, dLat, dLon, pf),
        'safer_night': _option(safer, oLat, oLon, dLat, dLon, pf),
      },
      'warnings': [],
    };
  }

  /// CNG / ride share / rickshaw / walk from the package rates.
  List<Map<String, dynamic>> otherWays(double crow, double pf) {
    final street = crow * 1.35, km = street / 1000;
    final out = <Map<String, dynamic>>[];
    Map<String, dynamic> range(String k, double mins) {
      final r = _r(k);
      if (r.isEmpty) return {'label': 'estimate', 'low': 0, 'high': 0};
      final lo = _n(r, 'base_low', 0) + km * _n(r, 'per_km_low', 0) + mins * _n(r, 'per_min', 0) * 0.5;
      final hi = _n(r, 'base_high', 0) + km * _n(r, 'per_km_high', 0) + mins * _n(r, 'per_min', 0);
      final l = (lo / 5).floor() * 5, h = (hi / 5).ceil() * 5;
      return {..._meta(r), 'low': l, 'high': math.max(l, h), 'basis': 'estimate'};
    }

    if (crow <= 2000) out.add({'mode': 'walk', 'minutes': math.max(1, (street / walkSpeed / 60).round()), 'km': km, 'fare': null});
    if (crow <= 5000) {
      out.add({'mode': 'rickshaw', 'minutes': (street / (9 * pf / 3.6) / 60 + 3).round(), 'km': km, 'fare': fare('rickshaw', km)});
    }
    if (crow >= 800) {
      final cmin = street / (16 * pf / 3.6) / 60;
      final c = _r('cng');
      double meter(double wait) =>
          _n(c, 'first_tk', 40) + math.max(0, km - _n(c, 'first_km', 2)) * _n(c, 'per_km', 12) + wait * _n(c, 'wait_per_min', 2);
      final lo = meter(0).round(), hi = meter(cmin / 3).round();
      out.add({
        'mode': 'cng',
        'minutes': (cmin + 5).round(),
        'km': km,
        'fare': {..._meta(c), 'low': lo, 'high': math.max(lo, hi), 'basis': 'meter', 'meter': lo, 'overcharge_note': true}
      });
      final bmin = street / (20 * pf / 3.6) / 60, vmin = street / (15 * pf / 3.6) / 60;
      out.add({'mode': 'ride_bike', 'minutes': (bmin + 6).round(), 'km': km, 'fare': range('ride_bike', bmin)});
      out.add({'mode': 'ride_car', 'minutes': (vmin + 8).round(), 'km': km, 'fare': range('ride_car', vmin)});
    }
    return out;
  }

  /// mapapp: route shapes for the City map layers — OUR data only (never
  /// mixed into the base-map tiles). One entry per route direction.
  List<Map<String, dynamic>> routeShapes({Set<String>? modes, Set<String>? ids}) {
    final out = <Map<String, dynamic>>[];
    for (final r in routes) {
      if (modes != null && !modes.contains(r.mode)) continue;
      if (ids != null && !ids.contains(r.id)) continue;
      out.add({
        'id': r.id,
        'mode': r.mode,
        'name': r.name.isNotEmpty ? r.name : r.ref,
        'name_bn': r.nameBn,
        'status': r.st == 'v' ? 'verified' : 'reported',
        'coords': [
          for (final si in r.stops) [stops[si].lon, stops[si].lat]
        ],
        'stops': [for (final si in r.stops) stops[si].pt()],
        'fare': fare(r.mode, r.km.last),
      });
    }
    return out;
  }

  /// Metro stations in line order (offline metro guide).
  List<Map<String, dynamic>> stations() {
    final out = <Map<String, dynamic>>[];
    final metro = routes.where((r) => r.mode == 'metro');
    if (metro.isEmpty) return out;
    for (final si in metro.first.stops) {
      out.add({...stops[si].pt(), 'code': stops[si].code, 'gates': gates[si]?.length ?? 0});
      // gap-nearby: km along the line (station-to-station fare offline)
      final k = metro.first.stops.indexOf(si);
      if (k >= 0 && k < metro.first.km.length) out.last['km'] = metro.first.km[k];
    }
    return out;
  }

  static String _routeName(_Route r) => r.name.isNotEmpty ? r.name : r.ref;

  /// Offline station guide (gates + connecting buses; no hours here — the
  /// package's `net.metro` carries those).
  Map<String, dynamic>? stationGuide(String id, {double? lat, double? lon}) {
    final si = stops.indexWhere((s) => s.id == id);
    if (si < 0) return null;
    final gs = [
      for (final g in gates[si] ?? const <Map<String, dynamic>>[])
        {
          ...g,
          'stands': [for (final x in (g['stands'] as List? ?? const [])) if (x is num && x < stops.length) stops[x.toInt()].pt()],
          'buses': [
            for (final x in (g['routes'] as List? ?? const []))
              if (x is num && _routeOfNet[x.toInt()] != null) _routeName(routes[_routeOfNet[x.toInt()]!])
          ],
        }
    ];
    final buses = <String>{};
    for (final (j, _) in near(stops[si].lat, stops[si].lon, 350)) {
      for (final (ri, _) in stopRoutes[j]) {
        final r = routes[ri];
        if (r.mode != 'metro') buses.add(r.name.isNotEmpty ? r.name : r.ref);
      }
    }
    return {
      'station': {...stops[si].pt(), 'code': stops[si].code},
      'gates': gs,
      'which_gate': lat != null && lon != null ? bestGate(si, lat, lon) : null,
      'connecting_buses': (buses.where((b) => b.isNotEmpty).toList()..sort()).take(40).toList(),
    };
  }
}

/// The free Google Maps transit link (no API call, no key).
String googleMapsTransit(double? oLat, double? oLon, double? dLat, double? dLon) {
  final q = <String, String>{'api': '1', 'travelmode': 'transit'};
  if (oLat != null && oLon != null) q['origin'] = '${oLat.toStringAsFixed(6)},${oLon.toStringAsFixed(6)}';
  if (dLat != null && dLon != null) q['destination'] = '${dLat.toStringAsFixed(6)},${dLon.toStringAsFixed(6)}';
  return Uri.https('www.google.com', '/maps/dir/', q).toString();
}

/// gap-nearby: the official metro chart amount for a station pair (either
/// direction), or null. [chart] = `[{a, b, tk}]` from the server / package.
int? metroChartTk(Object? chart, String a, String b) {
  if (a.isEmpty || b.isEmpty || chart is! List) return null;
  for (final e in chart) {
    if (e is! Map) continue;
    final x = '${e['a'] ?? ''}', y = '${e['b'] ?? ''}';
    if ((x == a && y == b) || (x == b && y == a)) return (e['tk'] as num?)?.round();
  }
  return null;
}
