// e2e-vehicle: phone Car Mode end to end on the app side + the real map.
//  * CarModeEngine (pure): live speed, stop detection, over-speed, off-route
//    (armed only after joining the route, re-arms, disarms on arrival), long
//    stop, GPS-speed fallback.
//  * CarModeScreen fed by a fake GPS stream: live map (flutter_map, tiles from
//    an in-memory provider — no network) with the car marker + OSM
//    attribution, live speed, Moving / Stopped chip, On route / Off route
//    chip, over-speed / off-route / long-stop alert banners, upload carries
//    the speed limit + usual route, "save as usual route"; bn + en, dark,
//    200 % text, no overflow.
//  * VehicleTrackerScreen: real map when the server configures tiles, the
//    tile-free canvas when it does not; owner sets / clears the planned route.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/car_mode_screen.dart';
import 'package:assisto/screens/vehicle_tracker_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/vehicle/car_mode_engine.dart';
import 'package:assisto/vehicle/route_canvas.dart';
import 'package:assisto/vehicle/veh_map.dart';

// 1x1 transparent PNG
final _png = Uint8List.fromList(base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='));

class _MemTiles extends TileProvider {
  int requests = 0;
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    requests++;
    return MemoryImage(_png);
  }
}

const home = GeoPt(23.7808, 90.4130);
// ~3 km due east of home
const routeEnd = GeoPt(23.7808, 90.4424);
const usual = [home, routeEnd];

GeoPt east(GeoPt p, double m) => GeoPt(p.lat, p.lng + m / (111320.0 * 0.9151));
GeoPt north(GeoPt p, double m) => GeoPt(p.lat + m / 110574.0, p.lng);

class _FakeVehApi extends ApiClient {
  _FakeVehApi() : super.detached('t');
  final List<Map<String, dynamic>> posted = [];
  final List<Map<String, dynamic>> patched = [];
  List<dynamic> routes = [];

  Map<String, dynamic> _tracker() => {
        'id': 7,
        'name': 'Corolla',
        'protocol': 'h02',
        'state': 'paired',
        'online': true,
        'is_owner': true,
        'access': {'view': true, 'command': false, 'manage': true},
        'last_seen_at': DateTime.now().toUtc().toIso8601String(),
        'live': {'lat': 23.7808, 'lng': 90.4300, 'speed_kmh': 0, 'moving': false,
                 'at': DateTime.now().toUtc().toIso8601String(), 'fix_age_s': 5},
        'settings': {'geofences': [], 'routes': routes},
      };

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/vehicle/config') return {'map': {}};
    if (path.contains('/route')) {
      final now = DateTime.now().toUtc();
      final pts = [
        for (var i = 0; i < 30; i++)
          {'at': now.subtract(Duration(minutes: 60 - i)).toIso8601String(),
           'lat': 23.7808, 'lng': 90.4130 + i * 0.0006, 'speed_kmh': 40}
      ];
      return {'points': pts, 'trips': [
        {'start': pts.first['at'], 'end': pts.last['at'], 'km': 1.9}
      ], 'stops': [], 'total_km': 1.9, 'moving_s': 1800, 'max_speed_kmh': 40};
    }
    if (path.endsWith('/commands')) return {'commands': []};
    return _tracker();
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) async {
    posted.add({'path': path, ...body});
    return {'ok': true, 'total_km': 2.4, 'moving_s': 300, 'alerts': []};
  }

  @override
  Future<Map<String, dynamic>> patchJson(String path, [Map<String, dynamic> body = const {}]) async {
    patched.add(body);
    if (body.containsKey('routes')) {
      routes = [
        for (final r in body['routes'] as List) {...(r as Map), 'type': 'route'}
      ];
    }
    return _tracker();
  }
}

AppState _state(ApiClient api, String lang) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return s;
}

Widget _app(Widget home, ApiClient api,
        {String lang = 'en', bool dark = false, double scale = 1.0}) =>
    ChangeNotifierProvider<AppState>.value(
      value: _state(api, lang),
      child: MaterialApp(
        locale: Locale(lang),
        theme: dark ? AssistoTheme.dark : AssistoTheme.light,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: home,
      ),
    );

void _phone(WidgetTester tester, {double height = 2400}) {
  tester.view.physicalSize = Size(360 * 3, height * 3); // smallest common BD phone width
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

const tiles = VehMapConfig(
    tileUrl: 'https://tiles.test/{z}/{x}/{y}.png?key=k',
    attribution: '© MapTiler © OpenStreetMap contributors');

void main() {
  late AppLocalizations en;
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
  });
  setUp(() {
    VehMap.debugTileProvider = _MemTiles();
    VehMapConfig.debugSet(null);
  });
  tearDown(() => VehMap.debugTileProvider = null);

  group('CarModeEngine', () {
    final t0 = DateTime.utc(2026, 10, 27, 8);

    test('over-speed needs 2 fixes, re-arms 10 km/h below', () {
      final e = CarModeEngine(speedLimitKmh: 60);
      expect(e.add(23.78, 90.41, t0, 65), isEmpty);              // one spike
      expect(e.add(23.78, 90.41, t0.add(const Duration(seconds: 5)), 59), isEmpty);
      expect(e.add(23.78, 90.41, t0.add(const Duration(seconds: 10)), 70), isEmpty);
      final a = e.add(23.78, 90.41, t0.add(const Duration(seconds: 15)), 72);
      expect(a.single.kind, CarAlertKind.overspeed);
      expect(e.add(23.78, 90.41, t0.add(const Duration(seconds: 20)), 75), isEmpty);
      e.add(23.78, 90.41, t0.add(const Duration(seconds: 25)), 40);   // re-arm
      e.add(23.78, 90.41, t0.add(const Duration(seconds: 30)), 70);
      expect(e.add(23.78, 90.41, t0.add(const Duration(seconds: 35)), 70).single.kind,
          CarAlertKind.overspeed);
    });

    test('off-route: armed on the route, 3 fixes out, re-arm, disarm at end', () {
      final e = CarModeEngine(route: usual, corridorM: 300, stopAlertMin: 0);
      var t = t0;
      var p = home;
      for (var i = 0; i < 10; i++) {
        expect(e.add(p.lat, p.lng, t, 40), isEmpty);
        p = east(p, 55);
        t = t.add(const Duration(seconds: 5));
      }
      expect(e.armed, isTrue);
      final raised = <CarAlert>[];
      for (var i = 1; i <= 6; i++) {
        final q = north(p, i * 120.0);
        raised.addAll(e.add(q.lat, q.lng, t, 50));
        t = t.add(const Duration(seconds: 5));
      }
      expect(raised.single.kind, CarAlertKind.offRoute);
      expect(raised.single.distanceM, greaterThan(300));
      expect(e.offRoute, isTrue);
      // back on the route clears + re-arms; leaving again alerts again
      e.add(p.lat, p.lng, t, 40);
      expect(e.offRoute, isFalse);
      final again = <CarAlert>[];
      for (var i = 1; i <= 4; i++) {
        final q = north(p, 400.0 + i);
        again.addAll(e.add(q.lat, q.lng, t.add(Duration(seconds: i)), 40));
      }
      expect(again.map((a) => a.kind), [CarAlertKind.offRoute]);
      // arrival disarms
      e.add(routeEnd.lat, routeEnd.lng, t.add(const Duration(minutes: 5)), 0);
      expect(e.armed, isFalse);
      final far = north(routeEnd, 2000);
      for (var i = 0; i < 5; i++) {
        expect(e.add(far.lat, far.lng, t.add(Duration(minutes: 6, seconds: i)), 30), isEmpty);
      }
    });

    test('never armed when the trip starts away from the route', () {
      final e = CarModeEngine(route: usual);
      final s = north(home, 2000);
      for (var i = 0; i < 8; i++) {
        expect(e.add(s.lat + i * 1e-4, s.lng, t0.add(Duration(seconds: i * 5)), 30), isEmpty);
      }
      expect(e.offRoute, isFalse);
      expect(e.distanceToRouteM, greaterThan(1500));
    });

    test('stop detection + long stop on the route; GPS speed fallback', () {
      final e = CarModeEngine(route: usual, stopAlertMin: 10);
      final p = east(home, 500);
      e.add(p.lat, p.lng, t0, 30);
      expect(e.moving, isTrue);
      final out = <CarAlert>[];
      for (var m = 0; m <= 11; m++) {
        out.addAll(e.add(p.lat, p.lng, t0.add(Duration(minutes: m, seconds: 5)), 0));
      }
      expect(e.moving, isFalse);
      expect(e.stoppedMinutes, 11);
      expect(out.single.kind, CarAlertKind.longStop);
      expect(out.single.minutes, 10);
      // no GPS speed (-1): derived from distance / time (≈ 39.6 km/h)
      final q = east(p, 55);
      e.add(q.lat, q.lng, t0.add(const Duration(minutes: 11, seconds: 10)), -1);
      expect(e.speedKmh, closeTo(39.6, 1.5));
      expect(e.stoppedSince, isNull);
      expect(routeDistanceM(usual, north(home, 250).lat, home.lng + 0.01), closeTo(250, 5));
    });

    test('simplify keeps ends and caps the size', () {
      final pts = [for (var i = 0; i < 1000; i++) GeoPt(23 + i * 1e-4, 90)];
      final s = CarModeEngine.simplify(pts, max: 200);
      expect(s.length, 200);
      expect(s.first.lat, pts.first.lat);
      expect(s.last.lat, pts.last.lat);
    });
  });

  group('CarModeScreen live', () {
    Future<StreamController<CarFix>> start(WidgetTester tester, _FakeVehApi api,
        {String lang = 'en', bool dark = false, double scale = 1.0}) async {
      SharedPreferences.setMockInitialValues({
        'veh_car_speed_limit': 60,
        'veh_car_use_route': true,
        'veh_car_usual_route': jsonEncode([for (final g in usual) [g.lat, g.lng]]),
      });
      final ctl = StreamController<CarFix>();
      addTearDown(ctl.close);
      await tester.pumpWidget(_app(
          CarModeScreen(positionSource: () => ctl.stream, mapConfig: tiles), api,
          lang: lang, dark: dark, scale: scale));
      await _settle(tester);
      final tr = await AppLocalizations.delegate.load(Locale(lang));
      await tester.tap(find.text(tr.vehCarStartTrip));
      await _settle(tester);
      return ctl;
    }

    testWidgets('map, speed, stop, off-route, over-speed, upload, save route',
        (tester) async {
      _phone(tester);
      final api = _FakeVehApi();
      final gps = await start(tester, api);
      var t = DateTime.now().toUtc().subtract(const Duration(minutes: 30));
      var p = home;
      for (var i = 0; i < 6; i++) {
        gps.add(CarFix(p.lat, p.lng, 40, t));
        p = east(p, 55);
        t = t.add(const Duration(seconds: 5));
      }
      await _settle(tester);
      expect(find.byKey(const ValueKey('car-live')), findsOneWidget);
      expect(find.byType(FlutterMap), findsOneWidget);
      expect(find.byIcon(Icons.directions_car_filled_rounded), findsOneWidget);
      expect(find.textContaining('OpenStreetMap'), findsOneWidget);
      expect((VehMap.debugTileProvider as _MemTiles).requests, greaterThan(0));
      expect(find.text(en.vehKmh('40')), findsWidgets);
      expect(find.text(en.e2eVehMoving), findsOneWidget);
      expect(find.text(en.e2eVehOnRoute), findsOneWidget);
      expect(find.byKey(const ValueKey('car-alert')), findsNothing);

      // turn north off the route at 70 km/h (limit 60)
      for (var i = 1; i <= 7; i++) {
        final q = north(p, i * 100.0);
        gps.add(CarFix(q.lat, q.lng, 70, t));
        t = t.add(const Duration(seconds: 5));
        await _settle(tester, 2);
        if (i == 2) {
          expect(find.textContaining('Slow down'), findsOneWidget);
        }
      }
      await _settle(tester);
      expect(find.byKey(const ValueKey('car-alert')), findsOneWidget);
      expect(find.textContaining('You left your usual route'), findsOneWidget);
      expect(find.textContaining('off your usual route'), findsOneWidget);

      // park 12 minutes
      final park = north(p, 700);
      for (var m = 0; m <= 12; m++) {
        gps.add(CarFix(park.lat, park.lng, 0, t.add(Duration(minutes: m))));
      }
      await _settle(tester);
      expect(find.text(en.e2eVehStoppedFor('12')), findsOneWidget);
      expect(find.text(en.vehKmh('0')), findsWidgets);
      expect(tester.takeException(), isNull);

      // stop the trip -> upload carries limit + usual route; save as usual route
      expect(find.byKey(const ValueKey('car-trip')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('car-trip')));
      await _settle(tester, 2);
      expect(find.text(en.vehCarStopTrip), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('car-trip')));
      await _settle(tester, 12);
      final snacks = tester.widgetList<SnackBar>(find.byType(SnackBar))
          .map((b) => (b.content as Text).data).toList();
      final labels = tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList();
      expect(api.posted, hasLength(1), reason: 'snacks: $snacks texts: $labels');
      final up = api.posted.single;
      expect(up['path'], '/vehicle/carmode/trip');
      expect(up['speed_limit_kmh'], 60);
      expect((up['route'] as Map)['points'], hasLength(2));
      expect((up['points'] as List).length, 6 + 7 + 13);
      expect(find.text(en.vehCarTripSaved), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('car-save-route')));
      await tester.tap(find.byKey(const ValueKey('car-save-route')));
      await _settle(tester);
      final prefs = await SharedPreferences.getInstance();
      final saved = jsonDecode(prefs.getString('veh_car_usual_route')!) as List;
      expect(saved.length, 26);
      expect(find.text(en.e2eVehRouteSaved), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('long stop on the route raises the stop alert', (tester) async {
      _phone(tester);
      final gps = await start(tester, _FakeVehApi());
      final t = DateTime.now().toUtc().subtract(const Duration(minutes: 30));
      final p = east(home, 800);
      gps.add(CarFix(p.lat, p.lng, 35, t));
      for (var m = 0; m <= 10; m++) {
        gps.add(CarFix(p.lat, p.lng, 0, t.add(Duration(minutes: m, seconds: 5))));
      }
      await _settle(tester);
      expect(find.text(en.e2eVehAlertLongStop('10')), findsOneWidget);
      expect(find.text(en.e2eVehOnRoute), findsOneWidget);
      await tester.tap(find.byTooltip(en.close));
      await _settle(tester);
      expect(find.byKey(const ValueKey('car-alert')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    for (final v in const [('bn', false, 1.0), ('en', true, 2.0), ('bn', true, 2.0)]) {
      testWidgets('no overflow ${v.$1} dark=${v.$2} x${v.$3}', (tester) async {
        _phone(tester, height: 4000);
        final gps = await start(tester, _FakeVehApi(), lang: v.$1, dark: v.$2, scale: v.$3);
        var t = DateTime.now().toUtc().subtract(const Duration(minutes: 10));
        var p = home;
        for (var i = 0; i < 4; i++) {
          gps.add(CarFix(p.lat, p.lng, 40, t));
          p = east(p, 55);
          t = t.add(const Duration(seconds: 5));
        }
        for (var i = 1; i <= 4; i++) {
          final q = north(p, i * 150.0);
          gps.add(CarFix(q.lat, q.lng, 75, t.add(Duration(seconds: i * 5))));
        }
        await _settle(tester);
        expect(find.byKey(const ValueKey('car-alert')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('settings: speed alert chips + usual-route switch, 48dp', (tester) async {
      _phone(tester);
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(_app(const CarModeScreen(mapConfig: tiles), _FakeVehApi()));
      await _settle(tester);
      expect(find.byKey(const ValueKey('car-settings')), findsOneWidget);
      expect(find.text(en.e2eVehNoRouteYet), findsOneWidget);
      final sw = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(sw.onChanged, isNull);                 // no usual route yet
      await tester.tap(find.text(en.vehKmh('80')));
      await _settle(tester);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('veh_car_speed_limit'), 80);
      for (final c in tester.widgetList<ChoiceChip>(find.byType(ChoiceChip))) {
        expect(c.materialTapTargetSize, MaterialTapTargetSize.padded);
      }
      expect(tester.getSize(find.byType(ChoiceChip).first).height, greaterThanOrEqualTo(48));
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('VehicleTrackerScreen map', () {
    testWidgets('real map with tiles; owner sets and clears the planned route',
        (tester) async {
      _phone(tester, height: 3000);
      VehMapConfig.debugSet(tiles);
      final api = _FakeVehApi();
      await tester.pumpWidget(_app(const VehicleTrackerScreen(trackerId: 7), api));
      await _settle(tester, 12);
      expect(find.byType(FlutterMap), findsOneWidget);
      expect(find.byType(RouteCanvas), findsNothing);
      expect(find.textContaining('OpenStreetMap'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('veh-plan-set')));
      await _settle(tester, 2);
      expect(tester.widget<ButtonStyleButton>(find.byKey(const ValueKey('veh-plan-set')))
          .onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('veh-plan-set')));
      await _settle(tester);
      final snacks = tester.widgetList<SnackBar>(find.byType(SnackBar))
          .map((b) => (b.content as Text).data).toList();
      expect(api.patched, isNotEmpty, reason: 'snacks: $snacks');
      final routes = api.patched.single['routes'] as List;
      expect(routes, hasLength(1));
      expect((routes.first as Map)['points'], hasLength(30));
      expect((routes.first as Map)['corridor_m'], 300);
      expect(find.text(en.e2eVehPlanSaved), findsOneWidget);
      expect(find.byKey(const ValueKey('veh-plan-clear')), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is PolylineLayer),
          findsNWidgets(2)); // trip + planned
      await tester.tap(find.byKey(const ValueKey('veh-plan-clear')));
      await _settle(tester);
      expect(api.patched.last['routes'], isEmpty);
      expect(find.byKey(const ValueKey('veh-plan-set')), findsOneWidget);
      final ex = tester.takeException();
      expect(ex, isNull, reason: ex is FlutterError ? ex.toStringDeep() : '$ex');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no tile provider configured -> tile-free canvas', (tester) async {
      _phone(tester, height: 3000);
      await tester.pumpWidget(_app(const VehicleTrackerScreen(trackerId: 7), _FakeVehApi(),
          lang: 'bn', dark: true, scale: 2.0));
      await _settle(tester, 12);
      expect(find.byType(FlutterMap), findsNothing);
      expect(find.byType(RouteCanvas), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
