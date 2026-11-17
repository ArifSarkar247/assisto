// mapapp: the Assisto map's style + Dhaka offline pack
// (contract: owner_actions/CITY_MAP_TILES_API.md, maptiles lane).
//
// Style: {base}style/assisto-{light|night}-{bn|en}.json — fetched over HTTP,
// cached on the phone (the last good copy opens the map offline), and for
// offline Dhaka only the `assisto_base` / `assisto_buildings` source URLs are
// rewritten to the downloaded PMTiles files (pmtiles://file://…).
// Tiles base: server setting GET /city/map (owner can move to a CDN without
// a build), else the contract default; an on-phone override key exists for
// owner tests (Settings `city_map_tiles_base`).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../api.dart';
import '../../state.dart' show Settings;
import 'city_map_data.dart';

const String kMapTilesBaseDefault = 'https://api.lifeassisto.com/maps/v1/';
const String kMapTilesBaseKey = 'city_map_tiles_base';
const String kMapCredits = '© OpenStreetMap contributors · Overture Maps · Copernicus';

/// Dhaka box from the contract (west, south, east, north) — used until the
/// manifest says otherwise.
const List<double> kDhakaBbox = [90.30, 23.68, 90.53, 23.92];

String mapStyleUrl(String base, {required bool night, required bool bn}) =>
    '${base}style/assisto-${night ? 'night' : 'light'}-${bn ? 'bn' : 'en'}.json';

/// Rewrite the two big vector sources to the offline PMTiles files (pure).
/// gap-city (contract §5): with [assetsDir] the glyphs + sprite also come
/// from the pack, so an offline map still draws names (Bangla PGF too) and
/// icons — not only shapes.
Map<String, dynamic> styleWithOffline(Map<String, dynamic> style,
    {required String baseFile, required String buildingsFile, String assetsDir = ''}) {
  final out = jsonDecode(jsonEncode(style)) as Map<String, dynamic>;
  final src = (out['sources'] as Map?)?.cast<String, dynamic>();
  if (src == null) return out;
  void set(String id, String file) {
    final s = (src[id] as Map?)?.cast<String, dynamic>();
    if (s == null || file.isEmpty) return;
    s['url'] = 'pmtiles://file://$file';
    s.remove('tiles');
    src[id] = s;
  }

  set('assisto_base', baseFile);
  set('assisto_buildings', buildingsFile);
  if (assetsDir.isNotEmpty) {
    if (out['glyphs'] is String) out['glyphs'] = 'file://$assetsDir/fonts/{fontstack}/{range}.pbf';
    final sp = out['sprite'];
    if (sp is String && sp.contains('sprites/')) {
      out['sprite'] = 'file://$assetsDir/${sp.substring(sp.indexOf('sprites/'))}';
    }
  }
  return out;
}

/// gap-city: the pack's extra files (manifest "fonts" + "sprites"), only
/// safe relative paths under fonts/ or sprites/.
List<String> packAssets(Map<String, dynamic> m) => [
      for (final k in const ['fonts', 'sprites'])
        if (m[k] is List)
          for (final x in m[k] as List)
            if ('$x'.isNotEmpty &&
                !'$x'.contains('..') &&
                RegExp(r'^(fonts|sprites)/[A-Za-z0-9 ._@/-]+$').hasMatch('$x'))
              '$x'
    ];

bool insideBbox(List<double> b, double lat, double lon) => lon >= b[0] && lat >= b[1] && lon <= b[2] && lat <= b[3];

/// Style + offline-pack loader. Network + disk are injectable for tests.
class CityMapStyle {
  CityMapStyle({http.Client? client, Future<Directory> Function()? dir})
      : _client = client,
        _dir = dir ?? getApplicationSupportDirectory;
  static CityMapStyle I = CityMapStyle();

  final http.Client? _client;
  final Future<Directory> Function() _dir;
  String? _base;

  http.Client? _own;
  http.Client get _http => _client ?? (_own ??= http.Client());

  /// Test: skip the network/disk entirely.
  @visibleForTesting
  static String? debugStyleJson;

  Future<String> base(ApiClient api) async {
    if (_base != null) return _base!;
    try {
      final o = (await Settings.getString(kMapTilesBaseKey)) ?? '';
      if (o.startsWith('https://')) return _base = o.endsWith('/') ? o : '$o/';
    } catch (_) {}
    try {
      final b = '${(await api.cityMapConfig().timeout(const Duration(seconds: 6)))['tiles_base'] ?? ''}';
      if (b.startsWith('https://')) return _base = b.endsWith('/') ? b : '$b/';
    } catch (_) {} // offline / old server: the contract default
    return kMapTilesBaseDefault;
  }

  Future<Directory> _root() async {
    final d = Directory('${(await _dir()).path}/citymap');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// The style JSON string for MapLibre, or null (no network and no cached
  /// copy -> the screen shows the list view). Never throws.
  Future<String?> load(ApiClient api, {required bool night, required bool bn, double? lat, double? lon}) async {
    if (debugStyleJson != null) return debugStyleJson;
    final name = 'style_${night ? 'night' : 'light'}_${bn ? 'bn' : 'en'}.json';
    Map<String, dynamic>? style;
    try {
      final url = mapStyleUrl(await base(api), night: night, bn: bn);
      final r = await _http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) {
        final m = jsonDecode(utf8.decode(r.bodyBytes));
        if (m is Map && m['version'] == 8 && m['sources'] is Map && m['layers'] is List) {
          style = m.cast<String, dynamic>();
          try {
            await File('${(await _root()).path}/$name').writeAsString(jsonEncode(style));
          } catch (_) {} // cache is best-effort
        }
      }
    } catch (_) {} // offline: the cached copy below
    if (style == null) {
      try {
        final f = File('${(await _root()).path}/$name');
        if (await f.exists()) style = (jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>();
      } catch (_) {}
    }
    if (style == null) return null;
    final pack = await offlineFiles();
    if (pack != null && (lat == null || lon == null || insideBbox(pack.bbox, lat, lon))) {
      style = styleWithOffline(style, baseFile: pack.base, buildingsFile: pack.buildings, assetsDir: pack.assets);
    }
    return jsonEncode(style);
  }

  // ---------------------------------------------------------------- offline
  static const _verKey = 'city_map_offline_v';

  /// The downloaded Dhaka pack, or null.
  Future<({String base, String buildings, List<double> bbox, String assets})?> offlineFiles() async {
    try {
      final v = (await Settings.getString(_verKey)) ?? '';
      if (v.isEmpty) return null;
      final d = Directory('${(await _root()).path}/offline_$v');
      final b = File('${d.path}/dhaka_base.pmtiles'), g = File('${d.path}/dhaka_buildings.pmtiles');
      if (!await b.exists()) return null;
      List<double> bbox = kDhakaBbox;
      var assets = '';
      try {
        final m = jsonDecode(await File('${d.path}/manifest.json').readAsString()) as Map;
        if (m['assets_ok'] == true) assets = '${d.path}/assets';
        final l = (m['bbox'] as List).map((x) => (x as num).toDouble()).toList();
        if (l.length == 4) bbox = l;
      } catch (_) {}
      return (base: b.path, buildings: await g.exists() ? g.path : '', bbox: bbox, assets: assets);
    } catch (_) {
      return null;
    }
  }

  /// The pack's manifest ({version, bbox, files:[{name, bytes, sha256}]}).
  Future<Map<String, dynamic>?> offlineManifest(ApiClient api) async {
    try {
      final r = await _http.get(Uri.parse('${await base(api)}offline/manifest.json')).timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return null;
      final m = jsonDecode(utf8.decode(r.bodyBytes));
      if (m is! Map || m['files'] is! List || '${m['version'] ?? ''}'.isEmpty) return null;
      return m.cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  static int packBytes(Map<String, dynamic> m) =>
      (m['files'] as List).fold<int>(0, (a, f) => a + (((f as Map)['bytes'] as num?)?.toInt() ?? 0));

  /// Download every file (resumes with HTTP Range), verify sha256, then mark
  /// the pack ready. [progress] gets 0..1. Returns true when ready.
  Future<bool> downloadPack(ApiClient api, Map<String, dynamic> m, {void Function(double)? progress}) async {
    final v = '${m['version']}'.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '');
    final total = packBytes(m);
    var done = 0;
    try {
      final b = await base(api);
      final d = Directory('${(await _root()).path}/offline_$v');
      await d.create(recursive: true);
      for (final f in (m['files'] as List).cast<Map>()) {
        final name = '${f['name']}'.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '');
        final want = '${f['sha256'] ?? ''}'.toLowerCase();
        final out = File('${d.path}/$name');
        if (await out.exists() && want.isNotEmpty && await _sha(out) == want) {
          done += await out.length();
          continue;
        }
        final part = File('${out.path}.part');
        final have = await part.exists() ? await part.length() : 0;
        final req = http.Request('GET', Uri.parse('${b}offline/$name'));
        if (have > 0) req.headers['Range'] = 'bytes=$have-';
        final res = await _http.send(req).timeout(const Duration(seconds: 30));
        if (res.statusCode != 200 && res.statusCode != 206) return false;
        final sink = part.openWrite(mode: res.statusCode == 206 ? FileMode.append : FileMode.write);
        var got = res.statusCode == 206 ? have : 0;
        try {
          await for (final chunk in res.stream) {
            sink.add(chunk);
            got += chunk.length;
            if (total > 0) progress?.call(((done + got) / total).clamp(0.0, 1.0));
          }
        } finally {
          await sink.close();
        }
        if (want.isNotEmpty && await _sha(part) != want) {
          await part.delete();
          return false; // a broken file never becomes the map
        }
        await part.rename(out.path);
        done += got;
      }
      final assetsOk = await _downloadAssets(b, d, packAssets(m));
      await File('${d.path}/manifest.json').writeAsString(jsonEncode({...m, 'assets_ok': assetsOk}));
      await Settings.setString(_verKey, v);
      progress?.call(1);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// gap-city: font ranges + sprites (small files, 6 at a time). Returns
  /// true only when every one is on the phone (then the style points at
  /// them); a miss keeps the online glyphs — the tiles still work offline.
  Future<bool> _downloadAssets(String base, Directory d, List<String> paths) async {
    if (paths.isEmpty) return false;
    var ok = true;
    Future<void> one(String rel) async {
      final out = File('${d.path}/assets/$rel');
      if (await out.exists() && await out.length() > 0) return;
      try {
        final r = await _http.get(Uri.parse('$base${Uri.encodeFull(rel)}')).timeout(const Duration(seconds: 20));
        if (r.statusCode != 200) {
          ok = false;
          return;
        }
        await out.parent.create(recursive: true);
        await out.writeAsBytes(r.bodyBytes, flush: true);
      } catch (_) {
        ok = false;
      }
    }

    for (var i = 0; i < paths.length; i += 6) {
      await Future.wait([for (final p in paths.skip(i).take(6)) one(p)]);
    }
    // MapLibre may ask for the font stack name percent-encoded
    // ("Noto%20Sans%20Regular"): a link with that name finds the same files
    try {
      final fonts = Directory('${d.path}/assets/fonts');
      if (await fonts.exists()) {
        for (final e in await fonts.list().toList()) {
          final name = e.path.split('/').last;
          if (e is! Directory || !name.contains(' ')) continue;
          final enc = Link('${fonts.path}/${Uri.encodeComponent(name)}');
          if (!await enc.exists()) await enc.create(e.path);
        }
      }
    } catch (_) {} // best-effort: the plain name is the usual one
    return ok;
  }

  /// gap-city: a pack saved by an older build has tiles but no fonts /
  /// sprites -> fetch them once (online, best-effort). True when done.
  Future<bool> ensureAssets(ApiClient api) async {
    try {
      final v = (await Settings.getString(_verKey)) ?? '';
      if (v.isEmpty) return false;
      final d = Directory('${(await _root()).path}/offline_$v');
      final f = File('${d.path}/manifest.json');
      final m = (jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>();
      if (m['assets_ok'] == true) return true;
      var assets = packAssets(m);
      if (assets.isEmpty) {
        final online = await offlineManifest(api);
        if (online == null) return false;
        assets = packAssets(online);
      }
      final ok = await _downloadAssets(await base(api), d, assets);
      if (ok) await f.writeAsString(jsonEncode({...m, 'assets_ok': true}));
      return ok;
    } catch (_) {
      return false;
    }
  }

  Future<void> deletePack() async {
    try {
      final v = (await Settings.getString(_verKey)) ?? '';
      await Settings.setString(_verKey, '');
      if (v.isNotEmpty) await Directory('${(await _root()).path}/offline_$v').delete(recursive: true);
    } catch (_) {}
  }

  static Future<String> _sha(File f) async => (await sha256.bind(f.openRead()).first).toString();
}

/// Crash guard for the native map (ColorOS / 2 GB phones): a marker is set
/// while the GL map opens and cleared once its style has loaded. If the app
/// died while opening, the next open shows the list view instead and stays
/// on it for this install (a native crash cannot be caught in Dart).
class CityMapGuard {
  static const _opening = 'city_map_gl_opening', _off = 'city_map_gl_off';
  static Future<bool> glAllowed() async {
    try {
      if (await Settings.getBool(_off, false)) return false;
      if (await Settings.getBool(_opening, false)) {
        await Settings.setBool(_off, true);
        return false;
      }
    } catch (_) {}
    return true;
  }

  static Future<void> opening() async {
    try {
      await Settings.setBool(_opening, true);
    } catch (_) {}
  }

  static Future<void> opened() async {
    try {
      await Settings.setBool(_opening, false);
    } catch (_) {}
  }

  /// Settings "try the map again" (and tests).
  static Future<void> reset() async {
    try {
      await Settings.setBool(_off, false);
      await Settings.setBool(_opening, false);
    } catch (_) {}
  }
}
