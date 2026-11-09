// sjduring: Safe Journey V2 DURING screenshots (bn/en x light/dark, plus
// 200% text in Bangla): the private "Changed route?" screen, the near-
// destination stop ask, the traveller's live states + "also watching", the
// PIN on an abnormal arrival, the watcher board (active with count + amber /
// red + near note; finished with the PIN badges) and the Family tile.
// Writes PNGs to $ASSISTO_SHOT_DIR only when set; otherwise renders every
// state (smoke: no exception, no overflow). Made-up people and places.
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
import 'package:assisto/maps/address_resolver.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/journey_live_screen.dart';
import 'package:assisto/screens/journey_watch_screen.dart';
import 'package:assisto/screens/safe_journey/sj_private_ask_screen.dart';
import 'package:assisto/screens/safe_journey/sj_watch_board.dart';
import 'package:assisto/services/journey_tracker.dart';
import 'package:assisto/services/oem_guide.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'app_fonts.dart';

final _out = Platform.environment['ASSISTO_SHOT_DIR'];

String _n(String lang, String bn, String en) => lang == 'bn' ? bn : en;

/// A fake server: plain maps only (never mocks whose result gets encoded).
class SjdApi extends ApiClient {
  SjdApi(this.lang) {
    token = 'shot-token';
  }
  final String lang;
  Map<String, dynamic> active = {};
  Map<String, dynamic> during = {};
  Map<String, dynamic> board = {'count': 0, 'active': [], 'finished': []};
  List<Map<String, dynamic>> watching = [];
  final List<String> posts = [];
  final List<Map<String, dynamic>> bodies = [];
  List<Map<String, dynamic>> pinAnswers = [];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/journey/active') return active;
    if (path.endsWith('/during')) return during;
    if (path == '/journey/watch-board') return board;
    if (path == '/journey/watching') return {'journeys': watching};
    if (path.startsWith('/journey/geocode')) return {'available': false, 'results': const []};
    if (path.startsWith('/maps/reverse')) return {'state': 'off', 'address': ''};
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) async {
    posts.add(path);
    bodies.add(body);
    if (path.endsWith('/location')) {
      return {'status': 'active', 'overdue_state': 'on_time', 'accepted': 1};
    }
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> postJsonRaw(String path, [Map<String, dynamic> body = const {}]) async {
    posts.add(path);
    bodies.add(body);
    if (path.endsWith('/arrive-pin') && pinAnswers.isNotEmpty) return pinAnswers.removeAt(0);
    return {'ok': true, '_status': 200};
  }
}

Map<String, dynamic> sjdTrip(String l) => {
      'id': 5,
      'status': 'active',
      'destination': {'name': _n(l, 'গাজীপুর চৌরাস্তা', 'Gazipur Chowrasta'), 'lat': 23.99, 'lng': 90.42},
      'eta': DateTime.now().add(const Duration(minutes: 35)).toIso8601String(),
      'pin_required': true,
      'extend_left': 6,
      'mode': 'local_bus',
      'vehicle': {'mode': 'local_bus'},
    };

Map<String, dynamic> sjdDuring({String state = 'slow', Map<String, dynamic>? ask,
        Map<String, dynamic>? pinWait, bool night = false, int? dist = 8400}) =>
    {
      'id': 5, 'status': 'active', 'state': state, 'state_minutes': state == 'stopped' ? 12 : null,
      'distance_m': dist, 'battery': 64, 'near_note': state == 'nearly',
      'night': night, 'pin_configured': true, 'arrive_always': false,
      'extend_default': 40, 'earliest_at': null,
      if (ask != null) 'ask': ask,
      if (pinWait != null) 'pin_wait': pinWait,
    };

Map<String, dynamic> sjdAskRoute() => {
      'id': 'off_route:1', 'kind': 'off_route', 'at': DateTime.now().toIso8601String(),
      'from': {'lat': 23.80, 'lng': 90.42}, 'to': {'lat': 23.86, 'lng': 90.47},
    };

List<Map<String, dynamic>> sjdBoardActive(String l) => [
      {'id': 11, 'name': _n(l, 'রিনা', 'Rina'), 'mode': 'cng', 'status': 'active', 'state': 'moving',
        'distance_m': 5200, 'level': '', 'badges': [], 'near_note': false,
        'window_from': DateTime.now().add(const Duration(minutes: 20)).toIso8601String(),
        'window_to': DateTime.now().add(const Duration(minutes: 45)).toIso8601String()},
      {'id': 12, 'name': _n(l, 'বাবা', 'Baba'), 'mode': 'long_bus', 'status': 'active', 'state': 'nearly',
        'state_minutes': 18, 'distance_m': 700, 'level': '', 'badges': [], 'near_note': true},
      {'id': 13, 'name': _n(l, 'তানিয়া', 'Tania'), 'mode': 'walk', 'status': 'active', 'state': 'stopped',
        'state_minutes': 27, 'level': 'amber', 'badges': []},
      {'id': 14, 'name': _n(l, 'আম্মু', 'Ammu'), 'mode': 'car', 'status': 'active', 'state': 'phone_off',
        'battery': 4, 'why': 'battery', 'level': 'amber', 'badges': []},
      {'id': 15, 'name': _n(l, 'সাকিব', 'Sakib'), 'mode': 'ride', 'status': 'active', 'state': 'nearly',
        'level': 'red', 'badges': [], 'audio': true},
    ];

List<Map<String, dynamic>> sjdBoardFinished(String l) => [
      {'id': 21, 'name': _n(l, 'রিনা', 'Rina'), 'mode': 'cng', 'status': 'arrived', 'state': 'arrived',
        'badges': ['pin_ok']},
      {'id': 22, 'name': _n(l, 'বাবা', 'Baba'), 'mode': 'car', 'status': 'arrived', 'state': 'arrived',
        'badges': ['fast_pin', 'pin_ok']},
    ];

List<Map<String, dynamic>> sjdWatching(String l) => [
      for (final c in [...sjdBoardActive(l), ...sjdBoardFinished(l)])
        {
          'id': c['id'], 'name': c['name'], 'status': c['status'] == 'active' ? 'active' : 'arrived',
          'sos': c['level'] == 'red', 'destination': _n(l, 'বাসা', 'Home'),
          'overdue_state': 'alert', // late on purpose: V2 never shows "late" in red
          'fix_age_s': 40, 'lat': 23.78, 'lng': 90.41, 'url': 'https://lifeassisto.com/j/1.x',
          if (c['distance_m'] != null) 'distance_m': c['distance_m'],
        }
    ];

class _Oem implements OemGuideNative {
  const _Oem();
  @override
  Future<OemInfo?> info() async => const OemInfo(
      manufacturer: 'google', brand: 'google', model: 'Pixel', batteryOptIgnored: true,
      bgRestricted: false);
  @override
  Future<OemOpen> available(String step) async => OemOpen.none;
  @override
  Future<OemOpen> open(String step) async => OemOpen.none;
}

class _Spec {
  final SjdApi Function(String lang) api;
  final Widget Function() screen;
  final bool pushed;
  final Size size;
  const _Spec(this.api, this.screen, {this.pushed = false, this.size = const Size(360, 900)});
}

JourneyTracker? _tracker;

Widget _live() {
  _tracker = JourneyTracker(
      useService: false, position: () async => (lat: 23.80, lng: 90.42), battery: () async => 64);
  return JourneyLiveScreen(journeyId: 5, tracker: _tracker, oem: const _Oem());
}

final Map<String, _Spec> _specs = {
  'sjd_ask_route': _Spec((l) => SjdApi(l),
      () => SjPrivateAskScreen(journeyId: 5, ask: sjdAskRoute()), size: const Size(360, 1100)),
  'sjd_ask_near': _Spec(
      (l) => SjdApi(l),
      () => SjPrivateAskScreen(journeyId: 5, ask: {
            'id': 'near_stop:1', 'kind': 'near_stop', 'at': DateTime.now().toIso8601String(),
            'minutes': 31}),
      size: const Size(360, 1100)),
  'sjd_live_slow': _Spec(
      (l) => SjdApi(l)
        ..active = sjdTrip(l)
        ..during = sjdDuring(night: true)
        ..board = {'count': 1, 'active': [sjdBoardActive(l).first], 'finished': []},
      _live,
      pushed: true,
      size: const Size(360, 1600)),
  'sjd_live_nearly': _Spec(
      (l) => SjdApi(l)
        ..active = sjdTrip(l)
        ..during = sjdDuring(state: 'nearly', dist: 600),
      _live,
      pushed: true,
      size: const Size(360, 1500)),
  'sjd_live_pin': _Spec(
      (l) => SjdApi(l)
        ..active = sjdTrip(l)
        ..during = sjdDuring(state: 'nearly', dist: 90, pinWait: {
          'why': ['too_early'], 'at': DateTime.now().toIso8601String()}),
      _live,
      pushed: true,
      size: const Size(360, 1100)),
  'sjd_watch_board': _Spec(
      (l) => SjdApi(l)
        ..watching = sjdWatching(l)
        ..board = {'count': 5, 'active': sjdBoardActive(l), 'finished': sjdBoardFinished(l)},
      () => const JourneyWatchScreen(),
      size: const Size(360, 3400)),
  'sjd_family_tile': _Spec(
      (l) => SjdApi(l)..board = {'count': 2, 'active': sjdBoardActive(l).take(3).toList(), 'finished': []},
      () => const Scaffold(body: Padding(padding: EdgeInsets.all(16), child: SjActiveJourneysTile())),
      size: const Size(360, 400)),
};

Future<void> _shoot(WidgetTester tester, String name, _Spec spec, String lang,
    Brightness b, double scale) async {
  SharedPreferences.setMockInitialValues({});
  Settings.resetForTest();
  AddressResolver.debugPhone = (lat, lng, l) async => lat < 23.83
      ? (l == 'bn' ? 'বাড্ডা' : 'Badda')
      : (l == 'bn' ? 'উত্তরা' : 'Uttara');
  addTearDown(() => AddressResolver.debugPhone = null);
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
        id: 1, name: 'Me', phone: '01712345678', email: '', autonomyLevel: 2, language: lang)
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
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
  final err = tester.takeException();
  if (_out != null) {
    final rb = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final img = await tester.runAsync(() => rb.toImage(pixelRatio: 2)) as ui.Image;
    final bytes = await tester.runAsync(() => img.toByteData(format: ui.ImageByteFormat.png));
    Directory(_out!).createSync(recursive: true);
    final tag = scale > 1 ? '_x2' : '';
    File('$_out/${name}_${lang}_${b.name}$tag.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    img.dispose();
  }
  await _tracker?.stop();
  _tracker = null;
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
