import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import 'train_api.dart';
import 'train_v2_native.dart';

/// train-app (Train Tracker V2, D): OFFLINE like the best offline train apps.
///
///  * [TrainOfflineStore]: every timetable + the learned tower-to-track map
///    on the phone (one small file, the size is shown before download; the
///    app offers a refresh when it is older than 7 days).
///  * [trainOfflineLine]: with no internet AND no GPS, where the train is —
///    from the phone's serving cell tower (when the map knows it) else from
///    the timetable — in the SAME "line" shape the server sends, always
///    labelled (tower / timetable estimate), never "100 % accurate".
///  * [TrainOutbox]: check-ins and 16318 reports made offline wait on the
///    phone and are sent when the internet returns (the GPS points of a
///    running share wait in TrainShareController's own saved queue).

/// One stop of a timetable in the offline pack.
class OffStop {
  final String id, bn, en;
  final double km;
  final double? lat, lng;

  /// minutes after the origin's departure (arrival / departure here)
  final int arrMin, depMin;
  final bool stop;
  const OffStop(this.id, this.bn, this.en, this.km,
      {this.lat, this.lng, required this.arrMin, required this.depMin, this.stop = true});
}

class OffTrain {
  final String no, nameBn, nameEn;

  /// origin departure, minutes after midnight (Dhaka time)
  final int depMin;

  /// weekdays it does NOT run (DateTime.weekday: 1 = Monday .. 7 = Sunday)
  final Set<int> offDays;
  final List<OffStop> stops;
  const OffTrain(this.no, this.nameBn, this.nameEn, this.depMin, this.offDays, this.stops);

  double get km => stops.isEmpty ? 0 : stops.last.km;
}

int? _hm(Object? v) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch('${v ?? ''}');
  if (m == null) return null;
  return int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!);
}

/// The server's off-day numbers are Python's (0 = Monday .. 6 = Sunday)
/// unless the pack says `off_day_base: 1` (1 = Monday .. 7 = Sunday).
Set<int> _offDays(Object? raw, int base) => {
      for (final d in (raw is List ? raw : const []))
        if (d is num) base == 0 ? d.toInt() + 1 : d.toInt()
    };

OffTrain? parseOffTrain(Map raw, {int offDayBase = 0}) {
  final stopsRaw = raw['stops'];
  if (stopsRaw is! List || stopsRaw.length < 2) return null;
  int? first;
  var dayAdd = 0;
  int? prev;
  final stops = <OffStop>[];
  for (final s in stopsRaw) {
    if (s is! Map) continue;
    final a = _hm(s['arr']) ?? _hm(s['dep']);
    final d = _hm(s['dep']) ?? _hm(s['arr']);
    if (a == null || d == null) continue;
    first ??= d;
    // past midnight: times go "down" — add a day
    var aa = a + dayAdd;
    if (prev != null && aa < prev) {
      dayAdd += 1440;
      aa += 1440;
    }
    var dd = d + dayAdd;
    if (dd < aa) {
      dayAdd += 1440;
      dd += 1440;
    }
    prev = dd;
    stops.add(OffStop('${s['id']}', '${s['bn'] ?? ''}', '${s['en'] ?? ''}',
        (s['km'] as num?)?.toDouble() ?? 0,
        lat: (s['lat'] as num?)?.toDouble(),
        lng: (s['lng'] as num?)?.toDouble(),
        arrMin: aa - first,
        depMin: dd - first,
        stop: s['stop'] != false));
  }
  if (first == null || stops.length < 2) return null;
  return OffTrain('${raw['no']}', '${raw['name_bn'] ?? ''}', '${raw['name_en'] ?? ''}', first,
      _offDays(raw['off_days'], offDayBase), stops);
}

/// The learned tower -> track map entry: where on the line this tower was
/// seen by riders (km from the train's origin, for that train), or the
/// station it covers.
class OffTower {
  final String? stationId, trainNo;
  final double? km;
  final int samples;
  const OffTower({this.stationId, this.trainNo, this.km, this.samples = 0});
}

class TrainOfflinePack {
  final String version;
  final DateTime? savedAt;
  final int sizeBytes;
  final Map<String, OffTrain> trains;
  final Map<String, List<OffTower>> towers;
  const TrainOfflinePack(
      {required this.version,
      this.savedAt,
      this.sizeBytes = 0,
      this.trains = const {},
      this.towers = const {}});

  bool get stale => savedAt == null || DateTime.now().difference(savedAt!).inDays >= 7;

  static TrainOfflinePack fromJson(Map<String, dynamic> j, {DateTime? savedAt, int sizeBytes = 0}) {
    final base = (j['off_day_base'] as num?)?.toInt() ?? 0;
    final trains = <String, OffTrain>{};
    for (final t in (j['trains'] as List? ?? const [])) {
      if (t is! Map) continue;
      final o = parseOffTrain(t, offDayBase: base);
      if (o != null) trains[o.no] = o;
    }
    final towers = <String, List<OffTower>>{};
    for (final w in (j['towers'] as List? ?? const [])) {
      if (w is! Map || w['k'] == null) continue;
      (towers['${w['k']}'] ??= []).add(OffTower(
          stationId: w['s'] == null ? null : '${w['s']}',
          trainNo: w['no'] == null ? null : '${w['no']}',
          km: (w['km'] as num?)?.toDouble(),
          samples: (w['n'] as num?)?.toInt() ?? 0));
    }
    return TrainOfflinePack(
        version: '${j['version'] ?? ''}',
        savedAt: savedAt,
        sizeBytes: sizeBytes,
        trains: trains,
        towers: towers);
  }
}

/// Where the train is, worked out on the phone.
class OffPosition {
  /// tower | timetable
  final String source;

  /// not_started | running | arrived | off_day
  final String state;
  final double km;
  final DateTime at;
  const OffPosition(this.source, this.state, this.km, this.at);
}

/// The run of [t] that matters at [now]: the one running now, else today's.
DateTime? _runStart(OffTrain t, DateTime now) {
  for (final back in [1, 0]) {
    final day = DateTime(now.year, now.month, now.day).subtract(Duration(days: back));
    if (t.offDays.contains(day.weekday)) continue;
    final start = day.add(Duration(minutes: t.depMin));
    final end = start.add(Duration(minutes: t.stops.last.arrMin));
    if (!now.isBefore(start) && !now.isAfter(end)) return start;
  }
  final today = DateTime(now.year, now.month, now.day);
  if (t.offDays.contains(today.weekday)) return null;
  return today.add(Duration(minutes: t.depMin));
}

/// Timetable estimate: linear between the stops' times, standing still
/// while the timetable says it stands at a station.
OffPosition timetablePosition(OffTrain t, DateTime now) {
  final start = _runStart(t, now);
  if (start == null) return OffPosition('timetable', 'off_day', 0, now);
  final m = now.difference(start).inSeconds / 60.0;
  if (m < 0) return OffPosition('timetable', 'not_started', 0, now);
  if (m >= t.stops.last.arrMin) return OffPosition('timetable', 'arrived', t.km, now);
  for (var i = 0; i < t.stops.length; i++) {
    final s = t.stops[i];
    if (m >= s.arrMin && m <= s.depMin) return OffPosition('timetable', 'running', s.km, now);
    if (i + 1 < t.stops.length) {
      final n = t.stops[i + 1];
      if (m > s.depMin && m < n.arrMin) {
        final f = (m - s.depMin) / (n.arrMin - s.depMin);
        return OffPosition('timetable', 'running', s.km + (n.km - s.km) * f, now);
      }
    }
  }
  return OffPosition('timetable', 'running', 0, now);
}

/// Tower position: the phone's serving cell in the learned map, for THIS
/// train (its own km first, else a station of its route).
OffPosition? towerPosition(TrainOfflinePack p, OffTrain t, TrainCell? cell, DateTime now) {
  if (cell == null) return null;
  final hits = p.towers[cell.key];
  if (hits == null || hits.isEmpty) return null;
  OffTower? best;
  for (final h in hits) {
    if (h.trainNo == t.no && h.km != null && (best == null || h.samples > best.samples)) best = h;
  }
  if (best != null) return OffPosition('tower', 'running', best.km!.clamp(0, t.km).toDouble(), now);
  for (final h in hits) {
    final st = t.stops.where((s) => s.id == h.stationId);
    if (st.isNotEmpty) return OffPosition('tower', 'running', st.first.km, now);
  }
  return null;
}

/// The offline "line" in the server's line_view shape (+ "source"), so the
/// same timeline widget draws it. ETAs/times are from the timetable.
Map<String, dynamic> trainOfflineLine(OffTrain t, OffPosition pos) {
  final start = _runStart(t, pos.at) ?? DateTime(pos.at.year, pos.at.month, pos.at.day)
      .add(Duration(minutes: t.depMin));
  final out = <Map<String, dynamic>>[];
  int? nowI, nextI;
  final known = pos.state == 'running' || pos.state == 'arrived';
  for (var i = 0; i < t.stops.length; i++) {
    final s = t.stops[i];
    final passed = known && s.km * 1000 <= pos.km * 1000 + 150;
    if (passed) nowI = i;
    if (!passed && nextI == null && known) nextI = i;
    final sched = start.add(Duration(minutes: s.arrMin));
    out.add({
      'id': s.id, 'bn': s.bn, 'en': s.en, 'km': s.km, 'stop': s.stop,
      'lat': s.lat, 'lng': s.lng,
      'sched': sched.toIso8601String(), 'eta': sched.toIso8601String(), 'passed': passed,
    });
  }
  int? passing;
  if (nowI != null && (pos.km - t.stops[nowI].km) <= 1.5) passing = nowI;
  return {
    'stations': out,
    'now_index': nowI,
    'passing': passing,
    'next_index': nextI,
    'source': pos.source,
    'state': pos.state,
  };
}

typedef TrainPackFetch = Future<Map<String, dynamic>> Function(String? have);

/// The offline file. Tests set [TrainOfflineStore.I] with a temp [dir].
class TrainOfflineStore extends ChangeNotifier {
  TrainOfflineStore({this.dir});
  static TrainOfflineStore I = TrainOfflineStore();

  final Directory? dir;
  TrainOfflinePack? _pack;
  bool _loaded = false;
  bool busy = false;

  TrainOfflinePack? get pack => _pack;

  Future<File> _file() async {
    final d = dir ?? await getApplicationSupportDirectory();
    return File('${d.path}/train_offline_v2.json');
  }

  Future<TrainOfflinePack?> load() async {
    if (_loaded) return _pack;
    _loaded = true;
    try {
      final f = await _file();
      if (!await f.exists()) return null;
      final raw = await f.readAsString();
      final j = jsonDecode(raw) as Map<String, dynamic>;
      _pack = TrainOfflinePack.fromJson(Map<String, dynamic>.from(j['pack'] as Map),
          savedAt: DateTime.tryParse('${j['saved_at']}'), sizeBytes: raw.length);
      notifyListeners();
    } catch (_) {
      _pack = null; // a broken file is ignored (downloaded again)
    }
    return _pack;
  }

  /// Download (or refresh) the pack. Returns false on no internet.
  Future<bool> download(TrainPackFetch fetch) async {
    if (busy) return false;
    busy = true;
    notifyListeners();
    try {
      final j = await fetch(_pack?.version);
      // {same: true} (or not_modified): the phone already has this version
      if ((j['same'] == true || j['not_modified'] == true) && _pack != null) {
        await _save(j, touchOnly: true);
        return true;
      }
      await _save(j);
      return true;
    } catch (_) {
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _save(Map<String, dynamic> j, {bool touchOnly = false}) async {
    final f = await _file();
    final now = DateTime.now();
    if (touchOnly) {
      final old = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      old['saved_at'] = now.toIso8601String();
      final raw = jsonEncode(old);
      await f.writeAsString(raw, flush: true);
      _pack = TrainOfflinePack.fromJson(Map<String, dynamic>.from(old['pack'] as Map),
          savedAt: now, sizeBytes: raw.length);
      return;
    }
    final raw = jsonEncode({'saved_at': now.toIso8601String(), 'pack': j});
    await f.writeAsString(raw, flush: true);
    _pack = TrainOfflinePack.fromJson(j, savedAt: now, sizeBytes: raw.length);
  }

  Future<void> remove() async {
    try {
      final f = await _file();
      if (await f.exists()) await f.delete();
    } catch (_) {
      // best-effort
    }
    _pack = null;
    notifyListeners();
  }

  @visibleForTesting
  void debugSet(TrainOfflinePack? p) {
    _pack = p;
    _loaded = true;
    notifyListeners();
  }
}

/// Human size: "1.2 MB" / "640 KB" (digits localised by the caller).
String trainSizeLabel(int bytes) {
  if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / 1024).ceil()} KB';
}

// ------------------------------------------------------------------ outbox

/// One report made without internet.
class TrainOutItem {
  final String kind; // checkin | text
  final String no;
  final Map<String, dynamic> body;
  const TrainOutItem(this.kind, this.no, this.body);
  Map<String, dynamic> toJson() => {'kind': kind, 'no': no, 'body': body};
}

/// Check-ins and shared texts (16318 replies, posts) wait here (saved on the phone) until the
/// internet returns; at most 50, older than 24 h are dropped (they would no
/// longer help anyone and the server would refuse them).
class TrainOutbox extends ValueNotifier<int> {
  TrainOutbox() : super(0);
  static TrainOutbox I = TrainOutbox();
  static const _key = 'train_outbox_v2';
  static const int max = 50;
  bool _flushing = false;

  Future<List<TrainOutItem>> _read() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw == null) return [];
      final now = DateTime.now();
      return [
        for (final e in (jsonDecode(raw) as List))
          if (e is Map &&
              now.difference(DateTime.tryParse('${(e['body'] as Map?)?['at']}') ?? now).inHours < 24)
            TrainOutItem('${e['kind']}', '${e['no']}', Map<String, dynamic>.from(e['body'] as Map))
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _write(List<TrainOutItem> items) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, jsonEncode([for (final i in items) i.toJson()]));
    } catch (_) {
      // best-effort
    }
    value = items.length;
  }

  Future<void> refreshCount() async => value = (await _read()).length;

  Future<void> add(TrainOutItem item) async {
    final items = await _read()..add(item);
    while (items.length > max) {
      items.removeAt(0);
    }
    await _write(items);
  }

  /// Send what waits. Stops at the first network error (still offline);
  /// a refused item (4xx) is dropped. Returns how many were sent.
  Future<int> flush(ApiClient api) async {
    if (_flushing) return 0;
    _flushing = true;
    var sent = 0;
    try {
      final items = await _read();
      while (items.isNotEmpty) {
        final i = items.first;
        try {
          if (i.kind == 'checkin') {
            await api.trainCheckin(i.no, i.body);
          } else {
            await api.trainText(i.body);
          }
          sent++;
        } on ApiException catch (e) {
          if ((e.status ?? 500) >= 500) break; // server trouble: try later
        } catch (_) {
          break; // still offline
        }
        items.removeAt(0);
      }
      await _write(items);
    } finally {
      _flushing = false;
    }
    return sent;
  }
}
