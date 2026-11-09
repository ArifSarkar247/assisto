// mapapp (owner order 10 Nov 00:35, PART A 1 + 3 + 4) — City map proof:
//  * map open (canvas engine in tests: no native view), credits, our layers
//    drawn from OUR City Service data, labels as Flutter widgets (Bangla);
//  * layer chips: metro, bus routes, fares, waterlogging, women bus (honest
//    "none confirmed yet");
//  * route results side by side: Assisto verified + CNG fare; Google transit
//    ONLY on the Google view, fetched only on "More routes" or when our data
//    has no answer, silent when Google gives nothing (no limit message);
//    the Assisto view never calls Google;
//  * trip confirm card: Which bus? What fare? -> /city/trips/confirm (no
//    name, no free text) -> "You verified N stops";
//  * pure: layer builder, offline style rewrite, polyline decode, crash guard.
import 'package:assisto/city/city_models.dart';
import 'package:assisto/city/map/assisto_map_view.dart';
import 'package:assisto/city/map/city_map_data.dart';
import 'package:assisto/city/map/city_map_style.dart';
import 'package:assisto/city/map/city_trip_learn_card.dart';
import 'package:assisto/city/map/google_city_view.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/city/city_journey.dart';
import 'package:assisto/screens/city/city_map_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api.dart';
import 'fake_city.dart';
import 'fake_city_map.dart';

class _MapApi extends FakeApi {
  final List<String> gets = [];
  final List<(String, Map<String, dynamic>)> posts = [];
  bool googleNone = false;
  bool noRoute = false;
  _MapApi() : super(mode: FakeMode.data);

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    gets.add(path);
    if (path.startsWith('/maps/transit')) return fakeGoogleTransit(none: googleNone);
    if (noRoute && path.startsWith('/city/plan')) {
      return {'ok': false, 'reason': 'no_route', 'other_ways': [], 'google_maps': ''};
    }
    return super.getJson(path);
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) async {
    posts.add((path, body));
    return super.postJson(path, body);
  }
}

const _mirpur = (lat: 23.8075, lon: 90.3670);
const _dest = (name: 'Motijheel', address: '', lat: 23.7270, lng: 90.4180);

Future<AppLocalizations> _pump(WidgetTester tester, Widget screen, _MapApi api, {String lang = 'en'}) async {
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
  return AppLocalizations.of(tester.element(find.byType(Scaffold).first));
}

CityMapScreen _screen({bool to = false, CityMapView view = CityMapView.assisto, Set<CityLayer>? layers}) =>
    CityMapScreen(
      here: _mirpur,
      to: to ? _dest : null,
      debugShapes: fakeCityMapShapes(),
      debugLayers: layers,
      debugView: view,
    );

void main() {
  setUp(() {
    AssistoMapView.debugCanvas = true;
    GoogleCityView.debugNoSdk = true;
  });

  testWidgets('map opens: our layers, Flutter labels, credits, Bangla station names', (tester) async {
    final api = _MapApi();
    final t = await _pump(tester, _screen(), api, lang: 'bn');
    expect(find.byKey(const ValueKey('city_map_canvas')), findsOneWidget);
    expect(find.byKey(const ValueKey('city_map_credits')), findsOneWidget);
    expect(find.textContaining('OpenStreetMap'), findsOneWidget);
    expect(find.text(t.cityMapTitle), findsOneWidget);
    expect(find.text('মিরপুর ১০'), findsWidgets); // metro label in Bangla (a widget, not a GL symbol)
    expect(find.text(t.cityMapHint), findsOneWidget); // no destination yet: how-to, not a dead end
    expect(api.gets.where((g) => g.startsWith('/maps/')), isEmpty); // Assisto view never asks Google
  });

  testWidgets('layer chips: bus, fares, waterlogging on/off; women bus honest empty', (tester) async {
    final api = _MapApi();
    // bus only, so no metro label competes for the same spot (labels declutter)
    final t = await _pump(tester, _screen(layers: {CityLayer.bus}), api);
    expect(find.text('Sample Bus 2'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('city_layer_bus')));
    await tester.pumpAndSettle();
    expect(find.text('Sample Bus 2'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('city_layer_fares')));
    await tester.pumpAndSettle();
    expect(find.text('৳10–35'), findsWidgets); // fare label from OUR fare data
    await tester.drag(find.byKey(const ValueKey('city_map_chips')), const Offset(-400, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('city_layer_waterlogging')));
    await tester.pumpAndSettle();
    expect(api.gets.any((g) => g.startsWith('/city/reports')), isTrue);
    await tester.tap(find.byKey(const ValueKey('city_layer_women')));
    await tester.pumpAndSettle();
    expect(find.text(t.cityMapWomenNone), findsOneWidget); // fake list is empty -> honest line
  });

  testWidgets('route results: Assisto verified + CNG side by side; no Google on the Assisto view',
      (tester) async {
    final api = _MapApi();
    final t = await _pump(tester, _screen(to: true), api);
    expect(find.byKey(const ValueKey('city_cmp_ours_cheapest')), findsOneWidget);
    expect(find.text(t.cityMapAssistoVerified), findsWidgets);
    await tester.dragUntilVisible(find.byKey(const ValueKey('city_cmp_cng')),
        find.byKey(const ValueKey('city_cmp_row')), const Offset(-300, 0));
    expect(find.byKey(const ValueKey('city_cmp_cng')), findsOneWidget);
    expect(find.text(t.cityMapGoogleTransit), findsNothing);
    expect(api.gets.where((g) => g.startsWith('/maps/transit')), isEmpty);
  });

  testWidgets('Google view: "More routes" -> live Google transit with attribution', (tester) async {
    final api = _MapApi();
    final t = await _pump(tester, _screen(to: true), api);
    await tester.tap(find.byKey(const ValueKey('city_map_view_google')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('city_gview_nosdk')), findsOneWidget); // no key in tests: panel + link
    expect(find.byKey(const ValueKey('city_gview_satellite')), findsOneWidget);
    // our data answered -> Google is NOT called until the user asks
    expect(api.gets.where((g) => g.startsWith('/maps/transit')), isEmpty);
    await tester.dragUntilVisible(find.byKey(const ValueKey('city_more_routes')),
        find.byKey(const ValueKey('city_cmp_row')), const Offset(-300, 0));
    await tester.tap(find.byKey(const ValueKey('city_more_routes')));
    await tester.pumpAndSettle();
    expect(api.gets.where((g) => g.startsWith('/maps/transit')).length, 1);
    await tester.dragUntilVisible(find.byKey(const ValueKey('city_cmp_google_0')),
        find.byKey(const ValueKey('city_cmp_row')), const Offset(-300, 0));
    expect(find.textContaining('MRT-6'), findsWidgets);
    expect(find.text(t.cityMapByGoogle), findsWidgets);
    // back to the Assisto view: Google results are not shown there
    await tester.tap(find.byKey(const ValueKey('city_map_view_assisto')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('city_cmp_google_0')), findsNothing);
  });

  testWidgets('Google view asks Google itself when our data has no answer; silent when Google has none',
      (tester) async {
    final api = _MapApi()
      ..noRoute = true
      ..googleNone = true;
    final t = await _pump(tester, _screen(to: true, view: CityMapView.google), api);
    expect(api.gets.where((g) => g.startsWith('/maps/transit')).length, 1);
    expect(find.byKey(const ValueKey('city_cmp_ours_none')), findsOneWidget);
    expect(find.byKey(const ValueKey('city_cmp_google_0')), findsNothing);
    expect(find.textContaining('limit'), findsNothing); // never a limit message
    expect(find.textContaining(t.cityMapGoogleTransit), findsNothing);
  });

  testWidgets('trip confirm card: one tap bus + fare -> confirm (no name) -> stops verified', (tester) async {
    final api = _MapApi();
    final opt = CityPlan.from(fakeCityPlan()).options[CityPick.cheapest]!;
    final t = await _pump(tester, CityTripScreen(option: opt, journeyId: 7), api);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('city_trip_done')), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const ValueKey('city_trip_done')));
    await tester.pumpAndSettle();
    expect(find.text(t.cityLearnCardTitle), findsOneWidget);
    expect(find.text(t.cityLearnCardSub), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('city_learn_bus_bus_shikor_1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('city_learn_fare_38')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('city_learn_send')));
    await tester.pumpAndSettle();
    final post = api.posts.firstWhere((p) => p.$1 == '/city/trips/confirm');
    expect(post.$2['route_id'], 'bus_shikor_1');
    expect(post.$2['paid'], 38);
    expect(post.$2['board_id'], 'b_m10');
    expect(post.$2['alight_id'], 'b_shapla');
    expect(post.$2.keys.toSet().intersection({'name', 'phone', 'user', 'text'}), isEmpty);
    expect(find.text(t.cityLearnVerified('14')), findsOneWidget);
  });

  test('layer builder: one line per route name, nearby only, fares from our data', () {
    final l = buildCityLayers(
      on: {CityLayer.metro, CityLayer.bus, CityLayer.fares},
      shapes: [...fakeCityMapShapes(), ...fakeCityMapShapes()],
      water: const [],
      womenIds: const {},
      bn: false,
      lat: _mirpur.lat,
      lon: _mirpur.lon,
      taka: (lo, hi) => '$lo-$hi',
      waterText: (n) => '$n',
      radiusKm: 3,
    );
    final ids = [for (final f in (l.lines['features'] as List)) (f as Map)['properties']['id']];
    expect(ids.where((i) => i == 'mrt6_s').length, 1); // duplicate direction dropped
    expect(ids.contains('bus_s1'), isFalse); // airport–Motijheel bus is far from Mirpur
    expect(ids.contains('bus_s2'), isTrue);
    expect(l.labels.any((x) => x.text == '10-35'), isTrue);
  });

  test('offline style: only the two big sources point at the phone files', () {
    final s = styleWithOffline({
      'version': 8,
      'sources': {
        'assisto_base': {'type': 'vector', 'url': 'pmtiles://https://x/bd_base.pmtiles'},
        'assisto_buildings': {'type': 'vector', 'url': 'pmtiles://https://x/bd_buildings.pmtiles'},
        'assisto_places': {'type': 'vector', 'url': 'pmtiles://https://x/bd_places.pmtiles'},
      },
      'layers': []
    }, baseFile: '/d/dhaka_base.pmtiles', buildingsFile: '/d/dhaka_buildings.pmtiles');
    final src = s['sources'] as Map;
    expect(src['assisto_base']['url'], 'pmtiles://file:///d/dhaka_base.pmtiles');
    expect(src['assisto_buildings']['url'], 'pmtiles://file:///d/dhaka_buildings.pmtiles');
    expect(src['assisto_places']['url'], 'pmtiles://https://x/bd_places.pmtiles');
    expect(mapStyleUrl('https://b/', night: true, bn: true), 'https://b/style/assisto-night-bn.json');
    expect(insideBbox(kDhakaBbox, 23.78, 90.42), isTrue);
    expect(insideBbox(kDhakaBbox, 22.33, 91.83), isFalse); // Chattogram
  });

  test('Google polyline decode + transit parse (state none -> nothing)', () {
    expect(decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@'), [(38.5, -120.2), (40.7, -120.95), (43.252, -126.453)]);
    expect(GTransitRoute.listFrom(fakeGoogleTransit()).length, 2);
    expect(GTransitRoute.listFrom(fakeGoogleTransit(none: true)), isEmpty);
    expect(GTransitRoute.listFrom({'state': 'user_cap', 'routes': fakeGoogleTransit()['routes']}), isEmpty);
  });

  test('fare quick picks + learnable rides', () {
    final opt = CityPlan.from(fakeCityPlan()).options[CityPick.cheapest]!;
    final rides = learnableRides(opt);
    expect(rides.single.routeId, 'bus_shikor_1');
    expect(fareChoices(rides.single), [35, 38, 45]);
    final metro = CityPlan.from(fakeCityPlan()).options[CityPick.fastest]!;
    expect(learnableRides(metro), isEmpty); // metro trips get no bus card
  });

  test('crash guard: a crash while opening -> list view from then on, until "try again"', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await CityMapGuard.glAllowed(), isTrue);
    await CityMapGuard.opening(); // the app dies here (native crash)
    expect(await CityMapGuard.glAllowed(), isFalse);
    expect(await CityMapGuard.glAllowed(), isFalse); // stays off
    await CityMapGuard.reset();
    expect(await CityMapGuard.glAllowed(), isTrue);
    await CityMapGuard.opening();
    await CityMapGuard.opened(); // style loaded fine
    expect(await CityMapGuard.glAllowed(), isTrue);
  });
}
