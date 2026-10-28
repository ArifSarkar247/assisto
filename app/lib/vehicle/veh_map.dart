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

/// A real street map (flutter_map) with the route, planned route, geofences,
/// live position and playback marker — or the tile-free canvas when the
/// server has no tile provider configured.
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
    this.tileProvider,
  });

  /// Test seam for screens that build VehMap themselves (no network tiles).
  static TileProvider? debugTileProvider;

  @override
  State<VehMap> createState() => _VehMapState();
}

class _VehMapState extends State<VehMap> {
  final _ctl = MapController();
  bool _ready = false;

  @override
  void didUpdateWidget(covariant VehMap old) {
    super.didUpdateWidget(old);
    final l = widget.live;
    if (widget.follow && _ready && l != null &&
        (old.live == null || old.live!.lat != l.lat || old.live!.lng != l.lng)) {
      try {
        _ctl.move(_ll(l), _ctl.camera.zoom);
      } catch (_) {} // camera not laid out yet — next fix recentres
    }
  }

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
    final playAt = (w.playIndex != null && w.route.isNotEmpty)
        ? w.route[w.playIndex!.clamp(0, w.route.length - 1)]
        : null;
    final center = w.live != null
        ? _ll(w.live!)
        : (all.isNotEmpty ? all.last : const LatLng(23.8103, 90.4125)); // Dhaka
    final fit = (!w.follow && all.length >= 2)
        ? CameraFit.coordinates(coordinates: all, padding: const EdgeInsets.all(32),
            maxZoom: 17)
        : null;
    return Semantics(
      label: w.semanticsLabel,
      image: true,
      child: ExcludeSemantics(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Radii.md),
          child: FlutterMap(
            mapController: _ctl,
            options: MapOptions(
              initialCenter: center,
              initialZoom: 15,
              initialCameraFit: fit,
              maxZoom: w.config.maxZoom.toDouble(),
              minZoom: 3,
              backgroundColor: scheme.surfaceContainerHighest,
              onMapReady: () => _ready = true,
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
              if (w.fences.isNotEmpty)
                CircleLayer(circles: [
                  for (final f in w.fences)
                    CircleMarker(
                      point: LatLng(f.lat, f.lng),
                      radius: f.radiusM,
                      useRadiusInMeter: true,
                      color: Brand.cyan.withValues(alpha: 0.12),
                      borderColor: Brand.cyan,
                      borderStrokeWidth: 2,
                    ),
                ]),
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
                PolylineLayer(polylines: [
                  Polyline(points: pts, color: Brand.blue, strokeWidth: 4),
                ]),
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
                    width: 22,
                    height: 22,
                    child: const _Dot(color: Brand.warning),
                  ),
                if (w.live != null)
                  Marker(
                    key: const ValueKey('veh-live-marker'),
                    point: _ll(w.live!),
                    width: 40,
                    height: 40,
                    child: Icon(Icons.directions_car_filled_rounded,
                        size: 34, color: scheme.error),
                  ),
              ]),
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
          ),
        ),
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
