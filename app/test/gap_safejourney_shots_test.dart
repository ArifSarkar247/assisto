// gap-safejourney: gallery shots of the changed Safe Journey screens —
// the start screen's "Going to Office?" card and the watcher card with the
// ride photo — Bangla / English × light / dark. Made-up people and places.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/maps/maps_sdk.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/journey_start_screen.dart';
import 'package:assisto/screens/journey_watch_screen.dart';
import 'package:assisto/services/journey_habits.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/vehicle/veh_map.dart' show VehMapConfig;

import 'app_fonts.dart';

final _out = Platform.environment['ASSISTO_SHOT_DIR'];

class _Api extends ApiClient {
  _Api(this.lang) {
    token = 'shot-token';
  }
  final String lang;
  String _n(String bn, String en) => lang == 'bn' ? bn : en;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/journey/active') return {};
    if (path == '/circle/members') {
      return {
        'results': [
          {'id': 7, 'name': _n('আম্মু', 'Ammu'), 'phone': '01711000002', 'state': 'accepted'},
          {'id': 8, 'name': _n('রিনা', 'Rina'), 'phone': '01711000003', 'state': 'accepted'},
        ]
      };
    }
    if (path == '/journey/places') return {'places': []};
    if (path == '/journey/watching') {
      return {
        'journeys': [
          {
            'id': 11, 'name': _n('রিনা', 'Rina'), 'status': 'active', 'sos': false,
            'destination': _n('অফিস', 'Office'), 'fix_age_s': 30, 'lat': 23.79, 'lng': 90.41,
            'battery': 64, 'ride': {'plate': 'DHAKA METRO-GA 11-2345', 'mode': 'cng'},
            'ride_photo': '/api/v1/m/journey/j11.jpg?e=1&s=x',
          },
        ]
      };
    }
    if (path == '/journey/watch-board') return {'count': 1, 'active': [], 'finished': []};
    if (path == '/maps/status') return {'ready': true, 'min_chars': 2, 'debounce_ms': 300, 'places': true};
    if (path.startsWith('/maps/eta')) return {'state': 'none', 'gmaps_url': ''};
    if (path.startsWith('/maps/reverse')) return {'state': 'none', 'address': ''};
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) async =>
      {'ok': true};
}

String _pastTrips(String lang) {
  final now = DateTime.now();
  return jsonEncode([
    for (final w in [7, 14])
      JourneyHabitTrip(
              fLat: 23.78, fLng: 90.42, dLat: 23.7925, dLng: 90.4078,
              name: lang == 'bn' ? 'অফিস' : 'Office', kind: 'office', mode: 'cng',
              at: now.subtract(Duration(days: w)))
          .toJson()
  ]);
}

Future<void> _shoot(WidgetTester tester, String name, String lang, bool dark, Widget screen,
    {double h = 1500}) async {
  SharedPreferences.setMockInitialValues({JourneyHabits.kTripsKey: _pastTrips(lang)});
  Settings.resetForTest();
  VehMapConfig.debugSet(const VehMapConfig());
  MapsSdk.debugAvailable = false;
  addTearDown(() {
    VehMapConfig.debugSet(null);
    MapsSdk.debugAvailable = null;
  });
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  m.setMockMethodCallHandler(const MethodChannel('flutter.baseflow.com/geolocator'),
      (call) async => switch (call.method) {
            'checkPermission' => 2,
            'getLastKnownPosition' => {
                'latitude': 23.78, 'longitude': 90.42, 'timestamp': 0, 'accuracy': 5.0,
                'altitude': 0.0, 'heading': 0.0, 'speed': 0.0, 'speed_accuracy': 0.0,
              },
            _ => null,
          });
  addTearDown(() => m.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/geolocator'), null));
  await tester.binding.setSurfaceSize(Size(360, h));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final nav = GlobalKey<NavigatorState>();
  final key = GlobalKey();
  final app = AppState()
    ..api = _Api(lang)
    ..user = AppUser(id: 1, name: 'Me', phone: '01712345678', email: '', autonomyLevel: 2, language: lang)
    ..locale = Locale(lang)
    ..loading = false;
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: app,
    child: RepaintBoundary(
      key: key,
      child: MaterialApp(
        navigatorKey: nav,
        debugShowCheckedModeBanner: false,
        locale: Locale(lang),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: AssistoTheme.light,
        darkTheme: AssistoTheme.dark,
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        home: const Scaffold(body: SizedBox()),
      ),
    ),
  ));
  unawaited(nav.currentState!.push(MaterialPageRoute(builder: (_) => screen)));
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
  final err = tester.takeException();
  if (_out != null) {
    final rb = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final img = await tester.runAsync(() => rb.toImage(pixelRatio: 2)) as ui.Image;
    final bytes = await tester.runAsync(() => img.toByteData(format: ui.ImageByteFormat.png));
    Directory(_out!).createSync(recursive: true);
    File('$_out/${name}_${lang}_${dark ? 'dark' : 'light'}.png')
        .writeAsBytesSync(bytes!.buffer.asUint8List());
    img.dispose();
  }
  await tester.pumpWidget(const SizedBox());
  expect(err, isNull);
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await loadAppFonts();
    final root = Platform.environment['FLUTTER_ROOT'] ??
        '${Platform.environment['HOME']}/assisto/tools/flutter';
    final icons = File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    if (icons.existsSync()) {
      final l = FontLoader('MaterialIcons')
        ..addFont(icons.readAsBytes().then((b) => ByteData.view(b.buffer)));
      await l.load();
    }
  });
  for (final lang in ['bn', 'en']) {
    for (final dark in [false, true]) {
      final th = dark ? 'dark' : 'light';
      testWidgets('shot gsj_start_usual $lang $th', (tester) async {
        await _shoot(tester, 'gsj_start_usual', lang, dark, const JourneyStartScreen(), h: 900);
      });
      testWidgets('shot gsj_watch_photo $lang $th', (tester) async {
        await _shoot(tester, 'gsj_watch_photo', lang, dark, const JourneyWatchScreen(), h: 900);
      });
    }
  }
}
