// sjp0 (owner P0 9 Nov 19:40): gallery shots of the Safe Journey V2 start
// screen and the place search typed "Gaibandha" (bn + en, light) — our own
// Bangladesh list answers, never a limit message, no 9/120 counter. The
// traveller prompt and the watcher view come from sjduring_shots_test
// (sjd_ask_route_*, sjd_watch_board_*). Writes PNGs to $ASSISTO_SHOT_DIR
// only when set. Made-up people and places.
import 'dart:async';
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
  final gets = <String>[];

  String _n(String bn, String en) => lang == 'bn' ? bn : en;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    gets.add(path);
    if (path == '/journey/active') return {};
    if (path == '/circle/members') {
      return {
        'results': [
          {'id': 7, 'name': _n('আম্মু', 'Ammu'), 'phone': '01711000002', 'state': 'accepted'},
          {'id': 8, 'name': _n('রিনা', 'Rina'), 'phone': '01711000003', 'state': 'accepted'},
        ]
      };
    }
    if (path == '/journey/places') {
      return {
        'places': [
          {'id': 1, 'kind': 'home', 'label': 'Home', 'name': _n('বাসা', 'Home'), 'lat': 23.78, 'lng': 90.42},
        ]
      };
    }
    if (path == '/maps/status') return {'ready': true, 'min_chars': 2, 'debounce_ms': 300, 'places': true};
    if (path.startsWith('/maps/search') || path.startsWith('/maps/autocomplete')) {
      // what the server answers with every Google cap used up: our own list
      return {
        'state': 'ok',
        'google': false,
        'results': [
          {'place_id': 'bd:101', 'name': _n('গাইবান্ধা', 'Gaibandha'), 'secondary': _n('রংপুর বিভাগ', 'Rangpur Division'),
           'lat': 25.33, 'lng': 89.54, 'kind': 'district', 'radius_m': 300, 'source': 'bd'},
          {'place_id': 'bd:102', 'name': _n('গাইবান্ধা সদর', 'Gaibandha Sadar'), 'secondary': _n('গাইবান্ধা', 'Gaibandha'),
           'lat': 25.32, 'lng': 89.53, 'kind': 'upazila', 'radius_m': 300, 'source': 'bd'},
          {'place_id': 'bd:103', 'name': _n('গাইবান্ধা রেলওয়ে স্টেশন', 'Gaibandha Railway Station'),
           'secondary': _n('গাইবান্ধা', 'Gaibandha'), 'lat': 25.33, 'lng': 89.55, 'kind': 'station',
           'radius_m': 400, 'source': 'bd'},
          {'place_id': 'bd:104', 'name': _n('গাইবান্ধা বাস টার্মিনাল', 'Gaibandha Bus Terminal'),
           'secondary': _n('গাইবান্ধা', 'Gaibandha'), 'lat': 25.32, 'lng': 89.54, 'kind': 'bus_terminal',
           'radius_m': 400, 'source': 'bd'},
        ],
      };
    }
    if (path.startsWith('/maps/eta')) return {'state': 'none', 'gmaps_url': ''};
    if (path.startsWith('/maps/reverse')) return {'state': 'none', 'address': ''};
    if (path.startsWith('/journey/geocode')) return {'available': true, 'results': const [], 'state': 'none'};
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) async =>
      {'ok': true};
}

Future<void> _shoot(WidgetTester tester, String name, String lang, {String? type}) async {
  SharedPreferences.setMockInitialValues({});
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
  await tester.binding.setSurfaceSize(const Size(360, 1500));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final api = _Api(lang);
  final nav = GlobalKey<NavigatorState>();
  final key = GlobalKey();
  final app = AppState()
    ..api = api
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
        themeMode: ThemeMode.light,
        home: const Scaffold(body: SizedBox()),
      ),
    ),
  ));
  unawaited(nav.currentState!.push(MaterialPageRoute(builder: (_) => const JourneyStartScreen())));
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
  if (type != null) {
    await tester.enterText(find.byKey(const ValueKey('j100_dest')), type);
    await tester.pump(const Duration(milliseconds: 400));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    // the owner's bug: suggestions appear, never a limit message or counter
    expect(find.textContaining(lang == 'bn' ? 'গাইবান্ধা' : 'Gaibandha'), findsWidgets);
    expect(find.textContaining('/120'), findsNothing);
    expect(api.gets.any((g) => g.startsWith('/maps/search')), isTrue);
  }
  final err = tester.takeException();
  if (_out != null) {
    final rb = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final img = await tester.runAsync(() => rb.toImage(pixelRatio: 2)) as ui.Image;
    final bytes = await tester.runAsync(() => img.toByteData(format: ui.ImageByteFormat.png));
    Directory(_out!).createSync(recursive: true);
    File('$_out/${name}_${lang}_light.png').writeAsBytesSync(bytes!.buffer.asUint8List());
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
    testWidgets('shot sjp0_start $lang light', (tester) => _shoot(tester, 'sjp0_start', lang));
    testWidgets('shot sjp0_search_gaibandha $lang light',
        (tester) => _shoot(tester, 'sjp0_search_gaibandha', lang,
            type: lang == 'bn' ? 'গাইবান্ধা' : 'Gaibandha'));
  }
}
