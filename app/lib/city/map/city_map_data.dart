// mapapp (owner order 10 Nov 00:35, PART A): the City map's data side.
//
// * Our layers (metro, bus routes, fares, waterlogging, women bus) are built
//   ONLY from our own City Service data (offline package + /city/reports +
//   /city/women) as GeoJSON overlays. They are never mixed into the base-map
//   tiles (CITY_MAP_TILES_API.md §2).
// * Map text: MapLibre cannot shape Bengali, so every label WE draw is a
//   Flutter widget over the map (MapLabel), never a symbol-layer text.
// * Google transit (Google view only): parsed from /maps/transit, kept in
//   memory for the screen's life, never stored.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../api.dart';
import '../../theme.dart';
import '../city_models.dart';

extension CityMapApi on ApiClient {
  /// Tiles base + credits (server setting; owner can move the tiles to a CDN).
  Future<Map<String, dynamic>> cityMapConfig() => getJson('/city/map');

  /// Live Google transit for the Google view (state ok | none | bad).
  Future<Map<String, dynamic>> mapsTransit(double oLat, double oLon, double dLat, double dLon) =>
      getJson('/maps/transit?olat=${oLat.toStringAsFixed(6)}&olng=${oLon.toStringAsFixed(6)}'
          '&dlat=${dLat.toStringAsFixed(6)}&dlng=${dLon.toStringAsFixed(6)}');

  /// The one-tap "Which bus? What fare?" answer (no name, no free text).
  Future<Map<String, dynamic>> cityTripConfirm(
          {required String boardId,
          required String alightId,
          String routeId = '',
          int? paid,
          String mode = 'bus',
          String city = 'dhaka'}) =>
      postJson('/city/trips/confirm', {
        'city': city,
        'mode': mode,
        'route_id': routeId,
        'board_id': boardId,
        'alight_id': alightId,
        if (paid != null) 'paid': paid,
      });

  /// "You verified N stops".
  Future<Map<String, dynamic>> cityTripMine() => getJson('/city/trips/mine');
}

enum CityLayer { metro, bus, fares, waterlogging, women }

/// A label drawn as a Flutter widget over the map (proper Bangla shaping).
class MapLabel {
  final double lat, lon;
  final String text;
  final CityLayer kind;
  final Color color;
  const MapLabel(this.lat, this.lon, this.text, this.kind, this.color);
}

/// Our overlay for one moment: lines + points (GeoJSON) + Flutter labels.
class CityLayerSet {
  final Map<String, dynamic> lines, points;
  final List<MapLabel> labels;

  /// Plain list rows (the list view when the GL map cannot run).
  final List<({CityLayer kind, String title, String sub})> rows;
  const CityLayerSet(this.lines, this.points, this.labels, this.rows);
  static const empty = CityLayerSet(_emptyFc, _emptyFc, [], []);
  bool get isEmpty => (lines['features'] as List).isEmpty && (points['features'] as List).isEmpty;
}

const Map<String, dynamic> _emptyFc = {'type': 'FeatureCollection', 'features': <Map<String, dynamic>>[]};

Map<String, dynamic> _fc(List<Map<String, dynamic>> f) => {'type': 'FeatureCollection', 'features': f};

/// "#RRGGBB" for a style expression (colours stay in theme.dart).
String hexOf(Color c) {
  int ch(double v) => (v * 255).round().clamp(0, 255);
  return '#${[ch(c.r), ch(c.g), ch(c.b)].map((x) => x.toRadixString(16).padLeft(2, '0')).join()}';
}

Color layerColor(CityLayer k) => switch (k) {
      CityLayer.metro => Brand.success,
      CityLayer.bus => Brand.blue,
      CityLayer.fares => Brand.warning,
      CityLayer.waterlogging => Brand.info,
      CityLayer.women => Brand.danger,
    };

/// Fare band colour for the Fares layer (full-route fare).
Color fareBand(int high) => high <= 20 ? Brand.success : (high <= 40 ? Brand.warning : Brand.danger);

double _km(double a, double b, double c, double d) {
  const r = 6371.0;
  double rad(double x) => x * math.pi / 180;
  final dp = rad(c - a), dl = rad(d - b);
  final x = math.pow(math.sin(dp / 2), 2) + math.cos(rad(a)) * math.cos(rad(c)) * math.pow(math.sin(dl / 2), 2);
  return 2 * r * math.asin(math.sqrt(x));
}

bool _near(List coords, double lat, double lon, double km) {
  for (final c in coords) {
    final p = c as List;
    if (_km(lat, lon, (p[1] as num).toDouble(), (p[0] as num).toDouble()) <= km) return true;
  }
  return false;
}

/// Build the overlay. [shapes] = OfflineRouter.routeShapes(); [water] =
/// live waterlogging reports; [womenIds] = women-only route ids. Routes are
/// limited to those passing within [radiusKm] of the map centre (cheap
/// phones), max [maxRoutes]. [taka] formats a fare range in the app language.
CityLayerSet buildCityLayers({
  required Set<CityLayer> on,
  required List<Map<String, dynamic>> shapes,
  required List<CityReport> water,
  required Set<String> womenIds,
  required bool bn,
  required double lat,
  required double lon,
  required String Function(int lo, int hi) taka,
  required String Function(int count) waterText,
  double radiusKm = 6,
  int maxRoutes = 40,
}) {
  final lines = <Map<String, dynamic>>[];
  final points = <Map<String, dynamic>>[];
  final labels = <MapLabel>[];
  final rows = <({CityLayer kind, String title, String sub})>[];
  String name(Map<String, dynamic> r) =>
      bn && '${r['name_bn'] ?? ''}'.isNotEmpty ? '${r['name_bn']}' : '${r['name'] ?? ''}';
  String stopName(Map s) => bn && '${s['name_bn'] ?? ''}'.isNotEmpty ? '${s['name_bn']}' : '${s['name'] ?? ''}';

  void line(CityLayer k, Map<String, dynamic> r, Color c, double width) => lines.add({
        'type': 'Feature',
        'properties': {'layer': k.name, 'id': r['id'], 'color': hexOf(c), 'width': width},
        'geometry': {'type': 'LineString', 'coordinates': r['coords']},
      });
  void point(CityLayer k, double la, double lo, Color c, double radius) => points.add({
        'type': 'Feature',
        'properties': {'layer': k.name, 'color': hexOf(c), 'radius': radius},
        'geometry': {
          'type': 'Point',
          'coordinates': [lo, la]
        },
      });
  ({double lat, double lon}) mid(List coords) {
    final p = coords[coords.length ~/ 2] as List;
    return (lat: (p[1] as num).toDouble(), lon: (p[0] as num).toDouble());
  }

  // one direction per route name (a/b directions draw the same street)
  final seen = <String>{};
  final uniq = <Map<String, dynamic>>[];
  for (final r in shapes) {
    final key = '${r['mode']}|${r['name']}';
    if (seen.add(key)) uniq.add(r);
  }

  if (on.contains(CityLayer.metro)) {
    for (final r in uniq.where((r) => r['mode'] == 'metro')) {
      line(CityLayer.metro, r, layerColor(CityLayer.metro), 6);
      rows.add((kind: CityLayer.metro, title: name(r), sub: '${(r['stops'] as List).length}'));
      for (final s in (r['stops'] as List).cast<Map>()) {
        final la = (s['lat'] as num).toDouble(), lo = (s['lon'] as num).toDouble();
        point(CityLayer.metro, la, lo, layerColor(CityLayer.metro), 6);
        labels.add(MapLabel(la, lo, stopName(s), CityLayer.metro, layerColor(CityLayer.metro)));
      }
    }
  }
  final nearBus = uniq
      .where((r) => r['mode'] != 'metro' && _near(r['coords'] as List, lat, lon, radiusKm))
      .take(maxRoutes)
      .toList();
  if (on.contains(CityLayer.bus)) {
    for (final r in nearBus) {
      line(CityLayer.bus, r, layerColor(CityLayer.bus), 3);
      final m = mid(r['coords'] as List);
      labels.add(MapLabel(m.lat, m.lon, name(r), CityLayer.bus, layerColor(CityLayer.bus)));
      final st = (r['stops'] as List).cast<Map>();
      rows.add((kind: CityLayer.bus, title: name(r), sub: st.isEmpty ? '' : '${stopName(st.first)} – ${stopName(st.last)}'));
    }
  }
  if (on.contains(CityLayer.fares)) {
    for (final r in nearBus) {
      final f = (r['fare'] as Map?) ?? const {};
      final lo = (f['low'] as num?)?.toInt() ?? 0, hi = (f['high'] as num?)?.toInt() ?? 0;
      if (hi <= 0) continue;
      final c = fareBand(hi);
      line(CityLayer.fares, r, c, 4);
      final m = mid(r['coords'] as List);
      labels.add(MapLabel(m.lat, m.lon, taka(lo, hi), CityLayer.fares, c));
      rows.add((kind: CityLayer.fares, title: name(r), sub: taka(lo, hi)));
    }
  }
  if (on.contains(CityLayer.waterlogging)) {
    for (final w in water.where((w) => w.kind == 'waterlogging' && w.lat != null && w.lon != null)) {
      point(CityLayer.waterlogging, w.lat!, w.lon!, layerColor(CityLayer.waterlogging), 14);
      labels.add(MapLabel(w.lat!, w.lon!, waterText(w.count), CityLayer.waterlogging, layerColor(CityLayer.waterlogging)));
      rows.add((kind: CityLayer.waterlogging, title: waterText(w.count), sub: ''));
    }
  }
  if (on.contains(CityLayer.women) && womenIds.isNotEmpty) {
    for (final r in uniq.where((r) => womenIds.contains(r['id']))) {
      line(CityLayer.women, r, layerColor(CityLayer.women), 5);
      final m = mid(r['coords'] as List);
      labels.add(MapLabel(m.lat, m.lon, name(r), CityLayer.women, layerColor(CityLayer.women)));
      rows.add((kind: CityLayer.women, title: name(r), sub: ''));
    }
  }
  return CityLayerSet(_fc(lines), _fc(points), labels, rows);
}

// ------------------------------------------------------------------ Google
class GTransitStep {
  final String mode, line, lineName, agency, headsign, from, to;
  final int minutes, meters, stops;
  const GTransitStep(
      {required this.mode,
      this.line = '',
      this.lineName = '',
      this.agency = '',
      this.headsign = '',
      this.from = '',
      this.to = '',
      this.minutes = 0,
      this.meters = 0,
      this.stops = 0});
  factory GTransitStep.from(Map m) => GTransitStep(
        mode: '${m['mode'] ?? 'walk'}',
        line: '${m['line'] ?? ''}',
        lineName: '${m['line_name'] ?? ''}',
        agency: '${m['agency'] ?? ''}',
        headsign: '${m['headsign'] ?? ''}',
        from: '${m['from'] ?? ''}',
        to: '${m['to'] ?? ''}',
        minutes: (m['minutes'] as num?)?.toInt() ?? 0,
        meters: (m['meters'] as num?)?.toInt() ?? 0,
        stops: (m['stops'] as num?)?.toInt() ?? 0,
      );
}

class GTransitRoute {
  final int minutes, distanceM;
  final int? fareBdt;
  final String polyline;
  final List<GTransitStep> steps;
  const GTransitRoute(this.minutes, this.distanceM, this.fareBdt, this.polyline, this.steps);
  factory GTransitRoute.from(Map m) => GTransitRoute(
        (m['minutes'] as num?)?.toInt() ?? 0,
        (m['distance_m'] as num?)?.toInt() ?? 0,
        (m['fare_bdt'] as num?)?.toInt(),
        '${m['polyline'] ?? ''}',
        [for (final s in (m['steps'] as List? ?? const [])) if (s is Map) GTransitStep.from(s)],
      );

  /// state ok -> routes; anything else (none / bad / off) -> [] (the app
  /// then shows only our own results — never a limit message).
  static List<GTransitRoute> listFrom(Map<String, dynamic> r) => r['state'] == 'ok'
      ? [for (final x in (r['routes'] as List? ?? const [])) if (x is Map) GTransitRoute.from(x)]
      : const [];
}

/// Google encoded polyline -> [(lat, lon)].
List<(double, double)> decodePolyline(String s) {
  final out = <(double, double)>[];
  var i = 0, lat = 0, lon = 0;
  int next() {
    var shift = 0, result = 0, b = 0;
    do {
      if (i >= s.length) return 0;
      b = s.codeUnitAt(i++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    return (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
  }

  while (i < s.length) {
    lat += next();
    if (i >= s.length) break;
    lon += next();
    out.add((lat / 1e5, lon / 1e5));
  }
  return out;
}
