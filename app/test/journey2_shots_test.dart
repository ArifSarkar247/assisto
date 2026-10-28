// journey2: Safe Journey screenshots (bn/en x light/dark, plus 200% text in
// Bangla) of the start form (empty + filled), the live trip and the watcher
// list (empty + filled). Writes PNGs to $ASSISTO_SHOT_DIR only when it is
// set; otherwise it just renders every state (smoke: no exception, no
// overflow).
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
import 'package:assisto/models.dart';
import 'package:assisto/screens/journey_live_screen.dart';
import 'package:assisto/screens/journey_start_screen.dart';
import 'package:assisto/screens/journey_watch_screen.dart';
import 'package:assisto/services/journey_tracker.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'app_fonts.dart';

final _out = Platform.environment['ASSISTO_SHOT_DIR'];

/// A fake server: plain maps only (never mocks whose result gets encoded).
class _ShotApi extends ApiClient {
  _ShotApi() {
    token = 'shot-token';
  }
  Map<String, dynamic> active = {};
  Map<String, dynamic> circle = {'results': []};
  List<Map<String, dynamic>> places = [];
  List<Map<String, dynamic>> watching = [];
  Map<String, dynamic> vehConfig = {'map': {'tile_url': ''}};

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/journey/active') return active;
    if (path == '/circle/members') return circle;
    if (path == '/journey/places') return {'places': places};
    if (path == '/journey/watching') return {'journeys': watching};
    if (path.startsWith('/vehicle/config')) return vehConfig;
    if (path.startsWith('/journey/geocode')) {
      return {'available': false, 'results': const []};
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    if (path.endsWith('/location')) {
      return {'status': 'active', 'overdue_state': 'on_time', 'accepted': 1};
    }
    return {'ok': true};
  }
}

String _n(String lang, String bn, String en) => lang == 'bn' ? bn : en;

Map<String, dynamic> _activeTrip(String lang) => {
      'id': 5,
      'status': 'active',
      'destination': {
        'name': _n(lang, 'বাসা', 'Home'),
        'lat': 23.7806,
        'lng': 90.4070,
      },
      'eta': DateTime.now().add(const Duration(minutes: 35)).toIso8601String(),
      'pin_required': false,
      'extend_left': 6,
      'mode': 'cng',
      'vehicle': {
        'plate': 'DHAKA METRO THA 11-2233',
        'mode': 'cng',
        'driver_name': _n(lang, 'রহিম', 'Rahim'),
      },
      'web_link': 'https://lifeassisto.com/j/5.1.x',
    };

class _Spec {
  final _ShotApi Function(String lang) api;
  final Widget Function() screen;
  final bool pushed; // opened over a dummy home (live screen pops on end)
  final Size size;
  const _Spec(this.api, this.screen,
      {this.pushed = false, this.size = const Size(360, 800)});
}

JourneyTracker? _liveTracker;

final Map<String, _Spec> _specs = {
  'j2_start_empty': _Spec((l) => _ShotApi(), () => const JourneyStartScreen(),
      size: const Size(360, 1400)),
  'j2_start_filled': _Spec(
      (l) => _ShotApi()
        ..circle = {
          'results': [
            {'id': 7, 'name': _n(l, 'আম্মু', 'Mum'), 'phone': '01711000002', 'state': 'accepted'},
            {'id': 8, 'name': _n(l, 'রিনা', 'Rina'), 'phone': '01711000003', 'state': 'accepted'},
          ]
        }
        ..places = [
          {'id': 1, 'label': 'home', 'name': _n(l, 'বাসা', 'Home'), 'lat': 23.78, 'lng': 90.40},
          {'id': 2, 'label': 'school', 'name': _n(l, 'স্কুল', 'School'), 'lat': 23.75, 'lng': 90.39},
        ],
      () => const JourneyStartScreen(),
      size: const Size(360, 1600)),
  'j2_live': _Spec((l) => _ShotApi()..active = _activeTrip(l), () {
    _liveTracker = JourneyTracker(
        useService: false,
        position: () async => (lat: 23.7650, lng: 90.3900),
        battery: () async => 64);
    return JourneyLiveScreen(journeyId: 5, tracker: _liveTracker);
  }, pushed: true, size: const Size(360, 1300)),
  'j2_watch_empty': _Spec((l) => _ShotApi(), () => const JourneyWatchScreen()),
  'j2_watch_filled': _Spec(
      (l) => _ShotApi()
        ..watching = [
          {
            'id': 1, 'name': _n(l, 'রিনা', 'Rina'), 'status': 'active', 'sos': false,
            'destination': _n(l, 'বাসা', 'Home'), 'lat': 23.765, 'lng': 90.39,
            'fix_age_s': 40, 'battery': 52, 'url': 'https://lifeassisto.com/j/1',
            'eta': DateTime.now().add(const Duration(minutes: 20)).toIso8601String(),
            'distance_m': 2350,
            'ride': {'plate': 'DHAKA METRO THA 11-2233', 'mode': 'cng',
                     'driver_name': _n(l, 'রহিম', 'Rahim')},
          },
          {
            'id': 2, 'name': _n(l, 'তুলি', 'Tuli'), 'status': 'active', 'sos': false,
            'destination': '', 'lat': 23.7, 'lng': 90.4, 'fix_age_s': 1800,
            'overdue_state': 'alert', 'url': 'https://lifeassisto.com/j/2',
          },
          {
            'id': 3, 'name': _n(l, 'আব্বু', 'Dad'), 'status': 'arrived', 'sos': false,
            'destination': _n(l, 'অফিস', 'Office'), 'url': '',
          },
        ],
      () => const JourneyWatchScreen()),
};

Future<void> _shoot(WidgetTester tester, String name, _Spec spec, String lang,
    Brightness b, double scale) async {
  SharedPreferences.setMockInitialValues({});
  Settings.resetForTest();
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  m.setMockMethodCallHandler(const MethodChannel('flutter.baseflow.com/geolocator'),
      (call) async => call.method == 'checkPermission' ? 2 : null);
  addTearDown(() => m.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/geolocator'), null));
  await tester.binding.setSurfaceSize(spec.size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final api = spec.api(lang);
  final nav = GlobalKey<NavigatorState>();
  final key = GlobalKey();
  final app = AppState()
    ..api = api
    ..user = AppUser(
        id: 1, name: 'Me', phone: '01712345678', email: '',
        autonomyLevel: 2, language: lang)
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
        themeMode: b == Brightness.light ? ThemeMode.light : ThemeMode.dark,
        builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: spec.pushed ? const Scaffold(body: SizedBox()) : spec.screen(),
      ),
    ),
  ));
  if (spec.pushed) {
    unawaited(nav.currentState!.push(MaterialPageRoute(builder: (_) => spec.screen())));
  }
  for (var i = 0; i < 14; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
  final err = tester.takeException(); // checked after the shot is saved
  if (_out != null) {
    final rb = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final img = await tester.runAsync(() => rb.toImage(pixelRatio: 2)) as ui.Image;
    final bytes =
        await tester.runAsync(() => img.toByteData(format: ui.ImageByteFormat.png));
    Directory(_out!).createSync(recursive: true);
    final tag = scale > 1 ? '_x2' : '';
    File('$_out/${name}_${lang}_${b.name}$tag.png')
        .writeAsBytesSync(bytes!.buffer.asUint8List());
    img.dispose();
  }
  await _liveTracker?.stop();
  _liveTracker = null;
  await tester.pumpWidget(const SizedBox()); // drop refresh timers
  expect(err, isNull);
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await loadAppFonts();
    final root = Platform.environment['FLUTTER_ROOT'] ??
        '${Platform.environment['HOME']}/assisto/tools/flutter';
    final icons =
        File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    if (icons.existsSync()) {
      final l = FontLoader('MaterialIcons')
        ..addFont(icons.readAsBytes().then((b) => ByteData.view(b.buffer)));
      await l.load();
    }
  });
  for (final e in _specs.entries) {
    for (final lang in ['bn', 'en']) {
      for (final b in [Brightness.light, Brightness.dark]) {
        testWidgets('shot ${e.key} $lang ${b.name}',
            (tester) => _shoot(tester, e.key, e.value, lang, b, 1.0));
      }
    }
    testWidgets('shot ${e.key} bn light 200% text',
        (tester) => _shoot(tester, e.key, e.value, 'bn', Brightness.light, 2.0));
  }
}
