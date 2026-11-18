// mapapp: the Assisto map (MapLibre, open source, BSD-2). Our own vector
// tiles (CITY_MAP_TILES_API.md) + OUR City Service overlays on top.
//
// Crash safety (ColorOS / 2 GB phones): nothing native runs at app start;
// the GL view is created only after this screen's first frame, behind the
// CityMapGuard marker (a crash while opening -> list view next time), with
// a 20 s style-load timeout -> list view. No style (offline, never cached)
// -> list view. Labels WE draw are Flutter widgets over the map (MapLibre
// cannot shape Bengali), decluttered and hidden while the camera moves.
import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:provider/provider.dart';

import '../../state.dart';
import '../../theme.dart';
import 'city_map_data.dart';
import 'city_map_style.dart';

/// A pin we draw (start / destination).
typedef MapPin = ({double lat, double lon, bool dest});

class AssistoMapView extends StatefulWidget {
  final double lat, lon;
  final bool night, bn, show3d;
  final CityLayerSet layers;
  final List<MapPin> pins;

  /// The list view (GL cannot run / no style yet).
  final WidgetBuilder fallback;

  /// Tells the screen whether the GL map runs (false = list view).
  final ValueChanged<bool>? onMode;

  /// Tests + gallery: draw our overlay on a plain canvas (no native view).
  @visibleForTesting
  static bool debugCanvas = false;

  const AssistoMapView(
      {super.key,
      required this.lat,
      required this.lon,
      required this.night,
      required this.bn,
      required this.layers,
      required this.fallback,
      this.show3d = true,
      this.pins = const [],
      this.onMode});

  @override
  State<AssistoMapView> createState() => _AssistoMapViewState();
}

enum _Phase { waiting, gl, fallback, canvas }

class _AssistoMapViewState extends State<AssistoMapView> {
  _Phase _phase = _Phase.waiting;
  String? _style;
  ml.MapLibreMapController? _c;
  bool _styleReady = false, _moving = false;
  Timer? _timeout;
  List<(Offset, MapLabel)> _placed = const [];
  List<(Offset, MapPin)> _pinsAt = const [];

  @override
  void initState() {
    super.initState();
    if (AssistoMapView.debugCanvas) {
      _phase = _Phase.canvas;
      return;
    }
    // lazy: the native view is created only after the first frame
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    final api = context.read<AppState>().api;
    if (!await CityMapGuard.glAllowed()) return _fail();
    final s = await CityMapStyle.I.load(api, night: widget.night, bn: widget.bn, lat: widget.lat, lon: widget.lon);
    if (!mounted) return;
    if (s == null) return _fail();
    await CityMapGuard.opening();
    if (!mounted) return;
    setState(() {
      _style = s;
      _phase = _Phase.gl;
    });
    _armTimeout();
  }

  void _armTimeout() {
    _timeout?.cancel();
    _timeout = Timer(const Duration(seconds: 20), () {
      if (!_styleReady) {
        unawaited(CityMapGuard.opened()); // slow, not a crash
        _fail();
      }
    });
  }

  void _fail() {
    if (!mounted) return;
    setState(() => _phase = _Phase.fallback);
    widget.onMode?.call(false);
  }

  @override
  void didUpdateWidget(AssistoMapView old) {
    super.didUpdateWidget(old);
    if (_phase != _Phase.gl) return;
    if (old.night != widget.night || old.bn != widget.bn) {
      _styleReady = false;
      CityMapStyle.I
          .load(context.read<AppState>().api, night: widget.night, bn: widget.bn, lat: widget.lat, lon: widget.lon)
          .then((s) {
        if (!mounted || s == null) return;
        setState(() => _style = s);
        _armTimeout();
      });
      return;
    }
    if (!identical(old.layers, widget.layers) || !listEquals(old.pins, widget.pins)) unawaited(_setData());
    if (old.show3d != widget.show3d) unawaited(_set3d());
    if (old.lat != widget.lat || old.lon != widget.lon) {
      unawaited(_c?.animateCamera(ml.CameraUpdate.newLatLng(ml.LatLng(widget.lat, widget.lon))));
    }
  }

  @override
  void dispose() {
    _timeout?.cancel();
    _c?.removeListener(_onCamera);
    if (_phase == _Phase.gl && !_styleReady) unawaited(CityMapGuard.opened()); // left early: not a crash
    super.dispose();
  }

  // ---------------------------------------------------------------- GL
  Map<String, dynamic> get _pinFc => {
        'type': 'FeatureCollection',
        'features': [
          for (final p in widget.pins)
            {
              'type': 'Feature',
              'properties': {'color': hexOf(p.dest ? Brand.danger : Brand.success), 'radius': 9},
              'geometry': {
                'type': 'Point',
                'coordinates': [p.lon, p.lat]
              },
            }
        ],
      };

  Future<void> _onStyle() async {
    _styleReady = true;
    if (mounted) setState(() {}); // gap-nearby: the 'city_map_gl_ready' marker
    _timeout?.cancel();
    await CityMapGuard.opened();
    widget.onMode?.call(true);
    final c = _c;
    if (c == null) return;
    try {
      await c.addGeoJsonSource('assisto_lines', widget.layers.lines);
      await c.addGeoJsonSource('assisto_points', widget.layers.points);
      await c.addGeoJsonSource('assisto_pins', _pinFc);
      const line = ml.LineLayerProperties(
          lineColor: ['get', 'color'],
          lineWidth: ['get', 'width'],
          lineOpacity: 0.9,
          lineCap: 'round',
          lineJoin: 'round');
      const dot = ml.CircleLayerProperties(
          circleColor: ['get', 'color'],
          circleRadius: ['get', 'radius'],
          circleOpacity: 0.85,
          circleStrokeColor: '#ffffff',
          circleStrokeWidth: 2);
      // our layers sit under the road labels (contract §2); a style
      // without that layer still gets them on top
      Future<void> add(Future<void> Function(String? below) f) async {
        try {
          await f('road-labels');
        } catch (_) {
          await f(null);
        }
      }

      await add((b) => c.addLineLayer('assisto_lines', 'assisto-lines', line, belowLayerId: b));
      await add((b) => c.addCircleLayer('assisto_points', 'assisto-points', dot, belowLayerId: b));
      await c.addCircleLayer('assisto_pins', 'assisto-pins', dot);
      await _set3d();
    } catch (_) {} // overlay is best-effort; the base map still works
    _onCamera();
    unawaited(_project());
  }

  Future<void> _setData() async {
    final c = _c;
    if (c == null || !_styleReady) return;
    try {
      await c.setGeoJsonSource('assisto_lines', widget.layers.lines);
      await c.setGeoJsonSource('assisto_points', widget.layers.points);
      await c.setGeoJsonSource('assisto_pins', _pinFc);
    } catch (_) {}
    unawaited(_project());
  }

  Future<void> _set3d() async {
    final c = _c;
    if (c == null || !_styleReady) return;
    try {
      await c.setLayerVisibility('buildings-3d', widget.show3d);
      await c.animateCamera(ml.CameraUpdate.tiltTo(widget.show3d ? 45 : 0));
    } catch (_) {}
  }

  void _onCamera() {
    final m = _c?.isCameraMoving ?? false;
    if (m != _moving && mounted) setState(() => _moving = m);
  }

  Future<void> _project() async {
    final c = _c;
    if (c == null || !mounted) return;
    final labels = widget.layers.labels.take(80).toList();
    try {
      final pts = await c.toScreenLocationBatch([
        for (final l in labels) ml.LatLng(l.lat, l.lon),
        for (final p in widget.pins) ml.LatLng(p.lat, p.lon),
      ]);
      if (!mounted) return;
      // Android answers in physical pixels
      final k = Platform.isAndroid ? MediaQuery.devicePixelRatioOf(context) : 1.0;
      final off = [for (final p in pts) Offset(p.x.toDouble() / k, p.y.toDouble() / k)];
      setState(() {
        _placed = declutter([for (var i = 0; i < labels.length; i++) (off[i], labels[i])]);
        _pinsAt = [for (var i = 0; i < widget.pins.length; i++) (off[labels.length + i], widget.pins[i])];
      });
    } catch (_) {}
  }

  // ---------------------------------------------------------------- UI
  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return switch (_phase) {
      _Phase.waiting => ColoredBox(
          color: s.surfaceContainerHighest,
          child: const Center(child: CircularProgressIndicator()),
        ),
      _Phase.fallback => widget.fallback(context),
      _Phase.canvas => LayoutBuilder(builder: (context, box) {
          final proj = CanvasProjection(widget.lat, widget.lon, 13.2, box.biggest);
          final labels = declutter([for (final l in widget.layers.labels) (proj.at(l.lat, l.lon), l)]);
          return Stack(children: [
            Positioned.fill(
                child: CustomPaint(
                    key: const ValueKey('city_map_canvas'),
                    painter: _OverlayPainter(widget.layers, proj, s.surfaceContainerHighest, s.outlineVariant))),
            ..._labelWidgets(labels),
            for (final p in widget.pins) _pinWidget(proj.at(p.lat, p.lon), p),
          ]);
        }),
      _Phase.gl => Stack(children: [
          Positioned.fill(
            child: ml.MapLibreMap(
              key: const ValueKey('city_map_gl'),
              styleString: _style!,
              initialCameraPosition: ml.CameraPosition(
                  target: ml.LatLng(widget.lat, widget.lon), zoom: 14.5, tilt: widget.show3d ? 45 : 0),
              onMapCreated: (c) {
                _c = c;
                c.addListener(_onCamera);
              },
              onStyleLoadedCallback: _onStyle,
              onCameraIdle: () => unawaited(_project()),
              trackCameraPosition: true,
              compassEnabled: true,
              myLocationEnabled: false, // no location prompt here; our pins show the trip
              attributionButtonPosition: ml.AttributionButtonPosition.bottomRight,
            ),
          ),
          if (!_moving) ..._labelWidgets(_placed),
          if (!_moving)
            for (final p in _pinsAt) _pinWidget(p.$1, p.$2),
          // gap-nearby: the real map's style + tiles loaded (emulator proof)
          if (_styleReady) const SizedBox.shrink(key: ValueKey('city_map_gl_ready')),
        ]),
    };
  }

  List<Widget> _labelWidgets(List<(Offset, MapLabel)> placed) => [
        for (final (o, l) in placed)
          Positioned(
            left: o.dx + 6,
            top: o.dy - 12,
            child: IgnorePointer(child: MapLabelChip(l)),
          ),
      ];

  Widget _pinWidget(Offset o, MapPin p) => Positioned(
        left: o.dx - 14,
        top: o.dy - 28,
        child: IgnorePointer(
            child: Icon(p.dest ? Icons.place_rounded : Icons.trip_origin_rounded,
                size: 28, color: p.dest ? Brand.danger : Brand.success)),
      );
}

/// Drop labels that would overlap one already placed (priority = order).
List<(Offset, MapLabel)> declutter(List<(Offset, MapLabel)> all, {double w = 120, double h = 26}) {
  final out = <(Offset, MapLabel)>[];
  for (final e in all) {
    final r = Rect.fromLTWH(e.$1.dx, e.$1.dy - h / 2, w, h);
    if (out.any((x) => Rect.fromLTWH(x.$1.dx, x.$1.dy - h / 2, w, h).overlaps(r))) continue;
    out.add(e);
  }
  return out;
}

class MapLabelChip extends StatelessWidget {
  final MapLabel label;
  const MapLabelChip(this.label, {super.key});
  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(maxWidth: 160),
      padding: const EdgeInsets.symmetric(horizontal: Gap.xs + 2, vertical: Gap.xxs),
      decoration: BoxDecoration(
        color: s.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: label.color, width: 1.5),
      ),
      child: Text(label.text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AType.labelSmall.copyWith(color: s.onSurface, fontWeight: FontWeight.w700)),
    );
  }
}

/// Web-Mercator projection around a centre (canvas mode + tests).
class CanvasProjection {
  final double lat, lon, zoom;
  final Size size;
  const CanvasProjection(this.lat, this.lon, this.zoom, this.size);
  static double _x(double lon, double z) => (lon + 180) / 360 * 256 * math.pow(2, z);
  static double _y(double lat, double z) {
    final r = lat * math.pi / 180;
    return (1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * 256 * math.pow(2, z);
  }

  Offset at(double la, double lo) => Offset(
      size.width / 2 + _x(lo, zoom) - _x(lon, zoom), size.height / 2 + _y(la, zoom) - _y(lat, zoom));
}

Color _hex(String h, Color def) {
  final v = int.tryParse(h.replaceFirst('#', ''), radix: 16);
  return v == null ? def : Color.fromARGB(255, (v >> 16) & 255, (v >> 8) & 255, v & 255);
}

class _OverlayPainter extends CustomPainter {
  final CityLayerSet layers;
  final CanvasProjection proj;
  final Color bg, grid;
  _OverlayPainter(this.layers, this.proj, this.bg, this.grid);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);
    final g = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 48) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), g);
    }
    for (var y = 0.0; y < size.height; y += 48) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), g);
    }
    for (final f in (layers.lines['features'] as List).cast<Map>()) {
      final p = (f['properties'] as Map);
      final pts = [
        for (final c in ((f['geometry'] as Map)['coordinates'] as List))
          proj.at(((c as List)[1] as num).toDouble(), (c[0] as num).toDouble())
      ];
      if (pts.length < 2) continue;
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (final o in pts.skip(1)) {
        path.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = _hex('${p['color']}', Brand.blue)
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..strokeWidth = (p['width'] as num?)?.toDouble() ?? 3);
    }
    for (final f in (layers.points['features'] as List).cast<Map>()) {
      final p = (f['properties'] as Map);
      final c = ((f['geometry'] as Map)['coordinates'] as List);
      final o = proj.at((c[1] as num).toDouble(), (c[0] as num).toDouble());
      final r = (p['radius'] as num?)?.toDouble() ?? 6;
      canvas.drawCircle(o, r, Paint()..color = _hex('${p['color']}', Brand.blue).withValues(alpha: 0.85));
      canvas.drawCircle(
          o,
          r,
          Paint()
            ..color = bg
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(_OverlayPainter o) => !identical(o.layers, layers) || o.bg != bg;
}
