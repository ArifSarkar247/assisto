// journey2: the Safe Journey destination picker (saved Home/School/Office,
// paste a Maps link, search only when the server has a geocoder, map only
// with tiles, the honest no-pin state), select-all watchers, ride details at
// start and mid-trip, turning the shared link off, the background-sharing
// honesty card, the watcher empty state, and Bangla digits.
// Fake server returns plain maps only.
import 'dart:async';

import 'package:flutter/material.dart';
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
import 'package:assisto/services/oem_guide.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/vehicle/veh_map.dart' show VehMapConfig;
import 'package:assisto/widgets/journey_ride.dart';

class _Hit {
  final String method, path;
  final Map<String, dynamic> body;
  _Hit(this.method, this.path, this.body);
}

class _Api extends ApiClient {
  _Api() {
    token = 't';
  }
  final hits = <_Hit>[];
  Map<String, dynamic> active = {};
  Map<String, dynamic> circle = {'results': []};
  List<Map<String, dynamic>> places = [];
  List<Map<String, dynamic>> watching = [];
  bool geocoder = false;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    hits.add(_Hit('GET', path, const {}));
    if (path == '/journey/active') return active;
    if (path == '/circle/members') return circle;
    if (path == '/journey/places') return {'places': places};
    if (path == '/journey/watching') return {'journeys': watching};
    if (path.startsWith('/journey/geocode')) {
      if (!geocoder) return {'available': false, 'results': const [], 'state': 'off'};
      return {
        'available': true,
        'state': 'ok',
        'results': [
          {'name': 'Bashundhara City', 'address': 'Panthapath', 'lat': 23.7509, 'lng': 90.3901}
        ],
      };
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    hits.add(_Hit('POST', path, body));
    if (path == '/journey/parse-link') {
      if ('${body['text']}'.contains('maps')) {
        return {'ok': true, 'lat': 23.7806, 'lng': 90.407, 'name': 'Gulshan 1'};
      }
      throw ApiException('no_coords', 400);
    }
    if (path == '/journey/start') throw ApiException('test: not started', 500);
    if (path.endsWith('/location')) return {'status': 'active', 'overdue_state': 'on_time'};
    if (path.endsWith('/ride')) {
      return {'ok': true, 'changed': true, 'vehicle': {...body}..removeWhere((k, v) => v == '')};
    }
    if (path.endsWith('/web-link/revoke')) return {'ok': true, 'url': 'https://x/j/5-1.1.s'};
    return {'ok': true};
  }

  List<_Hit> posts(String suffix) =>
      hits.where((h) => h.method == 'POST' && h.path.endsWith(suffix)).toList();
}

class _Oem implements OemGuideNative {
  final OemInfo? i;
  _Oem(this.i);
  @override
  Future<OemInfo?> info() async => i;
  @override
  Future<OemOpen> available(String step) async => OemOpen.none;
  @override
  Future<OemOpen> open(String step) async => OemOpen.none;
}

final _nav = GlobalKey<NavigatorState>();

Widget _app(_Api api, {String lang = 'en'}) {
  final s = AppState()
    ..api = api
    ..user = AppUser(id: 1, name: 'Rina', phone: '01711000001', email: '',
        autonomyLevel: 2, language: lang)
    ..locale = Locale(lang)
    ..loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: s,
    child: MaterialApp(
      navigatorKey: _nav,
      locale: Locale(lang),
      theme: AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const Scaffold(body: Text('below')),
    ),
  );
}

Future<void> _settle(WidgetTester tester, [int n = 15]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<void> _open(WidgetTester tester, _Api api, Widget screen, {String lang = 'en'}) async {
  await tester.binding.setSurfaceSize(const Size(400, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_app(api, lang: lang));
  unawaited(_nav.currentState!.push(MaterialPageRoute(builder: (_) => screen)));
  await _settle(tester);
}

late AppLocalizations en, bn;

/// Bangla digit string for a Latin one (codepoints, no Bangla literal).
String jDigitsBn(String s) => String.fromCharCodes(
    s.codeUnits.map((c) => c >= 0x30 && c <= 0x39 ? 0x09E6 + c - 0x30 : c));

void main() {
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    bn = await AppLocalizations.delegate.load(const Locale('bn'));
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Settings.resetForTest();
    VehMapConfig.debugSet(const VehMapConfig()); // no tiles unless a test says so
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('flutter.baseflow.com/geolocator'),
        (call) async => call.method == 'checkPermission' ? 2 : null);
  });
  tearDown(() => VehMapConfig.debugSet(null));

  group('helpers', () {
    test('rough time mirrors the server and never promises sooner', () {
      expect(jRoughMinutes(5000, 'cng'), 35); // backend tests_journey2 too
      expect(jRoughMinutes(0, null), 5);
      expect(jRoughMinutes(5000, 'walk') > jRoughMinutes(5000, 'bike'), isTrue);
      expect(jDistanceM(23.80, 90.40, 23.755, 90.40), closeTo(5004, 30));
    });
    test('ride line and place labels in one language', () {
      final v = {'mode': 'cng', 'app': 'pathao', 'plate': 'DHA-1'};
      expect(jRideLine(en, v), 'CNG · Pathao · DHA-1');
      expect(jRideLine(bn, v), '${bn.journeyModeCng} · ${bn.j2AppPathao} · DHA-${jDigitsBn('1')}');
      expect(jPlaceLabel(bn, {'label': 'home', 'name': 'Home'}), bn.j2PlaceHome);
      expect(jPlaceLabel(en, {'label': 'Aunt', 'name': ''}), 'Aunt');
    });
  });

  testWidgets('saved Home pins in one tap; typed name only says no pin', (tester) async {
    final api = _Api()
      ..places = [
        {'id': 1, 'label': 'home', 'kind': 'home', 'name': 'Home', 'lat': 23.8, 'lng': 90.4},
      ];
    await _open(tester, api, const JourneyStartScreen());
    expect(find.byKey(const ValueKey('j2_intro')), findsOneWidget);
    expect(find.byKey(const ValueKey('j2_search')), findsNothing); // no geocoder
    expect(find.byKey(const ValueKey('j2_pick_map')), findsNothing); // no tiles
    expect(find.byKey(const ValueKey('j2_no_map')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('j100_dest')), 'Aunt');
    await _settle(tester, 3);
    expect(find.byKey(const ValueKey('j2_no_pin')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('j2_place_1')));
    await _settle(tester, 3);
    expect(find.byKey(const ValueKey('j2_pinned')), findsOneWidget);
    expect(find.byKey(const ValueKey('j2_no_pin')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('j2_unpin')));
    await _settle(tester, 3);
    expect(find.byKey(const ValueKey('j2_no_pin')), findsOneWidget);
  });

  testWidgets('paste a Maps link -> pinned; a bad link says why', (tester) async {
    final api = _Api();
    await _open(tester, api, const JourneyStartScreen());
    await tester.tap(find.byKey(const ValueKey('j2_paste_link')));
    await _settle(tester, 6);
    await tester.enterText(find.byKey(const ValueKey('j2_link_field')), 'hello there');
    await tester.tap(find.byKey(const ValueKey('j2_link_use')));
    await _settle(tester, 6);
    expect(find.text(en.j2PasteLinkBad), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('j2_link_field')), 'https://maps.app.goo.gl/x');
    await tester.tap(find.byKey(const ValueKey('j2_link_use')));
    await _settle(tester, 8);
    expect(api.posts('/journey/parse-link').length, 2);
    expect(find.byKey(const ValueKey('j2_pinned')), findsOneWidget);
    expect(find.text('Gulshan 1'), findsOneWidget);
  });

  testWidgets('search shows only with a geocoder, and picks a real row', (tester) async {
    final api = _Api()..geocoder = true;
    await _open(tester, api, const JourneyStartScreen());
    await tester.tap(find.byKey(const ValueKey('j2_search')));
    await _settle(tester, 6);
    await tester.enterText(find.byKey(const ValueKey('j2_search_field')), 'Bashundhara');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await _settle(tester, 6);
    await tester.tap(find.text('Bashundhara City'));
    await _settle(tester, 6);
    expect(find.byKey(const ValueKey('j2_pinned')), findsOneWidget);
  });

  testWidgets('map pick shows only with tiles', (tester) async {
    VehMapConfig.debugSet(const VehMapConfig(tileUrl: 'https://tiles.example/{z}/{x}/{y}.png'));
    await _open(tester, _Api(), const JourneyStartScreen());
    expect(find.byKey(const ValueKey('j2_pick_map')), findsOneWidget);
    expect(find.byKey(const ValueKey('j2_no_map')), findsNothing);
  });

  testWidgets('select all watchers + ride details go to the server', (tester) async {
    final api = _Api()
      ..circle = {
        'results': [
          {'id': 7, 'name': 'Mum', 'phone': '01711000002', 'state': 'accepted'},
          {'id': 8, 'name': 'Dad', 'phone': '01711000003', 'state': 'accepted'},
        ]
      };
    await _open(tester, api, const JourneyStartScreen());
    await tester.tap(find.byKey(const ValueKey('j2_all')));
    await _settle(tester, 3);
    expect(find.text(en.j2SelectNone), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('j100_dest')), 'Home');
    await tester.tap(find.byKey(const ValueKey('j2_ride')));
    await _settle(tester, 6);
    await tester.enterText(find.byKey(const ValueKey('j2_plate')), 'DHA-1');
    await tester.enterText(find.byKey(const ValueKey('j2_driver_name')), 'Rahim');
    await tester.ensureVisible(find.byKey(const ValueKey('j100_start'), skipOffstage: false));
    await _settle(tester, 3);
    await tester.tap(find.byKey(const ValueKey('j100_start')));
    await _settle(tester);
    final b = api.posts('/journey/start').single.body;
    expect((b['watcher_ids'] as List).toSet(), {7, 8});
    expect(b['vehicle'], {'plate': 'DHA-1', 'driver_name': 'Rahim'});
  });

  JourneyTracker tr() => JourneyTracker(
      useService: false,
      position: () async => (lat: 23.755, lng: 90.40),
      battery: () async => 70);

  Map<String, dynamic> trip() => {
        'id': 5,
        'status': 'active',
        'destination': {'name': 'Home', 'lat': 23.80, 'lng': 90.40},
        'eta': DateTime.now().add(const Duration(minutes: 30)).toIso8601String(),
        'pin_required': false,
        'extend_left': 6,
        'vehicle': {'plate': 'DHA-1', 'mode': 'cng'},
      };

  testWidgets('live: background card on a Xiaomi, none on near-stock', (tester) async {
    final t1 = tr();
    await _open(tester, _Api()..active = trip(),
        JourneyLiveScreen(journeyId: 5, tracker: t1,
            oem: _Oem(const OemInfo(manufacturer: 'Xiaomi', brand: 'Redmi',
                batteryOptIgnored: false, bgRestricted: false))));
    expect(find.byKey(const ValueKey('j2_bg_risk')), findsOneWidget);
    expect(find.text(en.j2BgRiskTitle), findsOneWidget);
    expect(find.byKey(const ValueKey('j2_to_go')), findsOneWidget); // ~5 km
    expect(find.text('CNG · DHA-1'), findsOneWidget);
    await t1.stop();
    final t2 = tr();
    await _open(tester, _Api()..active = trip(),
        JourneyLiveScreen(journeyId: 5, tracker: t2,
            oem: _Oem(const OemInfo(manufacturer: 'Walton', brand: 'Walton',
                batteryOptIgnored: false, bgRestricted: false))));
    expect(find.byKey(const ValueKey('j2_bg_risk')), findsNothing);
    await t2.stop();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('live: ride details mid-trip + turning the link off', (tester) async {
    final api = _Api()..active = trip();
    final t1 = tr();
    await _open(tester, api, JourneyLiveScreen(journeyId: 5, tracker: t1, oem: _Oem(null)));
    await tester.ensureVisible(find.byKey(const ValueKey('j2_ride_edit')));
    await tester.tap(find.byKey(const ValueKey('j2_ride_edit')));
    await _settle(tester, 6);
    await tester.enterText(find.byKey(const ValueKey('j2_ride_driver')), 'Rahim');
    await tester.tap(find.byKey(const ValueKey('j2_ride_save')));
    await _settle(tester, 6);
    expect(api.posts('/journey/5/ride').single.body['driver_name'], 'Rahim');
    expect(find.text(en.j2Driver('Rahim')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('j100_share')));
    await _settle(tester, 6);
    await tester.tap(find.byKey(const ValueKey('j2_link_off')));
    await _settle(tester, 6);
    expect(find.text(en.j2LinkOffBody), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('j2_link_off_ok')));
    await _settle(tester, 6);
    expect(api.posts('/journey/5/web-link/revoke').length, 1);
    expect(find.text(en.j2LinkOffDone), findsOneWidget);
    await t1.stop();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('watcher empty state: benefit, how-to and a big action', (tester) async {
    await _open(tester, _Api(), const JourneyWatchScreen());
    expect(find.text(en.j2WatchEmptyBenefit), findsOneWidget);
    expect(find.text(en.j2WatchEmptyHow), findsOneWidget);
    expect(find.byKey(const ValueKey('j2_watch_start_own')), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // drop the refresh timer
  });

  testWidgets('watcher list in Bangla: Bangla digits, distance and ride', (tester) async {
    final api = _Api()
      ..watching = [
        {'id': 1, 'name': 'Rina', 'status': 'active', 'sos': false, 'destination': 'Home',
         'lat': 23.7, 'lng': 90.4, 'fix_age_s': 600, 'battery': 40, 'distance_m': 2400,
         'ride': {'mode': 'bike', 'app': 'pathao', 'plate': 'DHA-9'}, 'url': 'https://x/j/1'},
      ];
    await _open(tester, api, const JourneyWatchScreen(), lang: 'bn');
    final ctx = tester.element(find.byType(JourneyWatchScreen));
    expect(find.text(bn.j100StStale(jDigits(ctx, 10))), findsOneWidget);
    expect(find.text(bn.j100StStale(10)), findsNothing); // never Latin digits
    expect(find.text(bn.j2ToGo(jKm(ctx, 2400))), findsOneWidget);
    expect(find.text('${bn.j2ModeBike} · ${bn.j2AppPathao} · DHA-${jDigits(ctx, 9)}'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
