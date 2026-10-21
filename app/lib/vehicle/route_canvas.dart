import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// A geographic point for the route canvas.
class GeoPt {
  final double lat, lng;
  final DateTime? at;
  final double speed;
  const GeoPt(this.lat, this.lng, {this.at, this.speed = 0});
}

/// A circle area (geofence) to draw.
class GeoFenceView {
  final double lat, lng, radiusM;
  final String name;
  const GeoFenceView(this.lat, this.lng, this.radiusM, this.name);
}

/// Tile-free route map: draws the 24 h route, start / end, geofences, the
/// live position and an animated playback marker on a projected canvas. It
/// needs NO map SDK, API key or network (works offline, nothing to fake);
/// "Open in Maps" next to it hands the live point to the phone's map app for
/// streets. Equirectangular projection with cos(lat) correction — accurate at
/// city scale, which is what a vehicle's day looks like.
class RouteCanvas extends StatelessWidget {
  final List<GeoPt> route;
  final GeoPt? live;
  final int? playIndex;
  final List<GeoFenceView> fences;
  final String semanticsLabel;
  final String? scaleLabel;

  const RouteCanvas({
    super.key,
    required this.route,
    this.live,
    this.playIndex,
    this.fences = const [],
    required this.semanticsLabel,
    this.scaleLabel,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      label: semanticsLabel,
      image: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.md),
        child: CustomPaint(
          painter: _RoutePainter(
            route: route,
            live: live,
            playIndex: playIndex,
            fences: fences,
            bg: dark ? const Color(0xFF10131C) : const Color(0xFFEFF3FA),
            grid: dark ? const Color(0xFF1C2130) : const Color(0xFFDCE3F0),
            start: Brand.success,
            end: scheme.error,
            marker: scheme.primary,
            onMarker: scheme.onPrimary,
            fenceColor: Brand.purple,
            text: scheme.onSurfaceVariant,
            scaleLabel: scaleLabel,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _RoutePainter extends CustomPainter {
  final List<GeoPt> route;
  final GeoPt? live;
  final int? playIndex;
  final List<GeoFenceView> fences;
  final Color bg, grid, start, end, marker, onMarker, fenceColor, text;
  final String? scaleLabel;

  _RoutePainter({
    required this.route,
    required this.live,
    required this.playIndex,
    required this.fences,
    required this.bg,
    required this.grid,
    required this.start,
    required this.end,
    required this.marker,
    required this.onMarker,
    required this.fenceColor,
    required this.text,
    required this.scaleLabel,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);
    final gp = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 32) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gp);
    }
    for (double y = 0; y < size.height; y += 32) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gp);
    }

    final all = <GeoPt>[...route, if (live != null) live!];
    for (final f in fences) {
      all.add(GeoPt(f.lat, f.lng));
    }
    if (all.isEmpty) return;

    var minLat = all.first.lat, maxLat = all.first.lat;
    var minLng = all.first.lng, maxLng = all.first.lng;
    for (final p in all) {
      minLat = math.min(minLat, p.lat);
      maxLat = math.max(maxLat, p.lat);
      minLng = math.min(minLng, p.lng);
      maxLng = math.max(maxLng, p.lng);
    }
    for (final f in fences) {
      final dLat = f.radiusM / 111320.0;
      minLat = math.min(minLat, f.lat - dLat);
      maxLat = math.max(maxLat, f.lat + dLat);
    }
    final midLat = (minLat + maxLat) / 2;
    final kx = math.cos(midLat * math.pi / 180);
    // metres-ish extents; never zero (a parked car is one point)
    var w = (maxLng - minLng) * kx;
    var h = (maxLat - minLat);
    const minSpan = 0.004; // ~450 m
    if (w < minSpan) {
      final c = (minLng + maxLng) / 2;
      minLng = c - minSpan / kx / 2;
      maxLng = c + minSpan / kx / 2;
      w = minSpan;
    }
    if (h < minSpan) {
      final c = (minLat + maxLat) / 2;
      minLat = c - minSpan / 2;
      maxLat = c + minSpan / 2;
      h = minSpan;
    }
    const pad = 28.0;
    final sx = (size.width - 2 * pad) / w;
    final sy = (size.height - 2 * pad) / h;
    final s = math.min(sx, sy);
    final ox = (size.width - w * s) / 2;
    final oy = (size.height - h * s) / 2;
    Offset proj(double lat, double lng) =>
        Offset(ox + (lng - minLng) * kx * s, oy + (maxLat - lat) * s);

    for (final f in fences) {
      final c = proj(f.lat, f.lng);
      final r = f.radiusM / 111320.0 * s;
      canvas.drawCircle(c, r, Paint()..color = fenceColor.withValues(alpha: 0.12));
      canvas.drawCircle(
          c,
          r,
          Paint()
            ..color = fenceColor.withValues(alpha: 0.6)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
    }

    if (route.length >= 2) {
      final path = Path();
      final o0 = proj(route.first.lat, route.first.lng);
      path.moveTo(o0.dx, o0.dy);
      for (final p in route.skip(1)) {
        final o = proj(p.lat, p.lng);
        path.lineTo(o.dx, o.dy);
      }
      final bounds = path.getBounds();
      final shader = const LinearGradient(
              colors: [Brand.cyan, Brand.blue, Brand.purple])
          .createShader(bounds.inflate(1));
      canvas.drawPath(
          path,
          Paint()
            ..color = Colors.black.withValues(alpha: 0.10)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 7
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round);
      canvas.drawPath(
          path,
          Paint()
            ..shader = shader
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round);
      _dot(canvas, proj(route.first.lat, route.first.lng), start);
      _dot(canvas, proj(route.last.lat, route.last.lng), end);
    }

    if (playIndex != null && route.isNotEmpty) {
      final p = route[playIndex!.clamp(0, route.length - 1)];
      final o = proj(p.lat, p.lng);
      canvas.drawCircle(o, 13, Paint()..color = marker.withValues(alpha: 0.25));
      canvas.drawCircle(o, 8, Paint()..color = marker);
      canvas.drawCircle(o, 3, Paint()..color = onMarker);
    } else if (live != null) {
      final o = proj(live!.lat, live!.lng);
      canvas.drawCircle(o, 16, Paint()..color = marker.withValues(alpha: 0.20));
      canvas.drawCircle(o, 9, Paint()..color = Colors.white);
      canvas.drawCircle(o, 7, Paint()..color = marker);
    }

    if (scaleLabel != null) {
      final tp = TextPainter(
        text: TextSpan(
            text: scaleLabel,
            style: TextStyle(color: text, fontSize: 11, fontWeight: FontWeight.w600)),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: size.width - 16);
      tp.paint(canvas, Offset(10, size.height - tp.height - 8));
    }
  }

  void _dot(Canvas c, Offset o, Color color) {
    c.drawCircle(o, 7, Paint()..color = Colors.white);
    c.drawCircle(o, 5, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _RoutePainter old) =>
      old.route != route ||
      old.playIndex != playIndex ||
      old.live?.lat != live?.lat ||
      old.live?.lng != live?.lng ||
      old.bg != bg ||
      old.fences != fences;
}
