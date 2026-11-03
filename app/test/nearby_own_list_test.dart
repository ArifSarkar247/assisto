// nearby (owner 3 Nov 18:50): Assisto's own emergency list on the phone —
// distance sort on the phone, emergency numbers by the phone's country,
// offline area cache (size cap, LRU), report wrong number, no ads on the
// emergency list, "See more in Google Maps" at the end of every list, and
// no Google API anywhere.
import 'dart:io';

import 'package:assisto/ads/ad_banner_slot.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/nearby/area_cache.dart';
import 'package:assisto/nearby/emergency_numbers.dart';
import 'package:assisto/nearby/phone_country.dart';
import 'package:assisto/screens/nearby_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/nearby_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api.dart';

const _here = (lat: 23.7380, lon: 90.3950);

EmergencyArea _area(String key, double lat, double lon,
        {String version = 'BD:1', int rows = 3}) =>
    EmergencyArea(
      key: key,
      lat0: lat.floorToDouble() - 1,
      lat1: lat.floorToDouble() + 2,
      lon0: lon.floorToDouble() - 1,
      lon1: lon.floorToDouble() + 2,
      version: version,
      country: 'BD',
      attribution: '© OpenStreetMap contributors (ODbL)',
      places: [
        for (var i = 0; i < rows; i++)
          AreaPlace(i, 'hospital', 'h$i', 'Hospital $i', lat + i * 0.01, lon, '', 'osm'),
      ],
    );

Future<(AppLocalizations, FakeApi)> _pump(WidgetTester tester, Widget screen,
    {String lang = 'en', bool dark = false, FakeMode mode = FakeMode.data}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
  final api = FakeApi(lang: lang, mode: mode);
  final s = AppState()
    ..api = api
    ..user = AppUser(
        id: 1, name: 'Me', phone: '01712345678', email: '', autonomyLevel: 2, language: lang)
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
  return (AppLocalizations.of(tester.element(find.byWidget(screen))), api);
}

Finder _list() => find
    .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
    .first;

void main() {
  group('distance sort on the phone', () {
    test('nearest first, category filter, limit', () {
      final places = [
        const AreaPlace(1, 'hospital', 'far', 'Far', 23.80, 90.40, '', 'osm'),
        const AreaPlace(2, 'hospital', 'near', 'Near', 23.739, 90.395, '', 'osm'),
        const AreaPlace(3, 'police', 'thana', 'Thana', 23.7381, 90.3951, '', 'osm'),
        const AreaPlace(4, 'hospital', 'mid', 'Mid', 23.75, 90.40, '', 'osm'),
      ];
      final h = nearestFirst(places, _here.lat, _here.lon, cats: {'hospital'});
      expect([for (final x in h) x.$1.id], [2, 4, 1]);
      expect(h.first.$2, lessThan(200));
      final all = nearestFirst(places, _here.lat, _here.lon, limit: 2);
      expect([for (final x in all) x.$1.id], [3, 2]);
      // ~ 1 degree of latitude = 111 km
      expect(distanceM(23, 90, 24, 90), closeTo(111195, 300));
    });

    test('English name first, local name second', () {
      const a = AreaPlace(1, 'hospital', 'ঢাকা মেডিকেল', 'Dhaka Medical', 23, 90, '', 'osm');
      expect(a.displayName, 'Dhaka Medical');
      expect(a.secondName, 'ঢাকা মেডিকেল');
      const b = AreaPlace(2, 'police', 'শাহবাগ থানা', '', 23, 90, '', 'osm');
      expect(b.displayName, 'শাহবাগ থানা');
      expect(b.secondName, '');
    });
  });

  group('emergency numbers by the country the phone is in', () {
    test('network country wins (roaming), then our data, then SIM', () {
      expect(pickEmergencyCountry(network: 'sa', data: 'BD', sim: 'bd'), 'SA');
      expect(pickEmergencyCountry(network: '', data: 'AE', sim: 'BD'), 'AE');
      expect(pickEmergencyCountry(network: null, data: null, sim: 'bd'), 'BD');
      expect(pickEmergencyCountry(network: 'x1', data: '', sim: null), isNull);
    });

    test('every rollout country has official numbers and a source', () {
      for (final cc in ['BD', 'SA', 'AE', 'MY', 'QA', 'OM', 'KW', 'SG', 'IT', 'GB', 'US']) {
        final e = emergencyFor(cc);
        expect(e.cc, cc);
        expect(e.numbers, isNotEmpty, reason: cc);
        expect(e.source, startsWith('http'), reason: cc);
      }
      expect(emergencyFor('BD').primary.number, '999');
      expect(emergencyFor('BD').numbers.map((n) => n.number), contains('102'));
      expect(emergencyFor('OM').primary.number, '9999');
      expect(emergencyFor('KW').primary.number, '112');
      expect(emergencyFor('US').primary.number, '911');
      expect(emergencyFor('SG').numbers.map((n) => n.number), ['999', '995']);
      // unknown country -> 112 (3GPP emergency number), never a guess
      expect(emergencyFor('FR').primary.number, '112');
      expect(emergencyFor(null).cc, '');
    });
  });

  group('offline area cache', () {
    test('saved area comes back; size cap evicts least recently used', () async {
      var now = DateTime(2026, 11, 3);
      final store = MemoryAreaStore();
      final c = AreaCache(store, maxAreas: 2, clock: () => now = now.add(const Duration(minutes: 1)));
      await c.put(_area('23:90', 23.7, 90.4));
      await c.put(_area('22:91', 22.3, 91.8));
      expect((await c.lookup(23.74, 90.39))!.places, hasLength(3));
      // the third area evicts the least recently used one (22:91)
      await c.put(_area('24:89', 24.9, 89.3));
      expect(await c.keys(), unorderedEquals(['23:90', '24:89']));
      expect(store.files.containsKey('area_22:91'), isFalse);
    });

    test('byte cap and broken storage never throw', () async {
      var now = DateTime(2026, 11, 3);
      final store = MemoryAreaStore();
      final c = AreaCache(store,
          maxBytes: 1, clock: () => now = now.add(const Duration(minutes: 1)));
      await c.put(_area('23:90', 23.7, 90.4));
      await c.put(_area('22:91', 22.3, 91.8));
      expect(await c.keys(), ['22:91']); // the area just saved is kept
      store.files['index'] = '{broken';
      expect(await c.lookup(23.7, 90.4), isNull);
    });
  });

  group('Nearby screen (own list)', () {
    for (final lang in ['en', 'bn']) {
      for (final dark in [false, true]) {
        testWidgets('hospitals nearest first + numbers + see more ($lang, dark=$dark)',
            (tester) async {
          final (t, _) = await _pump(
              tester, NearbyScreen(debugLocation: _here, cache: AreaCache(MemoryAreaStore())),
              lang: lang, dark: dark);
          expect(find.byKey(const ValueKey('nearby_emergency_numbers')), findsOneWidget);
          expect(find.text(lang == 'bn' ? t.nearbyEmergencyIn(t.nearbyCountryBD)
              : 'Emergency numbers · Bangladesh'), findsOneWidget);
          final dmch = tester.getTopLeft(find.text('Dhaka Medical College Hospital')).dy;
          final square = tester.getTopLeft(find.text('Square Hospital')).dy;
          expect(dmch, lessThan(square));
          // local name as the second line
          expect(find.text('ঢাকা মেডিকেল কলেজ হাসপাতাল'), findsOneWidget);
          expect(find.byType(AdBannerSlot), findsNothing); // no ads on emergency
          await tester.scrollUntilVisible(
              find.byKey(const ValueKey('nearby_see_more_maps')), 300,
              scrollable: _list());
          expect(find.text(t.nearbySeeMoreMaps), findsOneWidget);
        });
      }
    }

    testWidgets('offline: the saved area shows when the server is down', (tester) async {
      final cache = AreaCache(MemoryAreaStore());
      await _pump(tester, NearbyScreen(debugLocation: _here, cache: cache));
      expect(await cache.keys(), ['23:90']);
      await tester.pumpWidget(const SizedBox());
      final (_, api) = await _pump(tester, NearbyScreen(debugLocation: _here, cache: cache),
          mode: FakeMode.fail);
      expect(api.nearbyAreaCalls, 1);
      expect(find.byKey(const ValueKey('nearby_offline_note')), findsOneWidget);
      expect(find.text('Dhaka Medical College Hospital'), findsOneWidget);
      expect(find.byKey(const ValueKey('truth_nearby_error')), findsNothing);
    });

    testWidgets('roaming SIM: numbers follow the network country', (tester) async {
      await _pump(
          tester,
          NearbyScreen(
              debugLocation: _here,
              cache: AreaCache(MemoryAreaStore()),
              debugPhoneCountry: const PhoneCountry(network: 'SA', sim: 'BD')));
      expect(find.text('Emergency numbers · Saudi Arabia'), findsOneWidget);
    });

    testWidgets('report wrong number reaches the server', (tester) async {
      final (t, api) = await _pump(tester,
          NearbyScreen(placeType: 'police', debugLocation: _here, cache: AreaCache(MemoryAreaStore())));
      final btn = find.byKey(const ValueKey('nearby_report_13'));
      await tester.scrollUntilVisible(btn, 200, scrollable: _list());
      await tester.tap(btn);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('nearby_report_phone')), '01320-040001');
      await tester.tap(find.byKey(const ValueKey('nearby_report_send')));
      await tester.pumpAndSettle();
      expect(api.nearbyReports.single['place'], 13);
      expect(api.nearbyReports.single['phone'], '01320-040001');
      expect(find.text(t.nearbyReportThanks), findsOneWidget);
    });

    testWidgets('general category: Open in Google Maps, banner allowed', (tester) async {
      final (t, _) = await _pump(tester,
          NearbyScreen(placeType: 'atm', debugLocation: _here, cache: AreaCache(MemoryAreaStore())));
      expect(find.byKey(const ValueKey('nearby_open_in_maps')), findsOneWidget);
      expect(find.text(t.nearbyOpenInMaps), findsOneWidget);
      expect(find.byKey(const ValueKey('nearby_emergency_numbers')), findsNothing);
      expect(NearbyCat.atmBank.mapsSearchUrl,
          startsWith('https://www.google.com/maps/search/?api=1&query='));
    });

    testWidgets('no location: numbers still work', (tester) async {
      final (t, _) = await _pump(tester,
          NearbyScreen(debugLocationDenied: true, cache: AreaCache(MemoryAreaStore())));
      expect(find.byKey(const ValueKey('nearby_emergency_numbers')), findsOneWidget);
      expect(find.text(t.nearbyNumbersFallback), findsOneWidget);
      expect(find.byKey(const ValueKey('truth_nearby_no_location')), findsOneWidget);
    });
  });

  test('no Google API in the nearby code', () {
    for (final f in [
      ...Directory('lib/nearby').listSync().whereType<File>(),
      File('lib/screens/nearby_screen.dart'),
      File('lib/widgets/nearby_data.dart'),
    ]) {
      final src = f.readAsStringSync();
      expect(src.contains('googleapis'), isFalse, reason: f.path);
      expect(src.contains('place/nearbysearch'), isFalse, reason: f.path);
    }
  });
}
