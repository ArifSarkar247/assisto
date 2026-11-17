// gap-city (owner order 17 Nov 10:10, feature gap sweep): City Service gaps
// a real user hits — every fix has a test here.
//  * guides hand a place back: "Go by bus / metro" from Around me, offices,
//    terminals -> City Service plans the trip (no leaving for another app);
//  * no GPS + no start -> "where are you starting from" with real buttons;
//  * failed loads are never dead ends (Try again); offices / terminals open
//    offline from the last good copy; a search that finds nothing says so;
//  * voice ask understands romanized Bangla and falls back to the full
//    place search for names our city data does not know;
//  * the offline map pack keeps fonts + sprites (CITY_MAP_TILES_API.md §5).
import 'dart:io';

import 'package:assisto/city/city_models.dart';
import 'package:assisto/city/city_offline.dart';
import 'package:assisto/city/map/city_map_style.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/maps/place_search.dart' show PlacePick;
import 'package:assisto/models.dart';
import 'package:assisto/screens/city/city_around_screen.dart';
import 'package:assisto/screens/city/city_directory_screen.dart';
import 'package:assisto/screens/city/city_journey.dart';
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

class _GapApi extends FakeApi {
  bool offline = false;
  bool netDown = false; // everything off (Safe Journey start too)
  final List<String> gets = [];
  _GapApi({super.mode});

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    gets.add(path);
    if (netDown || (offline && path.startsWith('/city/'))) throw const SocketException('offline');
    return super.getJson(path);
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) async {
    if (netDown) throw const SocketException('offline');
    return super.postJson(path, body);
  }
}

/// A host page with one button that opens [screen] and keeps its result.
class _Host extends StatefulWidget {
  final Widget screen;
  const _Host(this.screen);
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  PlacePick? got;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: TextButton(
            key: const ValueKey('host_open'),
            onPressed: () async {
              final p = await Navigator.of(context).push<PlacePick>(MaterialPageRoute(builder: (_) => widget.screen));
              setState(() => got = p);
            },
            child: Text(got == null ? 'none' : 'got ${got!.name} ${got!.lat}'),
          ),
        ),
      );
}

Future<AppLocalizations> _pump(WidgetTester tester, Widget screen, FakeApi api, {String lang = 'en'}) async {
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

const _here = (lat: 23.8075, lon: 90.3670);

void main() {
  group('voice ask: romanized Bangla', () {
    test('theke / jabo / kon bus / ekhan', () {
      expect(parseCityAsk('Farmgate theke Motijheel jabo'), (from: 'Farmgate', to: 'Motijheel'));
      expect(parseCityAsk('ekhan theke New Market kon bus?'), (from: null, to: 'New Market'));
      expect(parseCityAsk('Mirpur 10 theke Gulshan 1 kivabe jabo'), (from: 'Mirpur 10', to: 'Gulshan 1'));
      expect(parseCityAsk('Uttara hote Shahbag porjonto'), (from: 'Uttara', to: 'Shahbag'));
      // the English + Bangla-script forms still work
      expect(parseCityAsk('from Farmgate to Motijheel'), (from: 'Farmgate', to: 'Motijheel'));
      expect(parseCityAsk('এখান থেকে নিউ মার্কেট কোন বাস'), (from: null, to: 'নিউ মার্কেট'));
    });
  });

  group('offline map pack keeps fonts + sprites (contract §5)', () {
    test('style points glyphs + sprite at the pack; tiles at the files', () {
      final s = styleWithOffline({
        'version': 8,
        'glyphs': 'https://x/maps/v1/fonts/{fontstack}/{range}.pbf',
        'sprite': 'https://x/maps/v1/sprites/v1/night',
        'sources': {
          'assisto_base': {'type': 'vector', 'url': 'pmtiles://https://x/bd_base.pmtiles'},
          'assisto_places': {'type': 'vector', 'url': 'pmtiles://https://x/bd_places.pmtiles'},
        },
        'layers': [],
      }, baseFile: '/d/dhaka_base.pmtiles', buildingsFile: '', assetsDir: '/d/assets');
      expect(s['glyphs'], 'file:///d/assets/fonts/{fontstack}/{range}.pbf');
      expect(s['sprite'], 'file:///d/assets/sprites/v1/night');
      expect((s['sources'] as Map)['assisto_base']['url'], 'pmtiles://file:///d/dhaka_base.pmtiles');
      expect((s['sources'] as Map)['assisto_places']['url'], 'pmtiles://https://x/bd_places.pmtiles');
    });
    test('without the assets the online glyphs stay (names still load online)', () {
      final s = styleWithOffline({
        'version': 8,
        'glyphs': 'https://x/fonts/{fontstack}/{range}.pbf',
        'sources': {},
        'layers': [],
      }, baseFile: '/d/b.pmtiles', buildingsFile: '');
      expect(s['glyphs'], 'https://x/fonts/{fontstack}/{range}.pbf');
    });
    test('pack assets: only safe fonts/ + sprites/ paths', () {
      expect(
          packAssets({
            'fonts': ['fonts/Noto Sans Bengali Regular v1/0-255.pbf', '../etc/passwd', 'fonts/../x'],
            'sprites': ['sprites/v1/light@2x.png', '/abs/sprite.png'],
          }),
          ['fonts/Noto Sans Bengali Regular v1/0-255.pbf', 'sprites/v1/light@2x.png']);
    });
  });

  group('guides hand the place back to City Service', () {
    testWidgets('offices: "Go by bus / metro" returns the office as the destination', (tester) async {
      final t = await _pump(
          tester,
          _Host(CityDirectoryScreen(kinds: const ['offices'], routeHere: true, store: CityStore(files: MemoryCityFiles()))),
          _GapApi());
      await tester.tap(find.byKey(const ValueKey('host_open')));
      await tester.pumpAndSettle();
      expect(find.text(t.cityGRouteHere), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('city_route_here_o-passport')));
      await tester.pumpAndSettle();
      expect(find.textContaining('got Department of Immigration'), findsOneWidget);
      expect(find.textContaining('23.7787'), findsOneWidget);
    });

    testWidgets('opened elsewhere (no routeHere): no extra button', (tester) async {
      final t = await _pump(
          tester, CityDirectoryScreen(kinds: const ['offices'], store: CityStore(files: MemoryCityFiles())), _GapApi());
      expect(find.text(t.cityGRouteHere), findsNothing);
      expect(find.text(t.cityOpenInGoogleMaps), findsWidgets);
    });

    testWidgets('Around me: "Go by bus / metro" returns the place', (tester) async {
      await _pump(tester, const _Host(CityAroundScreen(debugHere: _here, routeHere: true)), _GapApi());
      await tester.tap(find.byKey(const ValueKey('host_open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('city_route_here_Square Hospital')));
      await tester.pumpAndSettle();
      expect(find.textContaining('got Square Hospital'), findsOneWidget);
    });
  });

  group('never a dead end', () {
    testWidgets('offices offline: last good copy + note; no copy -> Try again works', (tester) async {
      final store = CityStore(files: MemoryCityFiles());
      final api = _GapApi();
      // 1) online once -> remembered
      final t = await _pump(tester, CityDirectoryScreen(kinds: const ['offices'], store: store), api);
      expect(find.byKey(const ValueKey('city_dir_item_o-passport')), findsOneWidget);
      // 2) offline -> the saved copy, honestly labelled
      api.offline = true;
      await _pump(tester, CityDirectoryScreen(key: const ValueKey('again'), kinds: const ['offices'], store: store), api);
      expect(find.byKey(const ValueKey('city_dir_item_o-passport')), findsOneWidget);
      expect(find.byKey(const ValueKey('city_dir_offline')), findsOneWidget);
      // 3) offline with no copy -> a real Try again button
      await _pump(tester,
          CityDirectoryScreen(key: const ValueKey('fresh'), kinds: const ['terminals'], store: CityStore(files: MemoryCityFiles())), api);
      expect(find.text(t.cityGLoadFailed), findsOneWidget);
      api.offline = false;
      await tester.tap(find.byKey(const ValueKey('city_dir_retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('city_dir_item_t-gabtoli')), findsOneWidget);
      expect(find.byKey(const ValueKey('city_dir_failed')), findsNothing);
    });

    testWidgets('a search that matches nothing says so', (tester) async {
      final t = await _pump(
          tester, CityDirectoryScreen(kinds: const ['offices'], store: CityStore(files: MemoryCityFiles())), _GapApi());
      await tester.enterText(find.byKey(const ValueKey('city_dir_search')), 'zzqq');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('city_dir_no_match')), findsOneWidget);
      expect(find.text(t.cityGNoMatch('zzqq')), findsOneWidget);
    });

    testWidgets('Around me down -> Try again button (not just a sentence)', (tester) async {
      final t = await _pump(tester, const CityAroundScreen(debugHere: _here), _GapApi(mode: FakeMode.fail));
      expect(find.byKey(const ValueKey('city_around_failed')), findsOneWidget);
      expect(find.text(t.cityTryAgain), findsOneWidget);
    });

    testWidgets('no GPS + no start chosen -> say so, with Use my location + Choose start', (tester) async {
      final t = await _pump(
          tester,
          CityServiceScreen(
              debugTo: const (name: 'Motijheel', address: '', lat: 23.7284, lng: 90.4205),
              debugSimple: false,
              debugLocate: () async => null, // location off
              store: CityStore(files: MemoryCityFiles())),
          _GapApi());
      expect(find.byKey(const ValueKey('city_need_start')), findsOneWidget);
      expect(find.text(t.cityGNeedStart), findsOneWidget);
      expect(find.byKey(const ValueKey('city_need_start_gps')), findsOneWidget);
      expect(find.byKey(const ValueKey('city_need_start_pick')), findsOneWidget);
      // the old misleading "Could not find the way" is gone
      expect(find.text(t.cityPlanFailed), findsNothing);
    });

    testWidgets('Leave at…: a later time re-plans for that hour; Leave now goes back', (tester) async {
      final api = _GapApi();
      final t = await _pump(
          tester,
          CityServiceScreen(
              debugHere: _here,
              debugTo: const (name: 'Motijheel', address: '', lat: 23.7284, lng: 90.4205),
              debugSimple: false,
              debugNow: DateTime(2026, 11, 17, 14, 30),
              store: CityStore(files: MemoryCityFiles())),
          api);
      expect(find.text(t.cityGLeaveNow), findsOneWidget);
      expect(api.gets.where((g) => g.startsWith('/city/plan')).last, isNot(contains('at=')));
      await tester.ensureVisible(find.byKey(const ValueKey('city_leave_at')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('city_leave_at')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(MaterialLocalizations.of(tester.element(find.byType(Dialog))).okButtonLabel));
      await tester.pumpAndSettle();
      expect(api.gets.where((g) => g.startsWith('/city/plan')).last, contains('at=14%3A30'));
      expect(find.byKey(const ValueKey('city_leave_now')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('city_leave_now')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('city_leave_now')));
      await tester.pumpAndSettle();
      expect(api.gets.where((g) => g.startsWith('/city/plan')).last, isNot(contains('at=')));
    });

    testWidgets('Start as Safe Journey with no internet: the get-off alarm still starts + the trip guide opens',
        (tester) async {
      final api = _GapApi()..netDown = true;
      final armed = <(int, DestPlan)>[];
      final o = CityPlan.from(fakeCityPlan()).options[CityPick.fastest]!;
      final t = await _pump(
          tester,
          Builder(
              builder: (c) => Scaffold(
                  body: Center(
                      child: FilledButton(
                          key: const ValueKey('go'),
                          onPressed: () => startCityJourney(c,
                              option: o,
                              dest: (name: 'Motijheel', address: '', lat: 23.7284, lng: 90.4205),
                              askLocation: () async {},
                              arm: (id, p, _) async => armed.add((id, p))),
                          child: const Text('go'))))),
          api);
      await tester.tap(find.byKey(const ValueKey('go')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('city_sj_go')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('city_sj_go')));
      await tester.pumpAndSettle();
      expect(armed.single.$1, 0, reason: 'no journey id offline');
      expect(armed.single.$2.target.name, 'Motijheel');
      expect(armed.single.$2.notifyCircleIds, isEmpty);
      expect(find.byType(CityTripScreen), findsOneWidget);
      expect(find.text(t.cityGOfflineAlarmOnly), findsOneWidget);
      expect(find.text(t.cityStartFailed), findsNothing);
    });
  });
}
