// gap-nearby (18 Nov): Nearby pull-to-refresh really refetches (and says so),
// the offline note says WHEN the list was saved, unnamed places get a title,
// every phone number shows its source (no number -> pointer to the official
// numbers), no ads on the emergency list; City: metro fare between two
// stations (official chart first, else the official per-km rate) online and
// offline, the same rule in the offline trip planner.
import 'package:assisto/ads/ad_banner_slot.dart';
import 'package:assisto/city/city_models.dart';
import 'package:assisto/city/city_offline.dart';
import 'package:assisto/city/metro_fare.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/nearby/area_cache.dart';
import 'package:assisto/screens/city/city_journey.dart';
import 'package:assisto/screens/city/city_metro_screen.dart';
import 'package:assisto/train/dest_alarm_math.dart';
import 'package:assisto/train/dest_alarm_service.dart';
import 'package:assisto/screens/nearby_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/nearby_data.dart';
import 'package:assisto/widgets/nearby_place_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api.dart';
import 'fake_city.dart';

const _here = (lat: 23.7380, lon: 90.3950);

Future<(AppLocalizations, FakeApi)> _pump(WidgetTester tester, Widget screen,
    {String lang = 'en', bool dark = false, FakeApi? api}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
  final a = api ?? FakeApi(lang: lang);
  final s = AppState()
    ..api = a
    ..user = AppUser(id: 1, name: 'Me', phone: '01712345678', email: '', autonomyLevel: 2, language: lang)
    ..locale = Locale(lang)
    ..loading = false;
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: s,
      child: MaterialApp(
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
        home: screen,
      )));
  await tester.pumpAndSettle();
  return (AppLocalizations.of(tester.element(find.byWidget(screen))), a);
}

/// The network can be switched off mid-test (pull-to-refresh failure).
class _NetApi extends FakeApi {
  bool down = false;
  _NetApi({super.lang});
  @override
  Future<Map<String, dynamic>> nearbyArea(double lat, double lon, {String v = ''}) async {
    if (down) {
      nearbyAreaCalls++;
      throw Exception('offline');
    }
    return super.nearbyArea(lat, lon, v: v);
  }
}

Future<void> _pull(WidgetTester tester) async {
  await tester.fling(find.byKey(const ValueKey('nearby_emergency_numbers')), const Offset(0, 600), 1500);
  await tester.pumpAndSettle();
}

final _saved = DateTime(2026, 11, 18, 10, 5);

void main() {
  _tripRinging();
  group('Nearby pull-to-refresh', () {
    testWidgets('pull really asks the server again and says so', (tester) async {
      NearbyScreen.areaRequests = 0;
      final (t, api) = await _pump(tester, NearbyScreen(debugLocation: _here, cache: AreaCache(MemoryAreaStore())));
      expect(api.nearbyAreaCalls, 1);
      expect(find.byKey(const ValueKey('nearby_refresh')), findsOneWidget);
      await _pull(tester);
      expect(api.nearbyAreaCalls, 2);
      expect(NearbyScreen.areaRequests, 2);
      expect(find.text(t.nearbyRefreshedNow), findsOneWidget);
      expect(find.text('Dhaka Medical College Hospital'), findsOneWidget);
      expect(find.byType(AdBannerSlot), findsNothing); // safety list: never ads
    });

    testWidgets('pull while offline: honest failure, saved list stays, with its date', (tester) async {
      final cache = AreaCache(MemoryAreaStore(), clock: () => _saved);
      final api = _NetApi(lang: 'en');
      final (t, _) = await _pump(tester, NearbyScreen(debugLocation: _here, cache: cache), api: api);
      expect(find.byKey(const ValueKey('nearby_offline_note')), findsNothing);
      api.down = true;
      await _pull(tester);
      expect(api.nearbyAreaCalls, 2);
      expect(find.text(t.nearbyRefreshFailedSaved), findsOneWidget);
      expect(find.text('Dhaka Medical College Hospital'), findsOneWidget);
      final note = tester.widget<Text>(find.byKey(const ValueKey('nearby_offline_note'))).data!;
      expect(note, contains('Nov 18'));
      expect(note, isNot(t.nearbyOfflineNote));
    });

    for (final lang in ['en', 'bn']) {
      testWidgets('opening offline shows the saved date ($lang)', (tester) async {
        final cache = AreaCache(MemoryAreaStore(), clock: () => _saved);
        await _pump(tester, NearbyScreen(debugLocation: _here, cache: cache), lang: lang);
        await tester.pumpWidget(const SizedBox());
        final api = _NetApi(lang: lang)..down = true;
        final (t, _) = await _pump(tester, NearbyScreen(debugLocation: _here, cache: cache), lang: lang, api: api);
        final note = tester.widget<Text>(find.byKey(const ValueKey('nearby_offline_note'))).data!;
        expect(note, isNot(t.nearbyOfflineNote));
        if (lang == 'bn') {
          expect(RegExp('[0-9]').hasMatch(note), isFalse, reason: note); // Bangla digits
        } else {
          expect(note, contains('Nov 18'));
        }
      });
    }

    test('cache: saved time comes back; markFresh moves it', () async {
      var now = DateTime(2026, 11, 18, 9);
      final c = AreaCache(MemoryAreaStore(), clock: () => now);
      final a = EmergencyArea(
          key: '23:90', lat0: 22, lat1: 25, lon0: 89, lon1: 92, version: 'BD:1', country: 'BD',
          attribution: 'x', places: const []);
      await c.put(a);
      expect((await c.lookup(23.7, 90.4))!.savedAt, DateTime(2026, 11, 18, 9));
      now = DateTime(2026, 11, 18, 11);
      await c.markFresh('23:90');
      expect((await c.lookup(23.7, 90.4))!.savedAt, DateTime(2026, 11, 18, 11));
    });
  });

  group('place card: name + number source', () {
    test('rows: phone_src read, older rows fall back to the place source', () {
      final a = AreaPlace.fromRow([1, 'hospital', 'h', 'H', 23.0, 90.0, '10666', 'osm', 'admin'])!;
      expect(a.phoneSrc, 'admin');
      final b = AreaPlace.fromRow([2, 'police', 'p', 'P', 23.0, 90.0, '999', 'osm'])!;
      expect(b.phoneSrc, 'osm');
      final c = AreaPlace.fromRow([3, 'fire', '', '', 23.0, 90.0, '', 'osm', ''])!;
      expect(c.phoneSrc, '');
    });

    Future<AppLocalizations> card(WidgetTester tester, NearbyPlace p, {String lang = 'en'}) async {
      final screen = Scaffold(
          body: NearbyPlaceCard(
              place: p, bn: lang == 'bn', distanceMeters: 300, favourite: false, onToggleFav: () {},
              now: DateTime(2026, 11, 18, 10)));
      final (t, _) = await _pump(tester, screen, lang: lang);
      return t;
    }

    NearbyPlace place(String name, String? phone, String src) => NearbyPlace.fromArea(
        AreaPlace(7, 'hospital', name, name, 23.74, 90.39, phone ?? '', 'osm', src), NearbyCat.hospital);

    for (final lang in ['en', 'bn']) {
      testWidgets('unnamed place gets a title, never blank ($lang)', (tester) async {
        final t = await card(tester, place('', null, ''), lang: lang);
        expect(find.text(t.nearbyUnnamedPlace(t.nearbyCatHospital)), findsOneWidget);
        expect(find.text(t.nearbyNoPhoneListed), findsOneWidget);
      });
    }

    testWidgets('number from OpenStreetMap says so', (tester) async {
      final t = await card(tester, place('Sample Hospital', '10666', 'osm'));
      expect(find.text(t.nearbyPhoneSrcOsm), findsOneWidget);
      expect(find.text(t.nearbyNoPhoneListed), findsNothing);
    });

    testWidgets('number the owner checked says so', (tester) async {
      final t = await card(tester, place('Sample Hospital', '10666', 'admin'));
      expect(find.text(t.nearbyPhoneSrcAdmin), findsOneWidget);
    });
  });

  group('metro fare between two stations', () {
    const fare = {
      'per_km': 5.0, 'min': 20, 'max': 100, 'card_discount_pct': 10, 'label': 'official',
      // the official pairs in backend/core/citytransit/fares.py METRO_CHART
      'chart': [
        {'a': 'AGA', 'b': 'UTN', 'tk': 60},
        {'a': 'MOT', 'b': 'UTN', 'tk': 100},
        {'a': 'FAR', 'b': 'MOT', 'tk': 40},
      ],
    };
    CityStation st(String code, double? km) => CityStation('s_$code', code, code, code, 23.8, 90.4, 0, km);

    test('chart pair wins, either direction, card price', () {
      final r = metroPairFare(st('UTN', 0), st('AGA', 9.6), fare)!;
      expect((r.tk, r.card, r.fromChart), (60, 54, true));
      expect(metroPairFare(st('AGA', 9.6), st('UTN', 0), fare)!.tk, 60);
      expect(metroPairFare(st('MOT', 20.1), st('FAR', 11.4), fare)!.tk, 40);
    });

    test('not on the chart: official rate on km along the line, min and max', () {
      final r = metroPairFare(st('AGA', 9.6), st('MOT', 20.1), fare)!; // 10.5 km -> 52.5 -> 50
      expect((r.tk, r.fromChart), (50, false));
      expect(metroPairFare(st('X1', 1.0), st('X2', 2.0), fare)!.tk, 20); // minimum
      expect(metroPairFare(st('X1', 0), st('X2', 40), fare)!.tk, 100); // maximum
    });

    test('same station / no km and no chart = no fare (never a guess)', () {
      expect(metroPairFare(st('UTN', 0), st('UTN', 0), fare), isNull);
      expect(metroPairFare(st('X1', null), st('X2', 5), fare), isNull);
    });

    test('offline planner uses the same chart; stations carry km', () {
      final pkg = fakeCityPackage();
      (pkg['rates']['metro'] as Map)['chart'] = fare['chart'];
      final r = OfflineRouter(pkg);
      final f = r.fare('metro', 8.9, a: 'FAR', b: 'MOT');
      expect((f['low'], f['basis']), (40, 'chart'));
      expect(r.fare('metro', 8.9)['basis'], 'rate');
      final s = r.stations();
      expect(s.first['km'], 0.0);
      expect((s.last['km'] as num) > 0, isTrue);
    });

    for (final lang in ['en', 'bn']) {
      testWidgets('metro guide: pick two stations -> fare ($lang)', (tester) async {
        final api = _MetroApi(lang: lang);
        final (t, _) = await _pump(tester, CityMetroScreen(store: CityStore(files: MemoryCityFiles())),
            lang: lang, api: api);
        final list = find.descendant(of: find.byKey(const ValueKey('city_metro_list')), matching: find.byType(Scrollable)).first;
        await tester.scrollUntilVisible(find.byKey(const ValueKey('city_metro_pair')), 200, scrollable: list);
        // default: first -> last station = Uttara North -> Motijheel (chart Tk 100)
        expect(find.byKey(const ValueKey('city_metro_pair_tk_100')), findsOneWidget);
        expect(find.text(t.cityMetroPairFromChart), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('city_metro_pair_to')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(lang == 'bn' ? 'আগারগাঁও' : 'Agargaon').last);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('city_metro_pair_tk_60')), findsOneWidget);
      });
    }
  });
}

void _tripRinging() {
  group('city trip guide while the get-off alarm rings', () {
    testWidgets('shows "You are near …" + I\'m awake; nothing when not ringing', (tester) async {
      final opt = CityPlan.from(fakeCityPlan()).options.values.first;
      final old = DestAlarmController.I;
      addTearDown(() => DestAlarmController.I = old);
      DestAlarmController.I = DestAlarmController(useService: false);
      final (t, _) = await _pump(tester, CityTripScreen(option: opt, debugPositions: const Stream.empty()));
      expect(find.byKey(const ValueKey('city_alarm_ringing')), findsNothing);
      DestAlarmController.I.value = const DestAlarmState(
          phase: DestAlarmPhase.ringing,
          plan: DestPlan(
              mode: TransportMode.cityBus,
              target: DestTarget('Motijheel', 23.733, 90.4177),
              setM: kCityAlarmM,
              notifyCircleIds: []));
      await tester.pumpAndSettle();
      expect(find.text(t.trAlarmRinging('Motijheel')), findsOneWidget);
      expect(find.byKey(const ValueKey('city_alarm_awake')), findsOneWidget);
    });
  });
}

class _MetroApi extends FakeApi {
  _MetroApi({super.lang});
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path.startsWith('/city/metro?')) {
      final m = Map<String, dynamic>.of(fakeCityMetro());
      Map<String, dynamic> s(String id, String code, String en, String bn, double km) =>
          {'id': id, 'code': code, 'name': en, 'name_bn': bn, 'lat': 23.8, 'lon': 90.38, 'gates': 1, 'km': km};
      m['stations'] = [
        s('st_utn', 'UTN', 'Uttara North', 'উত্তরা উত্তর', 0),
        s('st_aga', 'AGA', 'Agargaon', 'আগারগাঁও', 9.6),
        s('st_far', 'FAR', 'Farmgate', 'ফার্মগেট', 11.4),
        s('st_mot', 'MOT', 'Motijheel', 'মতিঝিল', 20.1),
      ];
      m['fare'] = {
        ...(m['fare'] as Map).cast<String, dynamic>(),
        'chart': [
          {'a': 'AGA', 'b': 'UTN', 'tk': 60},
          {'a': 'MOT', 'b': 'UTN', 'tk': 100},
          {'a': 'FAR', 'b': 'MOT', 'tk': 40},
        ],
      };
      return m;
    }
    return super.getJson(path);
  }
}
