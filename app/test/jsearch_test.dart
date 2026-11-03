// jsearch (owner phone test 4 Nov 00:05): typing "Chandra" in My Trip
// showed NO suggestions. Now: one shared place search — 2 letters, 300 ms
// debounce, stale answers dropped, one session token per search, ONE Place
// Details ends it; rows = name + area line + distance; before typing:
// current location / saved / recent; the pick shows a confirm card (full
// address, Change) and sets the arrival pin; expected arrival = now + ONE
// Routes ETA ("About 1 h 20 min by car"), empty with a hint when there is
// none; no "Wake me before my stop" switch and no internal map text on My
// Trip. Fake server returns plain maps only (Chandra Mor, Kaliakair,
// Gazipur; Chandra Bus Terminal).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/maps/maps_sdk.dart';
import 'package:assisto/maps/place_search.dart';
import 'package:assisto/maps/place_search_controller.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/journey_start_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/vehicle/veh_map.dart' show VehMapConfig;

class _Api extends ApiClient {
  _Api() {
    token = 't';
  }
  final gets = <String>[];
  final posts = <(String, Map<String, dynamic>)>[];
  Map<String, dynamic> eta = {'state': 'ok', 'minutes': 80, 'distance_m': 41000};
  List<Map<String, dynamic>> places = [];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    gets.add(path);
    if (path == '/journey/active') return {};
    if (path == '/circle/members') {
      return {
        'results': [
          {'id': 7, 'name': 'Mother', 'phone': '01711000002', 'state': 'accepted'}
        ]
      };
    }
    if (path == '/journey/places') return {'places': places};
    if (path == '/maps/status') return {'ready': true, 'min_chars': 2, 'debounce_ms': 300};
    if (path.startsWith('/maps/autocomplete')) {
      return {
        'state': 'ok',
        'results': [
          {'place_id': 'ChIJchandraMor', 'name': 'Chandra Mor',
           'secondary': 'Kaliakair, Gazipur', 'distance_m': 2140},
          {'place_id': 'ChIJchandraBus', 'name': 'Chandra Bus Terminal',
           'secondary': 'Chandra, Kaliakair, Gazipur', 'distance_m': 2380},
        ],
      };
    }
    if (path.startsWith('/maps/place')) {
      return {'state': 'ok', 'lat': 24.0469, 'lng': 90.2405,
              'address': 'Chandra Mor, Dhaka-Tangail Hwy, Kaliakair 1750, Gazipur'};
    }
    if (path.startsWith('/maps/eta')) return eta;
    if (path.startsWith('/maps/reverse')) return {'state': 'off', 'address': ''};
    if (path.startsWith('/journey/geocode')) return {'available': false};
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts.add((path, Map.of(body)));
    if (path == '/journey/start') throw ApiException('test: not started', 500);
    return {'ok': true};
  }

  List<String> hits(String p) => gets.where((g) => g.startsWith(p)).toList();
}

final _nav = GlobalKey<NavigatorState>();

Widget _app(_Api api, {String lang = 'en', Widget? home}) {
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
      home: home ?? const Scaffold(body: Text('below')),
    ),
  );
}

Future<void> _settle(WidgetTester tester, [int n = 15]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<void> _open(WidgetTester tester, _Api api) async {
  await tester.binding.setSurfaceSize(const Size(400, 2600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_app(api));
  unawaited(_nav.currentState!.push(MaterialPageRoute(builder: (_) => const JourneyStartScreen())));
  await _settle(tester);
}

late AppLocalizations en;

void main() {
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Settings.resetForTest();
    VehMapConfig.debugSet(const VehMapConfig()); // no tiles
    MapsSdk.debugAvailable = false; // no Maps SDK key in this build: no map, still works
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // location already allowed; the phone's last fix is near Kaliakair
    m.setMockMethodCallHandler(const MethodChannel('flutter.baseflow.com/geolocator'),
        (call) async => switch (call.method) {
              'checkPermission' => 2,
              'getLastKnownPosition' => {
                  'latitude': 24.03, 'longitude': 90.25, 'timestamp': 0, 'accuracy': 5.0,
                  'altitude': 0.0, 'heading': 0.0, 'speed': 0.0, 'speed_accuracy': 0.0,
                },
              _ => null,
            });
  });
  tearDown(() {
    VehMapConfig.debugSet(null);
    MapsSdk.debugAvailable = null;
  });

  group('PlaceSearchController — Chandra', () {
    testWidgets('2 letters, 300 ms debounce, one session token, details ends it', (tester) async {
      final asked = <List<String>>[];
      final views = <String>[];
      final c = PlaceSearchController(
        suggest: (q, s) async {
          asked.add([q, s]);
          return {'state': 'ok', 'results': [
            {'place_id': 'ChIJchandraMor', 'name': 'Chandra Mor', 'secondary': 'Kaliakair, Gazipur'}
          ]};
        },
        details: (id, s) async => {'state': 'ok', 'lat': 24.0469, 'lng': 90.2405, 'address': 'Gazipur'},
        onView: (v) => views.add(v.state),
      );
      c.onChanged('C');
      await tester.pump(const Duration(milliseconds: 400));
      expect(asked, isEmpty); // one letter: nothing sent
      expect(views.last, 'short');
      for (final q in ['Ch', 'Cha', 'Chan', 'Chand', 'Chandr', 'Chandra']) {
        c.onChanged(q);
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(asked, isEmpty); // still typing: debounce
      await tester.pump(const Duration(milliseconds: 300));
      expect(asked.map((a) => a[0]), ['Chandra']); // ONE request
      final token = asked.single[1];
      c.onChanged('Chandra M');
      await tester.pump(const Duration(milliseconds: 300));
      expect(asked[1][1], token); // the same session for the whole search
      final got = await c.select('ChIJchandraMor');
      expect(got?.lat, 24.0469);
      expect(c.session, isNot(token)); // Place Details ended the session
      c.dispose();
    });

    testWidgets('a stale answer ("Ch") never overwrites "Chandra"', (tester) async {
      final views = <PlaceSearchView>[];
      final c = PlaceSearchController(
        suggest: (q, s) async {
          if (q == 'Ch') await Future<void>.delayed(const Duration(seconds: 2));
          return {'state': 'ok', 'results': [
            {'place_id': 'id-$q', 'name': q}
          ]};
        },
        details: (id, s) async => const {},
        onView: views.add,
      );
      c.onChanged('Ch');
      await tester.pump(const Duration(milliseconds: 300));
      c.onChanged('Chandra');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 3));
      expect(views.last.rows.single['name'], 'Chandra');
      c.dispose();
    });
  });

  group('My Trip — Where are you going?', () {
    testWidgets('Chandra -> suggestions with area + distance -> confirm card -> pin + Routes ETA',
        (tester) async {
      final api = _Api();
      await _open(tester, api);
      await tester.tap(find.byKey(const ValueKey('jm_mode_car')));
      await _settle(tester, 3);
      final field = find.byKey(const ValueKey('j100_dest'));
      await tester.enterText(field, 'Chandra');
      await tester.pump(const Duration(milliseconds: 100));
      expect(api.hits('/maps/autocomplete'), isEmpty); // debounce
      await tester.pump(const Duration(milliseconds: 300));
      await _settle(tester, 3);
      expect(api.hits('/maps/autocomplete').length, 1);
      final ac = Uri.parse(api.hits('/maps/autocomplete').single).queryParameters;
      expect(ac['q'], 'Chandra');
      expect((ac['lat'], ac['lng']), ('24.03', '90.25')); // biased to where the user is
      expect(find.text('Chandra Mor'), findsOneWidget);
      expect(find.text('Kaliakair, Gazipur'), findsOneWidget); // the area line
      expect(find.text('Chandra Bus Terminal'), findsOneWidget);
      expect(find.text(en.trKm('2.1')), findsOneWidget); // distance
      expect(find.byKey(const ValueKey('mc_powered_google')), findsOneWidget);
      // the honest no-pin warning while only a name is typed
      expect(find.byKey(const ValueKey('j2_no_pin')), findsOneWidget);

      await tester.tap(find.text('Chandra Mor'));
      await _settle(tester, 6);
      // ONE Place Details with the same session token
      expect(api.hits('/maps/place').length, 1);
      expect(Uri.parse(api.hits('/maps/place').single).queryParameters['session'], ac['session']);
      // confirm card: full address + Change; the arrival pin is set
      expect(find.byKey(const ValueKey('j2_pinned')), findsOneWidget);
      expect(find.byKey(const ValueKey('ps_confirm_address')), findsOneWidget);
      expect(find.textContaining('Kaliakair 1750, Gazipur'), findsOneWidget);
      expect(find.byKey(const ValueKey('ps_change')), findsOneWidget);
      expect(find.byKey(const ValueKey('ps_confirm_map')), findsNothing); // no SDK key: no map
      expect(find.byKey(const ValueKey('j2_no_pin')), findsNothing);
      // expected arrival = now + ONE Routes ETA for the chosen mode
      expect(api.hits('/maps/eta').length, 1);
      expect(Uri.parse(api.hits('/maps/eta').single).queryParameters['mode'], 'car');
      expect(find.text(en.psEtaAbout(en.psDurHM(1, 20), 'car')), findsOneWidget);
      expect(find.byKey(const ValueKey('js_eta_hint')), findsNothing);

      await tester.ensureVisible(find.byKey(const ValueKey('j100_w_7')));
      await tester.tap(find.byKey(const ValueKey('j100_w_7')));
      await _settle(tester, 3);
      final start = find.byKey(const ValueKey('j100_start'));
      await tester.ensureVisible(start);
      await tester.tap(start);
      await _settle(tester);
      final body = api.posts.firstWhere((p) => p.$1 == '/journey/start').$2;
      final dest = body['destination'] as Map;
      expect((dest['name'], dest['lat'], dest['lng']), ('Chandra Mor', 24.0469, 90.2405)); // geofence
      final eta = DateTime.parse('${body['eta']}');
      final mins = eta.difference(DateTime.now().toUtc()).inMinutes;
      expect(mins, inInclusiveRange(78, 81));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('before typing: current location + saved places; Change clears the pin',
        (tester) async {
      final api = _Api()
        ..places = [
          {'id': 1, 'label': 'home', 'kind': 'home', 'name': 'Home', 'lat': 23.8, 'lng': 90.4},
        ];
      await _open(tester, api);
      await tester.tap(find.byKey(const ValueKey('j100_dest')));
      await _settle(tester, 3);
      expect(find.byKey(const ValueKey('ps_current')), findsOneWidget);
      expect(find.byKey(const ValueKey('ps_saved_0')), findsOneWidget);
      expect(find.byKey(const ValueKey('ps_map')), findsNothing); // no map in this build
      expect(api.hits('/maps/autocomplete'), isEmpty);
      await tester.tap(find.byKey(const ValueKey('ps_saved_0')));
      await _settle(tester, 6);
      expect(find.byKey(const ValueKey('j2_pinned')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ps_change')));
      await _settle(tester, 3);
      expect(find.byKey(const ValueKey('j2_pinned')), findsNothing);
    });

    testWidgets('no road time (capped) -> arrival stays empty with a hint, never a made-up time',
        (tester) async {
      final api = _Api()..eta = {'state': 'global_cap', 'gmaps_url': ''};
      await _open(tester, api);
      expect(find.text(en.psEtaSet), findsOneWidget); // nothing picked yet: no time shown
      await tester.enterText(find.byKey(const ValueKey('j100_dest')), 'Chandra');
      await tester.pump(const Duration(milliseconds: 400));
      await _settle(tester, 3);
      await tester.tap(find.text('Chandra Bus Terminal'));
      await _settle(tester, 6);
      expect(find.byKey(const ValueKey('j2_pinned')), findsOneWidget);
      expect(find.byKey(const ValueKey('js_eta_about')), findsNothing);
      expect(find.byKey(const ValueKey('js_eta_hint')), findsOneWidget);
      expect(find.text(en.psEtaSet), findsOneWidget);
    });

    testWidgets('no "Wake me before my stop" switch, no internal map text', (tester) async {
      await _open(tester, _Api());
      await tester.tap(find.byKey(const ValueKey('jm_mode_local_bus')));
      await _settle(tester, 3);
      expect(find.byKey(const ValueKey('jm_alarm')), findsNothing);
      expect(find.text(en.jmAlarmSwitch), findsNothing);
      expect(find.byKey(const ValueKey('j2_no_map')), findsNothing);
      expect(find.text(en.j2NoMapNote), findsNothing);
      expect(find.text(en.sjlNoMapNote), findsNothing);
    });
  });

  group('shared sheet (Destination Alarm, Child School, saved places)', () {
    testWidgets('Chandra -> confirm card -> Change -> pick again -> Use this place', (tester) async {
      final api = _Api();
      PlacePick? got;
      await tester.pumpWidget(_app(api,
          home: Scaffold(
              body: Builder(
                  builder: (ctx) => TextButton(
                      onPressed: () async => got = await showPlaceSearchSheet(ctx, api,
                          lat: 24.03, lng: 90.25, currentLocation: false),
                      child: const Text('open'))))));
      await tester.tap(find.text('open'));
      await _settle(tester);
      expect(api.hits('/maps/status').length, 1); // the server says search is ready
      await tester.enterText(find.byKey(const ValueKey('j2_search_field')), 'Chandra');
      await tester.pump(const Duration(milliseconds: 400));
      await _settle(tester, 3);
      await tester.tap(find.text('Chandra Mor'));
      await _settle(tester, 6);
      expect(find.byKey(const ValueKey('ps_confirm')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ps_change')));
      await _settle(tester, 3);
      expect(find.byKey(const ValueKey('ps_confirm')), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('j2_search_field')), 'Chandra');
      await tester.pump(const Duration(milliseconds: 400));
      await _settle(tester, 3);
      await tester.tap(find.text('Chandra Mor'));
      await _settle(tester, 6);
      await tester.tap(find.byKey(const ValueKey('ps_use')));
      await _settle(tester, 6);
      expect(got?.name, 'Chandra Mor');
      expect(got?.lat, 24.0469);
      expect(got?.address, contains('Gazipur'));
      // the second pick came from the place cache on the server side; the
      // phone still made exactly one Details call per pick
      expect(api.hits('/maps/place').length, 2);
      // ... and it is now a recent place
      expect((await PlaceRecents.load()).first.name, 'Chandra Mor');
    });
  });
}
