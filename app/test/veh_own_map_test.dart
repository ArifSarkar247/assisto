// flag-vehicle: the vehicle live map on OUR OWN tiles (/maps/v1/, MapLibre)
// when no raster tile provider is configured — overlay building is pure and
// tested here; the widget runs in AssistoMapView's canvas mode (no GL in tests).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:assisto/city/map/assisto_map_view.dart';
import 'package:assisto/city/map/city_map_data.dart' show hexOf;
import 'package:assisto/vehicle/route_canvas.dart';
import 'package:assisto/vehicle/veh_map.dart';

const _calm = Color(0xFF1565C0), _near = Color(0xFFF9A825), _over = Color(0xFFC62828);
const _plan = Color(0xFF6A1B9A), _fence = Color(0xFF00838F);

List<GeoPt> _route() => [
      for (var i = 0; i < 12; i++)
        GeoPt(23.751, 90.380 + i * 0.001, speed: i < 6 ? 25.0 : (i < 9 ? 72.0 : 50.0))
    ];

void main() {
  test('circle fence ring is closed and about the right size', () {
    final r = vehCircleRing(23.75, 90.39, 150);
    expect(r.length, 49);
    expect(r.first[0], closeTo(r.last[0], 1e-9));
    expect(r.first[1], closeTo(r.last[1], 1e-9));
    // north point: lat + 150 m
    expect(r.first[1] - 23.75, closeTo(150 / 110574.0, 1e-7));
  });

  test('overlay: speed-coloured runs, fences, planned route, playback point', () {
    final l = vehOwnLayers(
      route: _route(),
      planned: const [GeoPt(23.751, 90.380), GeoPt(23.751, 90.392)],
      fences: const [
        GeoFenceView(23.751, 90.380, 150, 'Home'),
        GeoFenceView(23.752, 90.39, 0, 'Office',
            points: [GeoPt(23.75, 90.389), GeoPt(23.75, 90.391), GeoPt(23.753, 90.391)]),
      ],
      playIndex: 99,
      speedColours: true,
      speedLimitKmh: 60,
      calm: _calm,
      near: _near,
      over: _over,
      plannedColor: _plan,
      fenceColor: _fence,
    );
    final lines = (l.lines['features'] as List).cast<Map>();
    final colours = [for (final f in lines) (f['properties'] as Map)['color']];
    expect(colours.where((c) => c == hexOf(_fence)).length, 2);
    expect(colours, contains(hexOf(_plan)));
    expect(colours, contains(hexOf(_over))); // 72 km/h over a 60 limit
    expect(colours, contains(hexOf(_calm)));
    // polygon fence closed
    final poly = (lines[1]['geometry'] as Map)['coordinates'] as List;
    expect(poly.first, poly.last);
    // playback index is clamped to the last fix
    final pts = (l.points['features'] as List).cast<Map>();
    expect(pts.length, 1);
    expect((pts.first['geometry'] as Map)['coordinates'], [_route().last.lng, _route().last.lat]);
  });

  test('plain route without speed colours is one blue line', () {
    final l = vehOwnLayers(
        route: _route(), calm: _calm, near: _near, over: _over, plannedColor: _plan, fenceColor: _fence);
    final lines = (l.lines['features'] as List).cast<Map>();
    expect(lines.length, 1);
    expect((lines.first['properties'] as Map)['color'], hexOf(_calm));
    expect((l.points['features'] as List), isEmpty);
  });

  group('VehMap on our own tiles', () {
    setUp(() {
      VehMap.ownMap = true;
      AssistoMapView.debugCanvas = true;
    });
    tearDown(() {
      VehMap.ownMap = false;
      AssistoMapView.debugCanvas = false;
    });

    Widget app(VehMap m, {Brightness b = Brightness.light}) => MaterialApp(
          theme: ThemeData(brightness: b),
          home: Scaffold(body: SizedBox(width: 360, height: 360, child: m)),
        );

    testWidgets('no raster provider -> own map with the live pin', (tester) async {
      for (final b in Brightness.values) {
        await tester.pumpWidget(app(
            VehMap(
              config: const VehMapConfig(),
              route: _route(),
              live: const GeoPt(23.751, 90.391),
              speedColours: true,
              speedLimitKmh: 60,
              fences: const [GeoFenceView(23.751, 90.380, 150, 'Home')],
              semanticsLabel: 'Live map',
            ),
            b: b));
        await tester.pump();
        expect(find.byKey(const ValueKey('veh-own-map')), findsOneWidget);
        expect(find.byKey(const ValueKey('city_map_canvas')), findsOneWidget);
        expect(find.byIcon(Icons.trip_origin_rounded), findsOneWidget); // live pin
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('fence drawing (map taps) keeps the tile-free canvas', (tester) async {
      await tester.pumpWidget(app(VehMap(
        config: const VehMapConfig(),
        route: _route(),
        semanticsLabel: 'Draw',
        onTap: (_) {},
      )));
      await tester.pump();
      expect(find.byKey(const ValueKey('veh-own-map')), findsNothing);
      expect(find.byType(RouteCanvas), findsOneWidget);
    });

    test('a configured raster provider still wins over the own map', () {
      final cfg = VehMapConfig.fromJson({'tile_url': 'https://tiles.example.test/{z}/{x}/{y}.png'});
      expect(cfg.hasTiles, isTrue);
      expect(const VehMapConfig().hasTiles, isFalse);
    });
  });
}
