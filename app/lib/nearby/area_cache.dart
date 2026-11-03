// nearby (owner 3 Nov 18:50): the emergency list works OFFLINE from the last
// downloaded area.
//
// The server (GET /nearby/area) hands the phone a 3 x 3-degree area (about
// 330 km square) of Assisto's own emergency list plus a version token. The
// phone keeps a few areas on disk (size-capped, least recently used goes
// first), sorts by distance itself, and on the next open sends the token:
// "unchanged" costs a few bytes; an owner edit or the monthly refresh bumps
// the token so the area is pulled again. Storage failures never break the
// screen — they just mean "no offline copy".

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

/// One place row of an area (server FIELDS: id, cat, name, name_en, lat,
/// lon, phone, src).
class AreaPlace {
  final int id;
  final String cat;
  final String name; // local name (source / owner)
  final String nameEn;
  final double lat;
  final double lon;
  final String phone;
  final String src;
  const AreaPlace(this.id, this.cat, this.name, this.nameEn, this.lat, this.lon,
      this.phone, this.src);

  static AreaPlace? fromRow(Object? r) {
    if (r is! List || r.length < 7) return null;
    final lat = (r[4] as num?)?.toDouble();
    final lon = (r[5] as num?)?.toDouble();
    final id = (r[0] as num?)?.toInt();
    if (lat == null || lon == null || id == null) return null;
    return AreaPlace(id, '${r[1]}', '${r[2] ?? ''}', '${r[3] ?? ''}', lat, lon,
        '${r[6] ?? ''}', r.length > 7 ? '${r[7]}' : 'osm');
  }

  /// Owner rule: the English name when there is one, else the local name.
  String get displayName => nameEn.isNotEmpty ? nameEn : name;

  /// The local name as a second line when it differs.
  String get secondName => nameEn.isNotEmpty && name != nameEn ? name : '';
}

/// Great-circle distance in metres (pure, no plugin — the phone computes
/// every distance itself).
double distanceM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dp = rad(lat2 - lat1), dl = rad(lon2 - lon1);
  final x = math.pow(math.sin(dp / 2), 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dl / 2), 2);
  return r * 2 * math.asin(math.min(1.0, math.sqrt(x)));
}

/// Places of [cats] sorted nearest first from (lat, lon).
List<(AreaPlace, double)> nearestFirst(
    Iterable<AreaPlace> places, double lat, double lon,
    {Set<String>? cats, int limit = 200}) {
  final out = <(AreaPlace, double)>[
    for (final p in places)
      if (cats == null || cats.contains(p.cat))
        (p, distanceM(lat, lon, p.lat, p.lon)),
  ]..sort((a, b) => a.$2.compareTo(b.$2));
  return out.length > limit ? out.sublist(0, limit) : out;
}

class EmergencyArea {
  final String key;
  final double lat0, lat1, lon0, lon1;
  final String version;
  final String country;
  final String attribution;
  final String? refreshedAt;
  final List<AreaPlace> places;
  const EmergencyArea({
    required this.key,
    required this.lat0,
    required this.lat1,
    required this.lon0,
    required this.lon1,
    required this.version,
    required this.country,
    required this.attribution,
    required this.places,
    this.refreshedAt,
  });

  bool contains(double lat, double lon) =>
      lat >= lat0 && lat < lat1 && lon >= lon0 && lon < lon1;

  /// From GET /nearby/area (a full answer, not "unchanged").
  static EmergencyArea? fromServer(Map<String, dynamic> m) {
    final a = m['area'];
    if (a is! Map) return null;
    double d(Object? v) => (v as num?)?.toDouble() ?? 0;
    return EmergencyArea(
      key: '${a['key'] ?? ''}',
      lat0: d(a['lat0']),
      lat1: d(a['lat1']),
      lon0: d(a['lon0']),
      lon1: d(a['lon1']),
      version: '${m['version'] ?? ''}',
      country: '${m['country'] ?? ''}',
      attribution: '${m['attribution'] ?? ''}',
      refreshedAt: m['refreshed_at'] as String?,
      places: [
        for (final r in (m['rows'] as List? ?? const []))
          if (AreaPlace.fromRow(r) case final p?) p,
      ],
    );
  }

  Map<String, dynamic> toServerShape() => {
        'area': {'key': key, 'lat0': lat0, 'lat1': lat1, 'lon0': lon0, 'lon1': lon1},
        'version': version,
        'country': country,
        'attribution': attribution,
        'refreshed_at': refreshedAt,
        'rows': [
          for (final p in places)
            [p.id, p.cat, p.name, p.nameEn, p.lat, p.lon, p.phone, p.src]
        ],
      };
}

/// Where the areas live. Prod: files under the app support dir.
abstract class AreaStore {
  Future<String?> read(String name);
  Future<void> write(String name, String data);
  Future<void> delete(String name);
}

class FileAreaStore implements AreaStore {
  Directory? _dir;
  static final bool _inFlutterTest = () {
    try {
      return Platform.environment.containsKey('FLUTTER_TEST');
    } catch (_) {
      return false;
    }
  }();
  Future<Directory> _d() async {
    // widget tests run in a fake clock where real disk IO never completes:
    // there the store is simply "no offline copy" (tests inject MemoryAreaStore)
    if (_inFlutterTest) throw StateError('no disk in widget tests');
    final d = _dir ??= Directory(
        '${(await getApplicationSupportDirectory()).path}/nearby_areas');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  String _safe(String n) => n.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');

  @override
  Future<String?> read(String name) async {
    try {
      final f = File('${(await _d()).path}/${_safe(name)}.json');
      return await f.exists() ? await f.readAsString() : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String name, String data) async {
    try {
      await File('${(await _d()).path}/${_safe(name)}.json').writeAsString(data);
    } catch (_) {}
  }

  @override
  Future<void> delete(String name) async {
    try {
      final f = File('${(await _d()).path}/${_safe(name)}.json');
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

@visibleForTesting
class MemoryAreaStore implements AreaStore {
  final Map<String, String> files = {};
  @override
  Future<String?> read(String name) async => files[name];
  @override
  Future<void> write(String name, String data) async => files[name] = data;
  @override
  Future<void> delete(String name) async => files.remove(name);
}

/// Size-capped least-recently-used cache of areas.
class AreaCache {
  final AreaStore store;
  final int maxAreas;
  final int maxBytes;
  final DateTime Function() clock;
  AreaCache(this.store,
      {this.maxAreas = 8, this.maxBytes = 6 * 1024 * 1024, DateTime Function()? clock})
      : clock = clock ?? DateTime.now;

  static AreaCache? _shared;
  static AreaCache get shared => _shared ??= AreaCache(FileAreaStore());
  @visibleForTesting
  static set shared(AreaCache c) => _shared = c;

  static const _index = 'index';

  Future<List<Map<String, dynamic>>> _readIndex() async {
    try {
      final raw = await store.read(_index);
      if (raw == null || raw.isEmpty) return [];
      return [
        for (final e in (jsonDecode(raw) as List))
          if (e is Map) e.cast<String, dynamic>()
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeIndex(List<Map<String, dynamic>> idx) =>
      store.write(_index, jsonEncode(idx));

  bool _has(Map<String, dynamic> e, double lat, double lon) {
    double d(String k) => (e[k] as num?)?.toDouble() ?? 0;
    return lat >= d('lat0') && lat < d('lat1') && lon >= d('lon0') && lon < d('lon1');
  }

  /// The saved area covering (lat, lon); prefers the one centred on the
  /// point's own tile. Null = nothing saved here (or storage unavailable).
  Future<EmergencyArea?> lookup(double lat, double lon) async {
    final idx = await _readIndex();
    final own = '${lat.floor()}:${lon.floor()}';
    final hits = idx.where((e) => _has(e, lat, lon)).toList()
      ..sort((a, b) => (a['key'] == own ? 0 : 1).compareTo(b['key'] == own ? 0 : 1));
    for (final e in hits) {
      try {
        final raw = await store.read('area_${e['key']}');
        if (raw == null) continue;
        final a = EmergencyArea.fromServer(
            (jsonDecode(raw) as Map).cast<String, dynamic>());
        if (a == null) continue;
        e['used'] = clock().millisecondsSinceEpoch;
        await _writeIndex(idx);
        return a;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// Save an area, then evict least-recently-used ones over the caps (the
  /// area just saved is never evicted).
  Future<void> put(EmergencyArea a) async {
    final raw = jsonEncode(a.toServerShape());
    await store.write('area_${a.key}', raw);
    final idx = (await _readIndex())..removeWhere((e) => e['key'] == a.key);
    idx.add({
      'key': a.key,
      'lat0': a.lat0,
      'lat1': a.lat1,
      'lon0': a.lon0,
      'lon1': a.lon1,
      'version': a.version,
      'bytes': raw.length,
      'used': clock().millisecondsSinceEpoch,
    });
    idx.sort((x, y) => ((y['used'] as num?) ?? 0).compareTo((x['used'] as num?) ?? 0));
    int total() => idx.fold<int>(0, (s, e) => s + ((e['bytes'] as num?)?.toInt() ?? 0));
    while (idx.length > 1 && (idx.length > maxAreas || total() > maxBytes)) {
      final gone = idx.removeLast();
      if (gone['key'] == a.key) {
        idx.insert(0, gone);
        break;
      }
      await store.delete('area_${gone['key']}');
    }
    await _writeIndex(idx);
  }

  /// Keys currently saved (most recent first) — for tests / diagnostics.
  Future<List<String>> keys() async =>
      [for (final e in await _readIndex()) '${e['key']}'];
}
