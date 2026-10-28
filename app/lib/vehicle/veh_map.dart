import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api.dart';
import '../theme.dart';
import 'route_canvas.dart';
import 'vehicle_api.dart';

/// e2e-vehicle: tile settings handed out by the server (`/vehicle/config` →
/// `map`). An empty [tileUrl] means "no provider configured" and [VehMap]
/// falls back to the tile-free [RouteCanvas], so the app never depends on a
/// map key to work. The server refuses tile.openstreetmap.org (OSMF policy).
class VehMapConfig {
  final String tileUrl;
  final String attribution;
  final int maxZoom;
  final String userAgentPackage;
  const VehMapConfig({
    this.tileUrl = '',
    this.attribution = '© OpenStreetMap contributors',
    this.maxZoom = 19,
    this.userAgentPackage = 'com.assisto.app',
  });

  bool get hasTiles => tileUrl.isNotEmpty && !tileUrl.contains('tile.openstreetmap.org');

  factory VehMapConfig.fromJson(Map<String, dynamic> m) => VehMapConfig(
        tileUrl: '${m['tile_url'] ?? ''}',
        attribution: _withOsm('${m['attribution'] ?? ''}'),
        maxZoom: (vehInt(m['max_zoom']) ?? 19).clamp(1, 22),
        userAgentPackage: '${m['user_agent_package'] ?? 'com.assisto.app'}',
      );

  static VehMapConfig? _cached;
  static DateTime? _cachedAt;

  /// Cached for 10 minutes; any failure -> canvas fallback (never throws).
  static Future<VehMapConfig> load(ApiClient api) async {
    final now = DateTime.now();
    if (_cached != null && now.difference(_cachedAt!).inMinutes < 10) return _cached!;
    try {
      final c = VehMapConfig.fromJson(vehMap((await api.vehConfig())['map']));
      _cached = c;
      _cachedAt = now;
      return c;
    } catch (_) {
      return const VehMapConfig();
    }
  }

  /// Tests / previews.
  static void debugSet(VehMapConfig? c) {
    _cached = c;
    _cachedAt = c == null ? null : DateTime.now();
  }
}

/// OSM-derived tiles must always credit OpenStreetMap (ODbL).
String _withOsm(String a) {
  final t = a.trim();
  if (t.isEmpty) return '© OpenStreetMap contributors';
  return t.contains('OpenStreetMap') ? t : '$t © OpenStreetMap contributors';
}

LatLng _ll(GeoPt p) => LatLng(p.lat, p.lng);

// ---------------------------------------------------------------- veh100 pure helpers

/// Speed colour band of one fix: 0 = calm (< 75 % of the limit), 1 = near the
/// limit, 2 = over it. [limitKmh] 0 = the general 80 km/h default.
int vehSpeedBand(double speedKmh, int limitKmh) {
  final lim = limitKmh > 0 ? limitKmh.toDouble() : 80.0;
  if (speedKmh > lim) return 2;
  if (speedKmh >= lim * 0.75) return 1;
  return 0;
}

/// The route split into runs of the same speed band (each run shares its
/// first point with the previous run's last, so the line never breaks).
List<({int band, List<GeoPt> points})> vehSpeedRuns(List<GeoPt> route, int limitKmh) {
  final out = <({int band, List<GeoPt> points})>[];
  if (route.length < 2) return out;
  var band = vehSpeedBand(route[1].speed, limitKmh);
  var cur = <GeoPt>[route[0], route[1]];
  for (var i = 2; i < route.length; i++) {
    final b = vehSpeedBand(route[i].speed, limitKmh);
    if (b != band) {
      out.add((band: band, points: cur));
      cur = <GeoPt>[route[i - 1]];
      band = b;
    }
    cur.add(route[i]);
  }
  out.add((band: band, points: cur));
  return out;
}

/// Linear interpolation between two fixes (t in 0..1) — the live marker
/// glides from the previous fix to the new one instead of jumping.
GeoPt vehLerp(GeoPt a, GeoPt b, double t) {
  final k = t.clamp(0.0, 1.0);
  // shortest way round for the heading (350 deg -> 10 deg turns 20, not 340)
  var dc = (b.course - a.course) % 360;
  if (dc > 180) dc -= 360;
  if (dc < -180) dc += 360;
  return GeoPt(a.lat + (b.lat - a.lat) * k, a.lng + (b.lng - a.lng) * k,
      speed: a.speed + (b.speed - a.speed) * k, course: (a.course + dc * k) % 360,
      at: b.at);
}

/// Bearing a -> b in degrees (0 = north), for the playback arrow.
double vehBearing(GeoPt a, GeoPt b) {
  final p1 = a.lat * math.pi / 180, p2 = b.lat * math.pi / 180;
  final dl = (b.lng - a.lng) * math.pi / 180;
  final y = math.sin(dl) * math.cos(p2);
  final x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

/// A real street map (flutter_map) with the speed-coloured route, planned
/// route, circle + polygon geofences, a smoothly gliding live marker that
/// points where the vehicle is heading, and the playback arrow — or the
/// tile-free canvas when the server has no tile provider configured.
class VehMap extends StatefulWidget {
  final VehMapConfig config;
  final List<GeoPt> route;
  final List<GeoPt> plannedRoute;
  final GeoPt? live;
  final int? playIndex;
  final List<GeoFenceView> fences;
  final String semanticsLabel;
  final String? emptyLabel;

  /// Keep the camera on [live] (Car Mode).
  final bool follow;

  /// veh100: colour the route by speed against this limit (0 = 80 km/h).
  final bool speedColours;
  final int speedLimitKmh;

  /// veh100: tap on the map (fence drawing). Null = not interactive for taps.
  final void Function(GeoPt p)? onTap;

  /// Test seam: tiles without network.
  final TileProvider? tileProvider;

  const VehMap({
    super.key,
    required this.config,
    required this.route,
    this.plannedRoute = const [],
    this.live,
    this.playIndex,
    this.fences = const [],
    required this.semanticsLabel,
    this.emptyLabel,
    this.follow = false,
    this.speedColours = false,
    this.speedLimitKmh = 0,
    this.onTap,
    this.tileProvider,
  });

  /// Test seam for screens that build VehMap themselves (no network tiles).
  static TileProvider? debugTileProvider;

  /// How long the live marker glides between two fixes.
  static const glide = Duration(milliseconds: 1400);

  @override
  State<VehMap> createState() => _VehMapState();
}

class _VehMapState extends State<VehMap> with SingleTickerProviderStateMixin {
  final _ctl = MapController();
  bool _ready = false;
  late final AnimationController _anim =
      AnimationController(vsync: this, duration: VehMap.glide);
  GeoPt? _from;

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  GeoPt? get _shown {
    final to = widget.live;
    if (to == null) return null;
    final from = _from;
    if (from == null || !_anim.isAnimating) return to;
    return vehLerp(from, to, Curves.easeInOut.transform(_anim.value));
  }

  @override
  void didUpdateWidget(covariant VehMap old) {
    super.didUpdateWidget(old);
    final l = widget.live;
    final o = old.live;
    final moved = l != null && o != null && (o.lat != l.lat || o.lng != l.lng);
    if (moved) {
      final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
      // a jump of more than ~2 km (reconnect after a long gap) is not animated
      final far = (o.lat - l.lat).abs() + (o.lng - l.lng).abs() > 0.02;
      if (!reduce && !far) {
        _from = _anim.isAnimating ? (_shown ?? o) : o;
        _anim.forward(from: 0);
      } else {
        _from = null;
      }
    }
    if (widget.follow && _ready && l != null && (o == null || moved)) {
      try {
        _ctl.move(_ll(l), _ctl.camera.zoom);
      } catch (_) {} // camera not laid out yet — next fix recentres
    }
  }

  Color _bandColor(int band, ColorScheme scheme) => switch (band) {
        2 => scheme.error,
        1 => Brand.warning,
        _ => Brand.blue,
      };

  @override
  Widget build(BuildContext context) {
    final w = widget;
    if (!w.config.hasTiles) {
      return RouteCanvas(
        route: w.route,
        live: w.live,
        playIndex: w.playIndex,
        fences: w.fences,
        semanticsLabel: w.semanticsLabel,
        scaleLabel: (w.route.isEmpty && w.live == null) ? w.emptyLabel : null,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final pts = w.route.map(_ll).toList();
    final planned = w.plannedRoute.map(_ll).toList();
    final all = <LatLng>[...pts, ...planned, if (w.live != null) _ll(w.live!)];
    final pi = (w.playIndex != null && w.route.isNotEmpty)
        ? w.playIndex!.clamp(0, w.route.length - 1)
        : null;
    final playAt = pi == null ? null : w.route[pi];
    final playHeading = (pi == null || w.route.length < 2)
        ? 0.0
        : (pi > 0
            ? vehBearing(w.route[pi - 1], w.route[pi])
            : vehBearing(w.route[0], w.route[1]));
    final center = w.live != null
        ? _ll(w.live!)
        : (all.isNotEmpty ? all.last : const LatLng(23.8103, 90.4125)); // Dhaka
    final fit = (!w.follow && all.length >= 2)
        ? CameraFit.coordinates(coordinates: all, padding: const EdgeInsets.all(32),
            maxZoom: 17)
        : null;
    final circles = w.fences.where((f) => !f.isPolygon).toList();
    final polys = w.fences.where((f) => f.isPolygon).toList();
    final runs = w.speedColours
        ? vehSpeedRuns(w.route, w.speedLimitKmh)
        : <({int band, List<GeoPt> points})>[];
    final map = FlutterMap(
      mapController: _ctl,
      options: MapOptions(
        initialCenter: center,
        initialZoom: 15,
        initialCameraFit: fit,
        maxZoom: w.config.maxZoom.toDouble(),
        minZoom: 3,
        backgroundColor: scheme.surfaceContainerHighest,
        onMapReady: () => _ready = true,
        onTap: w.onTap == null
            ? null
            : (_, ll) => w.onTap!(GeoPt(ll.latitude, ll.longitude)),
        interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
      ),
      children: [
        TileLayer(
          key: const ValueKey('veh-tiles'),
          urlTemplate: w.config.tileUrl,
          maxZoom: w.config.maxZoom.toDouble(),
          userAgentPackageName: w.config.userAgentPackage,
          tileProvider: w.tileProvider ?? VehMap.debugTileProvider,
        ),
        if (circles.isNotEmpty)
          CircleLayer(circles: [
            for (final f in circles)
              CircleMarker(
                point: LatLng(f.lat, f.lng),
                radius: f.radiusM,
                useRadiusInMeter: true,
                color: Brand.cyan.withValues(alpha: 0.12),
                borderColor: Brand.cyan,
                borderStrokeWidth: 2,
              ),
          ]),
        if (polys.isNotEmpty)
          PolygonLayer(
            key: const ValueKey('veh-fence-polygons'),
            polygons: [
              for (final f in polys)
                Polygon(
                  points: f.points.map(_ll).toList(),
                  color: Brand.cyan.withValues(alpha: 0.12),
                  borderColor: Brand.cyan,
                  borderStrokeWidth: 2,
                ),
            ],
          ),
        if (planned.length >= 2)
          PolylineLayer(polylines: [
            Polyline(
              points: planned,
              color: Brand.purple.withValues(alpha: 0.8),
              strokeWidth: 5,
              pattern: StrokePattern.dashed(segments: const [10, 8]),
            ),
          ]),
        if (pts.length >= 2)
          PolylineLayer(
            key: const ValueKey('veh-route'),
            polylines: runs.isEmpty
                ? [Polyline(points: pts, color: Brand.blue, strokeWidth: 4)]
                : [
                    for (final r in runs)
                      Polyline(
                          points: r.points.map(_ll).toList(),
                          color: _bandColor(r.band, scheme),
                          strokeWidth: 5),
                  ],
          ),
        MarkerLayer(markers: [
          if (pts.isNotEmpty)
            Marker(
              point: pts.first,
              width: 18,
              height: 18,
              child: const _Dot(color: Brand.success),
            ),
          if (playAt != null)
            Marker(
              key: const ValueKey('veh-play-marker'),
              point: _ll(playAt),
              width: 34,
              height: 34,
              child: _Arrow(heading: playHeading, color: Brand.warning),
            ),
        ]),
        if (w.live != null)
          AnimatedBuilder(
            animation: _anim,
            builder: (context, _) {
              final p = _shown ?? w.live!;
              return MarkerLayer(markers: [
                Marker(
                  key: const ValueKey('veh-live-marker'),
                  point: _ll(p),
                  width: 44,
                  height: 44,
                  child: _LiveCar(heading: p.course, color: scheme.error),
                ),
              ]);
            },
          ),
        // OSM / provider credit, always visible; wraps instead of
        // overflowing at large text sizes.
        Align(
          key: const ValueKey('veh-map-attribution'),
          alignment: AlignmentDirectional.bottomEnd,
          child: Container(
            margin: const EdgeInsets.all(4),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(w.config.attribution,
                textAlign: TextAlign.end,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.black87, height: 1.2)),
          ),
        ),
      ],
    );
    return Semantics(
      label: w.semanticsLabel,
      image: true,
      child: ExcludeSemantics(
        child: ClipRRect(borderRadius: BorderRadius.circular(Radii.md), child: map),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  final Color color;
  const _Dot({required this.color});

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
        ),
      );
}

/// The live vehicle: the car icon with a small arrow badge turned to where
/// it is heading.
class _LiveCar extends StatelessWidget {
  final double heading;
  final Color color;
  const _LiveCar({required this.heading, required this.color});

  @override
  Widget build(BuildContext context) => Stack(clipBehavior: Clip.none, children: [
        Center(child: Icon(Icons.directions_car_filled_rounded, size: 34, color: color)),
        PositionedDirectional(
          top: -2,
          end: -2,
          child: SizedBox(
              width: 18, height: 18, child: _Arrow(heading: heading, color: Brand.blue)),
        ),
      ]);
}

/// A round marker with an arrow pointing along [heading] (deg, 0 = north).
class _Arrow extends StatelessWidget {
  final double heading;
  final Color color;
  final bool big;
  const _Arrow({required this.heading, required this.color, this.big = false});

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black38)],
        ),
        child: Transform.rotate(
          angle: heading * math.pi / 180,
          child: FittedBox(
            child: Icon(Icons.navigation_rounded,
                color: Colors.white, size: big ? 24 : 18),
          ),
        ),
      );
}
