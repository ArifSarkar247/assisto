// cityapp (owner order 9 Nov 11:45) — City Service proof:
//  * e2e routing on the contract's shapes (online plan -> chips -> steps,
//    fare labels + checked date, exit gate, CNG overcharge + complaint line);
//  * offline: the city package synced to the phone, then the trip planned ON
//    the phone with no network (metro + exit gate, and a one-change bus ->
//    metro trip), remembered plans, metro guide offline;
//  * "Which gate" geofence at the metro exit; Start as Safe Journey posts
//    Safe Journey's own start + arms the get-off alarm at the last stop;
//  * voice ask parsing (en + bn); no ad ever on route results.
import 'dart:io';

import 'package:assisto/city/city_models.dart';
import 'package:assisto/city/city_offline.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/city/city_journey.dart';
import 'package:assisto/screens/city/city_metro_screen.dart';
import 'package:assisto/screens/city/city_service_screen.dart';
import 'package:assisto/screens/city/city_voice.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/train/dest_alarm_math.dart';
import 'package:assisto/train/dest_alarm_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api.dart';
import 'fake_city.dart';

/// FakeApi that can drop off the network for /city/ calls and records posts.
class _CityApi extends FakeApi {
  bool offline = false;
  final List<(String, Map<String, dynamic>)> posts = [];
  _CityApi({super.lang, super.mode});

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (offline && path.startsWith('/city/')) throw const SocketException('offline');
    return super.getJson(path);
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) async {
    posts.add((path, body));
    return super.postJson(path, body);
  }
}

Future<AppLocalizations> _pump(WidgetTester tester, Widget screen, _CityApi api, {String lang = 'en'}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
  final s = AppState()
    ..api = api
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
        home: screen,
      )));
  await tester.pumpAndSettle();
  return AppLocalizations.of(tester.element(find.byWidget(screen)));
}

const _here = (lat: 23.8075, lon: 90.3670); // near Mirpur 10 station
const _motijheel = (name: 'Motijheel', address: '', lat: 23.7284, lng: 90.4205);

Finder _list() => find.descendant(of: find.byKey(const ValueKey('city_list')), matching: find.byType(Scrollable)).first;

void main() {
  group('offline router (the city package on the phone)', () {
    final r = OfflineRouter(fakeCityPackage());

    test('metro trip: board, get off, official fare, exit gate on the destination side', () {
      final p = CityPlan.from(r.plan(_here.lat, _here.lon, 23.7284, 90.4205, minute: 14 * 60), offline: true);
      expect(p.ok, isTrue);
      expect(p.offline, isTrue);
      final o = p.options[CityPick.fastest]!;
      final metro = o.legs.firstWhere((l) => l.mode == 'metro');
      expect(metro.board!.id, 'st_m10');
      expect(metro.alight!.id, 'st_mot');
      expect(metro.stops, 2);
      expect(metro.fare!.label, FareLabel.official);
      expect(metro.fare!.low, 80); // 15.6 km x Tk 5 -> rounded to 10
      expect(metro.fare!.checked, '2026-11-09');
      expect(metro.exitGate!.ref, 'A'); // east gate, nearest to the destination
      expect(o.legs.first.mode, 'walk');
      expect(o.legs.first.meters, greaterThan(0));
    });

    test('one change: bus to Farmgate, short walk, metro to Motijheel', () {
      final p = CityPlan.from(r.plan(23.7958, 90.3540, 23.7284, 90.4205, minute: 14 * 60));
      final o = p.options[CityPick.fewestChanges]!;
      expect(o.changes, 1);
      final modes = o.legs.map((l) => l.mode).toList();
      expect(modes.indexOf('bus'), lessThan(modes.indexOf('metro')));
      expect(o.fare.low, greaterThanOrEqualTo(10 + 20));
    });

    test('no stop near the start -> honest no_route + Google Maps transit link + other ways', () {
      final m = r.plan(23.9500, 90.2000, 23.7284, 90.4205);
      expect(m['ok'], isFalse);
      expect(m['reason'], 'no_route');
      expect('${m['google_maps']}', contains('travelmode=transit'));
      final cng = (m['other_ways'] as List).cast<Map>().firstWhere((w) => w['mode'] == 'cng');
      expect((cng['fare'] as Map)['overcharge_note'], isTrue);
      expect((cng['fare'] as Map)['label'], 'official');
      final bike = (m['other_ways'] as List).cast<Map>().firstWhere((w) => w['mode'] == 'ride_bike');
      expect((bike['fare'] as Map)['label'], 'estimate');
      expect((bike['fare'] as Map)['high'], greaterThan((bike['fare'] as Map)['low'] as int)); // always a range
    });

    test('metro guide offline: stations in line order + gates + connecting bus', () {
      expect(r.stations().map((s) => s['id']), ['st_m10', 'st_far', 'st_mot']);
      final g = r.stationGuide('st_mot', lat: 23.7290, lon: 90.4210)!;
      expect((g['which_gate'] as Map)['ref'], 'A');
      expect((g['gates'] as List).length, 2);
      expect(((g['gates'] as List).first as Map)['buses'], ['Sample Bus']);
    });
  });

  group('CityStore (offline cache)', () {
    test('sync saves the package; a fresh store plans with no network; unchanged costs nothing', () async {
      final files = MemoryCityFiles();
      final api = _CityApi();
      expect(await CityStore(files: files).sync(api, 'dhaka'), isTrue);
      expect(files.files.keys, contains('pkg_dhaka.json'));
      api.offline = true;
      final store2 = CityStore(files: files); // app restarted, no network
      expect(await store2.version('dhaka'), 'dhaka-v1');
      expect(await store2.sync(api, 'dhaka'), isTrue); // offline: keeps the copy
      final router = await store2.router('dhaka');
      expect(router!.plan(_here.lat, _here.lon, 23.7284, 90.4205)['ok'], isTrue);
    });

    test('remembered plans: last answer for the same trip comes back offline', () async {
      final s = CityStore(files: MemoryCityFiles());
      final k = CityStore.planKey(1, 2, 3, 4);
      await s.rememberPlan(k, fakeCityPlan());
      final got = await s.rememberedPlan(k);
      expect(CityPlan.from(got!.plan).options.length, 4);
      expect(await s.rememberedPlan(CityStore.planKey(9, 9, 9, 9)), isNull);
    });
  });

  group('models', () {
    test('fare labels + one number only when low == high', () {
      final p = CityPlan.from(fakeCityPlan());
      expect(p.options.keys, containsAll(CityPick.values));
      final bus = p.options[CityPick.cheapest]!.legs.firstWhere((l) => l.mode == 'bus');
      expect(bus.fare!.single, isFalse);
      expect(bus.status, 'reported');
      expect(p.complaint.dial, '333');
      expect(p.complaint.usesFallback, isTrue);
    });
    test('directory item papers in both languages', () {
      final o = CityDirItem.from(fakeCityDir('offices').first);
      expect(o.papers(true).first, 'অনলাইন আবেদনের সারাংশ');
      expect(o.papers(false).first, 'Online application summary');
      expect(o.checked, '2026-11-09');
    });
  });

  group('voice ask', () {
    test('english', () {
      expect(parseCityAsk('From here to New Market which bus?'), (from: null, to: 'New Market'));
      expect(parseCityAsk('from Farmgate to Motijheel'), (from: 'Farmgate', to: 'Motijheel'));
      expect(parseCityAsk('to Gulshan 1'), (from: null, to: 'Gulshan 1'));
    });
    test('bangla', () {
      expect(parseCityAsk('এখান থেকে নিউ মার্কেট কোন বাস'), (from: null, to: 'নিউ মার্কেট'));
      expect(parseCityAsk('ফার্মগেট থেকে মতিঝিল কিভাবে যাব?'), (from: 'ফার্মগেট', to: 'মতিঝিল'));
    });
  });

  group('geofence: which gate at the metro exit', () {
    test('inside 150 m of the get-off station only', () {
      final o = CityPlan.from(fakeCityPlan()).options[CityPick.fastest]!;
      final exit = cityMetroExit(o)!;
      expect(exit.gate.ref, 'A');
      expect(cityAtStation(exit.station, 23.7284, 90.4197), isTrue);
      expect(cityAtStation(exit.station, 23.7400, 90.4100), isFalse);
      expect(cityJourneyMode(o), 'metro');
    });

    testWidgets('trip screen shows "Which gate" when the phone reaches the station', (tester) async {
      final o = CityPlan.from(fakeCityPlan()).options[CityPick.fastest]!;
      await _pump(tester, CityTripScreen(option: o, debugPositions: Stream.value((lat: 23.7284, lon: 90.4197))),
          _CityApi());
      expect(find.byKey(const ValueKey('city_which_gate_now')), findsOneWidget);
      expect(find.text('Exit by gate A'), findsWidgets);
    });
  });

  group('screen e2e', () {
    testWidgets('online: route options, chips, steps, labels, CNG card; never an ad', (tester) async {
      final api = _CityApi();
      final t = await _pump(
          tester,
          CityServiceScreen(
              debugHere: _here, debugTo: _motijheel, debugSimple: false, store: CityStore(files: MemoryCityFiles()),
              debugNow: DateTime(2026, 11, 9, 14, 30)),
          api);
      expect(find.byKey(const ValueKey('city_option')), findsOneWidget);
      expect(find.byKey(const ValueKey('city_chip_cheapest')), findsOneWidget);
      expect(find.byKey(const ValueKey('city_chip_safer_night')), findsOneWidget);
      // cheapest by day = the bus
      expect(find.textContaining('Shikor Paribahan'), findsWidgets);
      expect(find.text(t.cityFareOfficial), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('city_chip_fastest')));
      await tester.pumpAndSettle();
      expect(find.textContaining('MRT Line 6'), findsWidgets);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('city_gate_box')), 300, scrollable: _list());
      expect(find.text('Exit by gate A'), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('city_cng_show')), 300, scrollable: _list());
      expect(find.byKey(const ValueKey('city_complaint')), findsOneWidget);
      expect(find.text(t.cityAdLabel), findsNothing); // B15: no ads on route results
      expect(api.posts, isEmpty);
    });

    testWidgets('offline: synced package -> trip planned on the phone with the exit gate', (tester) async {
      final api = _CityApi();
      final store = CityStore(files: MemoryCityFiles());
      await tester.runAsync(() => store.sync(api, 'dhaka'));
      api.offline = true;
      final t = await _pump(
          tester,
          CityServiceScreen(
              debugHere: _here, debugTo: _motijheel, debugSimple: false, debugPick: CityPick.fastest, store: store),
          api);
      expect(find.text(t.cityOfflinePlanned), findsOneWidget);
      expect(find.textContaining('MRT Line 6'), findsWidgets);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('city_gate_box')), 300, scrollable: _list());
      expect(find.text('Exit by gate A'), findsOneWidget);
    });

    testWidgets('no destination yet -> benefit line + big button + how-to', (tester) async {
      final t = await _pump(
          tester, CityServiceScreen(debugHere: _here, debugSimple: false, store: CityStore(files: MemoryCityFiles())),
          _CityApi());
      expect(find.byKey(const ValueKey('city_header')), findsOneWidget);
      expect(find.text(t.cityEmptyTitle), findsOneWidget);
      expect(find.byKey(const ValueKey('city_where_to_btn')), findsOneWidget);
    });

    testWidgets('no data for this city -> honest card + Open in Google Maps (transit)', (tester) async {
      final t = await _pump(
          tester, CityServiceScreen(debugHere: _here, debugSimple: false, store: CityStore(files: MemoryCityFiles())),
          _CityApi(mode: FakeMode.empty));
      expect(find.byKey(const ValueKey('city_no_data')), findsOneWidget);
      expect(find.text(t.cityOpenGoogleMapsTransit), findsOneWidget);
    });

    testWidgets('New here mode shows one way with tips', (tester) async {
      final t = await _pump(
          tester,
          CityServiceScreen(
              debugHere: _here, debugTo: _motijheel, debugSimple: true, store: CityStore(files: MemoryCityFiles())),
          _CityApi());
      expect(find.byKey(const ValueKey('city_chip_cheapest')), findsNothing);
      expect(find.text(t.cityNewHereShowing), findsOneWidget);
      await tester.scrollUntilVisible(find.text(t.cityTipMetro), 300, scrollable: _list());
      expect(find.text(t.cityTipMetro), findsOneWidget);
    });

    testWidgets('Start as Safe Journey: family from My Circle in one tap + get-off alarm at the last stop',
        (tester) async {
      final api = _CityApi();
      final armed = <(int, DestPlan)>[];
      final o = CityPlan.from(fakeCityPlan()).options[CityPick.fastest]!;
      await _pump(
          tester,
          Builder(
              builder: (c) => Scaffold(
                  body: Center(
                      child: FilledButton(
                          key: const ValueKey('go'),
                          onPressed: () => startCityJourney(c,
                              option: o, dest: _motijheel, arm: (id, p, _) async => armed.add((id, p))),
                          child: const Text('go'))))),
          api);
      await tester.tap(find.byKey(const ValueKey('go')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('city_watch_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('city_sj_go')));
      await tester.pumpAndSettle();
      final start = api.posts.firstWhere((p) => p.$1 == '/journey/start').$2;
      expect((start['destination'] as Map)['name'], 'Motijheel');
      expect(start['watcher_ids'], [1]);
      expect(start['mode'], 'metro');
      expect(armed.single.$1, 1);
      expect(armed.single.$2.target.name, 'Motijheel');
      expect(armed.single.$2.mode, TransportMode.cityBus);
      expect(armed.single.$2.setM, kCityAlarmM);
      expect(find.byType(CityTripScreen), findsOneWidget);
    });

    testWidgets('metro guide: hours, Friday, fares, recharge, stations -> gates', (tester) async {
      final t = await _pump(tester, CityMetroScreen(store: CityStore(files: MemoryCityFiles())), _CityApi());
      expect(find.text(t.cityMetroSatThu('07:10', '21:40')), findsOneWidget);
      expect(find.text(t.cityMetroFriday('15:00', '21:40')), findsOneWidget);
      expect(find.byKey(const ValueKey('city_metro_fare')), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('city_station_st_mot')), 300,
          scrollable: find.descendant(of: find.byKey(const ValueKey('city_metro_list')), matching: find.byType(Scrollable)).first);
      await tester.tap(find.byKey(const ValueKey('city_station_st_mot')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('city_gate_A')), findsOneWidget);
      expect(find.text(t.cityLiftHere), findsOneWidget);
    });
  });
}
