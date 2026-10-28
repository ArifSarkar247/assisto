// veh100: vehicle tracking to best-in-market (owner order 28 Oct), app side.
//  * pure map helpers: speed bands / coloured runs, gliding interpolation
//    (shortest heading turn), bearing;
//  * VehMap: live marker glides (no exception, no jump) between two fixes;
//  * VehicleReportScreen: day + month, score card, empty state; bn + en, dark,
//    200 % text — no overflow;
//  * VehShareSheet: make a link (shown once), list + turn off;
//  * VehSetupView: brand steps from the server, waiting -> connected -> first
//    location;
//  * VehicleTrackerScreen: engine cut button ONLY when the server flag is on
//    (honest "switched off" note otherwise), share / report / driver entries;
//  * VehicleDriversScreen: list, assign who drives now.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/vehicle_drivers_screen.dart';
import 'package:assisto/screens/vehicle_report_screen.dart';
import 'package:assisto/screens/vehicle_tracker_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/vehicle/route_canvas.dart';
import 'package:assisto/vehicle/veh_map.dart';
import 'package:assisto/vehicle/veh_setup.dart';
import 'package:assisto/vehicle/veh_share_sheet.dart';

final _png = Uint8List.fromList(base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='));

class _MemTiles extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) => MemoryImage(_png);
}

const _tiles = VehMapConfig(
    tileUrl: 'https://tiles.test/{z}/{x}/{y}.png?key=k',
    attribution: '© MapTiler © OpenStreetMap contributors');

class _Api extends ApiClient {
  _Api() : super.detached('t');
  final List<Map<String, dynamic>> posted = [];
  final List<String> deleted = [];
  bool cutEnabled = false;
  bool command = true;
  String state = 'paired';
  bool hasFix = true;
  double reportKm = 42.5;
  List<Map<String, dynamic>> links = [];
  List<Map<String, dynamic>> drivers = [
    {'id': 11, 'name': 'Karim', 'phone': '01711000000', 'licence_expiry': '2026-11-10'},
    {'id': 12, 'name': 'Rahim'},
  ];

  Map<String, dynamic> tracker() => {
        'id': 7,
        'name': 'Corolla',
        'imei': '359339077003915',
        'protocol': 'h02',
        'state': state,
        'online': true,
        'is_owner': true,
        'engine_cut_enabled': cutEnabled,
        'relay_cut': false,
        'pair_expires_at':
            DateTime.now().toUtc().add(const Duration(minutes: 8)).toIso8601String(),
        'access': {'view': true, 'command': command, 'manage': true},
        'driver': {'driver_id': 11, 'driver_name': 'Karim'},
        'last_seen_at': DateTime.now().toUtc().toIso8601String(),
        'live': hasFix
            ? {'lat': 23.7808, 'lng': 90.4300, 'speed_kmh': 0, 'course': 90, 'moving': false,
               'at': DateTime.now().toUtc().toIso8601String(), 'fix_age_s': 5}
            : null,
        'settings': {'geofences': [], 'routes': [], 'speed_limit_kmh': 60,
                     'alert_prefs': {'silent_min': 30}},
      };

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/vehicle/config') return {'map': {}};
    if (path.contains('/route')) {
      final now = DateTime.now().toUtc();
      final pts = [
        for (var i = 0; i < 30; i++)
          {'at': now.subtract(Duration(minutes: 60 - i)).toIso8601String(),
           'lat': 23.7808, 'lng': 90.4130 + i * 0.0006, 'speed_kmh': i < 20 ? 40 : 75}
      ];
      return {'points': pts, 'trips': [], 'stops': [], 'total_km': 1.9, 'moving_s': 1800,
              'max_speed_kmh': 75};
    }
    if (path.endsWith('/commands')) return {'commands': []};
    if (path.contains('/report')) {
      final month = path.contains('period=month');
      final tot = {'km': reportKm, 'trips': reportKm > 0 ? 3 : 0, 'moving_s': 5400, 'idle_s': 600,
                   'max_kmh': 82.0, 'overspeed_s': 240, 'harsh_brake': 2, 'harsh_accel': 1,
                   'score': reportKm > 0 ? 78 : null, 'coverage': 0.4, 'days_driven': 9};
      return {
        'period': month ? 'month' : 'day', 'totals': tot, 'band': 'ok',
        'speed_limit_kmh': 80, 'limit_default': true, 'in_retention': true,
        'trips': [
          {'start': '2026-10-28T03:00:00Z', 'end': '2026-10-28T03:40:00Z', 'km': 21.0,
           'max_kmh': 82.0}
        ],
        'drivers': [
          {'driver_id': 11, 'name': 'Karim', 'km': 30.0, 'score': 80}
        ],
        'days': [
          {'day': '2026-10-27', 'km': 30.0, 'trips': 2, 'score': 80},
          {'day': '2026-10-28', 'km': 12.5, 'trips': 1, 'score': 74},
        ],
      };
    }
    if (path.endsWith('/share')) return {'links': links, 'hours': [1, 4, 8, 24, 72]};
    if (path.startsWith('/vehicle/setup-guide')) {
      return {
        'protocol': 'h02', 'id_hint': 'id_10', 'reply_ok': 'SET OK',
        'steps': [
          {'sms': '8030000 gpinternet', 'what': 'apn'},
          {'sms': '8040000 16.4.105.173 5023', 'what': 'server'},
          {'sms': '7100000', 'what': 'gprs_on'},
        ],
      };
    }
    if (path.startsWith('/vehicle/drivers/')) {
      return {'name': 'Karim', 'totals': {'km': 0}, 'vehicles': []};
    }
    return tracker();
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) async {
    posted.add({'path': path, ...body});
    if (path.endsWith('/share')) {
      final l = {'id': links.length + 1, 'label': body['label'], 'state': 'active',
                 'expires_at': DateTime.now().toUtc().add(const Duration(hours: 8)).toIso8601String(),
                 'views': 0};
      links = [...links, l];
      return {'ok': true, 'link': {...l, 'url': 'https://lifeassisto.com/v/abc123'}};
    }
    return {'ok': true, 'current': null};
  }

  @override
  Future<Map<String, dynamic>> deleteJson(String path) async {
    deleted.add(path);
    links = [for (final l in links) {...l, 'state': 'revoked'}];
    return {'ok': true};
  }

  @override
  Future<List<Map<String, dynamic>>> listItems(String path) async => drivers;
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
  tester.view.physicalSize = Size(360 * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void _noErrors(WidgetTester tester) {
  final ex = tester.takeException();
  expect(ex, isNull, reason: ex is FlutterError ? ex.toStringDeep() : '$ex');
}

void main() {
  late AppLocalizations en, bn;
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    bn = await AppLocalizations.delegate.load(const Locale('bn'));
  });
  setUp(() {
    VehMap.debugTileProvider = _MemTiles();
    VehMapConfig.debugSet(null);
  });
  tearDown(() => VehMap.debugTileProvider = null);

  group('map helpers (pure)', () {
    test('speed bands and coloured runs share their joints', () {
      expect(vehSpeedBand(30, 60), 0);
      expect(vehSpeedBand(50, 60), 1);
      expect(vehSpeedBand(61, 60), 2);
      expect(vehSpeedBand(85, 0), 2); // no limit -> 80 km/h
      final route = [
        for (final s in [10, 20, 30, 70, 70, 20]) GeoPt(23.78, 90.41, speed: s.toDouble())
      ];
      final runs = vehSpeedRuns(route, 60);
      expect(runs.map((r) => r.band), [0, 2, 0]);
      expect(runs.fold<int>(0, (n, r) => n + r.points.length), route.length + 2);
      expect(vehSpeedRuns(route.take(1).toList(), 60), isEmpty);
    });

    test('glide interpolation takes the short way round', () {
      const a = GeoPt(23.0, 90.0, speed: 0, course: 350);
      const b = GeoPt(23.1, 90.2, speed: 40, course: 10);
      final m = vehLerp(a, b, 0.5);
      expect(m.lat, closeTo(23.05, 1e-9));
      expect(m.lng, closeTo(90.1, 1e-9));
      expect(m.speed, 20);
      expect(m.course, closeTo(0, 1e-9));
      expect(vehLerp(a, b, 2).lat, b.lat); // clamped
    });

    test('bearing', () {
      expect(vehBearing(const GeoPt(23.78, 90.41), const GeoPt(23.79, 90.41)), closeTo(0, 0.5));
      expect(vehBearing(const GeoPt(23.78, 90.41), const GeoPt(23.78, 90.42)), closeTo(90, 0.5));
    });
  });

  testWidgets('VehMap: live marker glides between fixes, polygons draw', (tester) async {
    _phone(tester);
    Widget map(GeoPt live) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 360,
              child: VehMap(
                config: _tiles,
                route: [
                  for (var i = 0; i < 10; i++) GeoPt(23.78, 90.41 + i * 0.001, speed: i * 10.0)
                ],
                live: live,
                speedColours: true,
                speedLimitKmh: 60,
                fences: const [
                  GeoFenceView(23.78, 90.41, 300, 'Home'),
                  GeoFenceView(23.785, 90.415, 500, 'Office', points: [
                    GeoPt(23.78, 90.41), GeoPt(23.78, 90.42), GeoPt(23.79, 90.42)
                  ]),
                ],
                semanticsLabel: 'map',
              ),
            ),
          ),
        );
    await tester.pumpWidget(map(const GeoPt(23.78, 90.41, course: 90)));
    await _settle(tester, 4);
    expect(find.byKey(const ValueKey('veh-fence-polygons')), findsOneWidget);
    await tester.pumpWidget(map(const GeoPt(23.781, 90.412, course: 45)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('veh-live-marker')), findsOneWidget);
    await tester.pump(VehMap.glide);
    await _settle(tester, 2);
    _noErrors(tester);
    await tester.pumpWidget(const SizedBox());
  });

  group('VehicleReportScreen', () {
    for (final v in const [('en', false, 1.0), ('bn', true, 2.0)]) {
      testWidgets('day + month, score card (${v.$1}, dark ${v.$2}, x${v.$3})', (tester) async {
        _phone(tester, height: 3200);
        final api = _Api();
        await tester.pumpWidget(_app(const VehicleReportScreen(trackerId: 7, name: 'Corolla'),
            api, lang: v.$1, dark: v.$2, scale: v.$3));
        await _settle(tester, 10);
        final t = v.$1 == 'en' ? en : bn;
        expect(find.text(t.v100ScoreTitle), findsOneWidget);
        expect(find.text(t.v100ScoreLimited), findsOneWidget); // coverage 0.4: honest
        if (v.$3 == 1.0) expect(find.text(t.v100ByDriver), findsOneWidget);
        await tester.tap(find.text(t.v100ReportMonth));
        await _settle(tester, 10);
        expect(find.text(t.v100ReportDays), findsOneWidget);
        expect(api.posted, isEmpty);
        _noErrors(tester);
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('honest empty state', (tester) async {
      _phone(tester);
      final api = _Api()..reportKm = 0;
      await tester.pumpWidget(_app(const VehicleReportScreen(trackerId: 7), api));
      await _settle(tester, 10);
      expect(find.text(en.v100ReportEmptyTitle), findsOneWidget);
      _noErrors(tester);
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('VehShareSheet: make a link, shown once, then turn it off', (tester) async {
    _phone(tester);
    final api = _Api();
    await tester.pumpWidget(_app(const Scaffold(body: VehShareSheet(trackerId: 7)), api,
        lang: 'bn', scale: 1.3));
    await _settle(tester);
    expect(find.text(bn.v100ShareNone), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('veh-share-create')));
    await _settle(tester);
    expect(api.posted.single['hours'], 8);
    expect(find.text('https://lifeassisto.com/v/abc123'), findsOneWidget);
    expect(find.text(bn.v100ShareTurnOff), findsOneWidget);
    await tester.ensureVisible(find.text(bn.v100ShareTurnOff));
    await tester.tap(find.text(bn.v100ShareTurnOff));
    await _settle(tester);
    expect(api.deleted.single, '/vehicle/trackers/7/share/1');
    _noErrors(tester);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('VehSetupView: SMS steps, waiting -> first location', (tester) async {
    _phone(tester, height: 3000);
    final api = _Api()
      ..state = 'pending'
      ..hasFix = false;
    var closed = false;
    await tester.pumpWidget(_app(
        Scaffold(
          body: SingleChildScrollView(
            child: VehSetupView(
                tracker: api.tracker(),
                brand: 'sinotrack',
                operator: 'gp',
                simNumber: '01711222333',
                onClose: () => closed = true),
          ),
        ),
        api));
    await _settle(tester);
    expect(find.text(en.v100SetupWaiting), findsOneWidget);
    expect(find.text('8040000 16.4.105.173 5023'), findsOneWidget);
    expect(find.text(en.v100SetupSendSms), findsNWidgets(3));
    expect(find.text(en.v100SetupIdHint10), findsOneWidget);
    api
      ..state = 'paired'
      ..hasFix = true;
    await tester.pump(const Duration(seconds: 5));
    await _settle(tester);
    expect(find.text(en.v100SetupFirstFix), findsOneWidget);
    await tester.tap(find.text(en.vehDone));
    expect(closed, isTrue);
    _noErrors(tester);
    await tester.pumpWidget(const SizedBox());
  });

  group('VehicleTrackerScreen', () {
    testWidgets('engine cut hidden while the flag is off (honest note)', (tester) async {
      _phone(tester, height: 4000);
      final api = _Api()..cutEnabled = false;
      await tester.pumpWidget(_app(const VehicleTrackerScreen(trackerId: 7), api));
      await _settle(tester, 12);
      expect(find.byKey(const ValueKey('veh-cut')), findsNothing);
      expect(find.text(en.v100ErrCutOff), findsOneWidget);
      expect(find.text(en.vehRestoreCta), findsOneWidget); // restore always possible
      expect(find.byKey(const ValueKey('veh-share')), findsOneWidget);
      expect(find.byKey(const ValueKey('veh-report')), findsOneWidget);
      expect(find.text(en.v100DriverNow('Karim')), findsOneWidget);
      expect(find.textContaining(en.v100LegendCalm, findRichText: true), findsOneWidget);
      _noErrors(tester);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('engine cut shown when the flag is on (bn, 2x)', (tester) async {
      _phone(tester, height: 5000);
      final api = _Api()..cutEnabled = true;
      await tester.pumpWidget(
          _app(const VehicleTrackerScreen(trackerId: 7), api, lang: 'bn', scale: 2.0));
      await _settle(tester, 12);
      expect(find.byKey(const ValueKey('veh-cut')), findsOneWidget);
      expect(find.text(bn.v100CutSafetyNote), findsOneWidget);
      _noErrors(tester);
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('VehicleDriversScreen: list + assign who drives now', (tester) async {
    _phone(tester);
    final api = _Api();
    await tester.pumpWidget(_app(
        const VehicleDriversScreen(trackerId: 7, canAssign: true, currentDriverId: 11), api));
    await _settle(tester);
    expect(find.text('Rahim'), findsWidgets);
    await tester.tap(find.widgetWithText(RadioListTile<int?>, 'Rahim'));
    await _settle(tester);
    expect(api.posted.single['path'], '/vehicle/trackers/7/driver');
    expect(api.posted.single['driver_id'], 12);
    _noErrors(tester);
    await tester.pumpWidget(const SizedBox());
  });
}
