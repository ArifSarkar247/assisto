// mapscost (owner order 3 Nov 18:40, PART 1): destination search sends
// nothing under 2 characters (jsearch), waits 300 ms of quiet, keeps ONE session token
// per search and ends it with ONE Place Details; the address comes from the
// phone's free Geocoder first, our server second, coordinates last; road time
// is one call on tap with a free Google Maps fallback; SOS code has no maps
// call at all. Fake server returns plain maps only.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/maps/address_resolver.dart';
import 'package:assisto/maps/maps_sdk.dart';
import 'package:assisto/maps/place_search.dart';
import 'package:assisto/maps/place_search_controller.dart';
import 'package:assisto/maps/road_eta_button.dart';
import 'package:assisto/state.dart' show Settings;
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/journey_dest_sheets.dart';

class _Api extends ApiClient {
  _Api() {
    token = 't';
  }
  final gets = <String>[];
  Map<String, dynamic> reverse = {'state': 'ok', 'address': 'Road 5, Dhanmondi'};
  Map<String, dynamic> eta = {'state': 'ok', 'minutes': 25, 'distance_m': 6400};
  String acState = 'ok';

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    gets.add(path);
    if (path.startsWith('/maps/reverse')) return reverse;
    if (path.startsWith('/maps/eta')) return eta;
    if (path.startsWith('/maps/autocomplete')) {
      if (acState != 'ok') return {'state': acState, 'results': const []};
      return {
        'state': 'ok',
        'results': [
          {'place_id': 'ChIJabc123', 'name': 'Bashundhara City', 'secondary': 'Panthapath'}
        ],
      };
    }
    if (path.startsWith('/maps/place')) {
      return {'state': 'ok', 'lat': 23.7509, 'lng': 90.3901, 'address': 'Panthapath'};
    }
    return {};
  }

  List<String> hits(String p) => gets.where((g) => g.startsWith(p)).toList();
}

Widget _host(Widget child, {String lang = 'en'}) => MaterialApp(
      locale: Locale(lang),
      theme: AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(body: child),
    );

void main() {
  setUp(() {
    // jsearch: the search keeps recent places in Settings
    SharedPreferences.setMockInitialValues({});
    Settings.resetForTest();
  });
  tearDown(() {
    AddressResolver.debugPhone = null;
    MapsSdk.debugAvailable = null;
  });

  group('PlaceSearchController', () {
    testWidgets('nothing under 2 chars, one call after 300 ms quiet, same session token',
        (tester) async {
      final asked = <List<String>>[];
      final views = <String>[];
      final c = PlaceSearchController(
        suggest: (q, s) async {
          asked.add([q, s]);
          return {'state': 'ok', 'results': [
            {'place_id': 'p1', 'name': 'X'}
          ]};
        },
        details: (id, s) async => {'state': 'ok', 'lat': 23.7, 'lng': 90.4},
        onView: (v) => views.add(v.state),
      );
      c.onChanged('B');
      await tester.pump(const Duration(milliseconds: 500));
      expect(asked, isEmpty);
      expect(views.last, 'short');
      for (final q in ['Ba', 'Bas', 'Bash', 'Bashu', 'Bashun']) {
        c.onChanged(q);
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(asked, isEmpty); // still typing
      await tester.pump(const Duration(milliseconds: 300));
      expect(asked.length, 1);
      expect(asked.single[0], 'Bashun');
      final token = asked.single[1];
      expect(token.length, 32);
      c.onChanged('Bashundhara');
      await tester.pump(const Duration(milliseconds: 300));
      expect(asked.length, 2);
      expect(asked[1][1], token); // one session for the whole search
      final got = await c.select('p1');
      expect(got?.lat, 23.7);
      expect(c.session, isNot(token)); // the session ended with ONE details call
      c.dispose();
    });

    testWidgets('a late answer for an older query is dropped', (tester) async {
      final views = <PlaceSearchView>[];
      var n = 0;
      final c = PlaceSearchController(
        suggest: (q, s) async {
          n++;
          if (q == 'Gul') await Future<void>.delayed(const Duration(seconds: 2));
          return {'state': 'ok', 'results': [
            {'place_id': 'id-$q', 'name': q}
          ]};
        },
        details: (id, s) async => const {},
        onView: views.add,
      );
      c.onChanged('Gul');
      await tester.pump(const Duration(milliseconds: 300));
      c.onChanged('Gulshan');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 3));
      expect(n, 2);
      expect(views.last.rows.single['name'], 'Gulshan');
      c.dispose();
    });
  });

  group('AddressResolver', () {
    testWidgets('phone Geocoder first — no server call', (tester) async {
      final api = _Api();
      AddressResolver.debugPhone = (lat, lng, lang) async => 'Road 27, Dhanmondi';
      final r = await AddressResolver.resolve(api, 23.746, 90.376);
      expect((r.text, r.source), ('Road 27, Dhanmondi', 'phone'));
      expect(api.hits('/maps/reverse'), isEmpty);
    });

    testWidgets('phone has nothing -> our server; capped -> coordinates', (tester) async {
      final api = _Api();
      AddressResolver.debugPhone = (lat, lng, lang) async => null;
      final r = await AddressResolver.resolve(api, 23.746, 90.376);
      expect((r.text, r.source), ('Road 5, Dhanmondi', 'server'));
      api.reverse = {'state': 'user_cap', 'address': '', 'coords': '23.74600, 90.37600'};
      AddressResolver.debugPhone = (lat, lng, lang) async => throw Exception('no geocoder');
      final c = await AddressResolver.resolve(api, 23.746, 90.376);
      expect((c.text, c.source, c.isAddress), ('23.74600, 90.37600', 'coords', false));
    });
  });

  group('search sheet', () {
    testWidgets('type -> 300 ms -> Google rows -> one Place Details', (tester) async {
      final api = _Api();
      JourneyDest? picked;
      await tester.pumpWidget(_host(Builder(
          builder: (ctx) => TextButton(
              onPressed: () async => picked = await showJourneySearchSheet(ctx, api, mode: PlaceSearchMode.live),
              child: const Text('open')))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('j2_search_field')), 'Bash');
      await tester.pump(const Duration(milliseconds: 100));
      expect(api.hits('/maps/autocomplete'), isEmpty);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(api.hits('/maps/autocomplete').length, 1);
      expect(find.text('Bashundhara City'), findsOneWidget);
      expect(find.byKey(const ValueKey('mc_powered_google')), findsOneWidget);
      await tester.tap(find.text('Bashundhara City'));
      await tester.pumpAndSettle();
      expect(api.hits('/maps/place').length, 1);
      await tester.tap(find.byKey(const ValueKey('ps_use'))); // jsearch: confirm card
      await tester.pumpAndSettle();
      final session = Uri.parse(api.hits('/maps/autocomplete').single).queryParameters['session'];
      expect(Uri.parse(api.hits('/maps/place').single).queryParameters['session'], session);
      expect(picked?.name, 'Bashundhara City');
      expect(picked?.lat, 23.7509);
    });

    testWidgets('capped -> honest message, nothing invented', (tester) async {
      final api = _Api()..acState = 'global_cap';
      await tester.pumpWidget(_host(Builder(
          builder: (ctx) => TextButton(
              onPressed: () => showJourneySearchSheet(ctx, api, mode: PlaceSearchMode.live), child: const Text('open')))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('j2_search_field')), 'Gulshan');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(t.mapscSearchCapped), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
    });
  });

  group('road time', () {
    testWidgets('one call on tap, Bangla digits', (tester) async {
      final api = _Api();
      await tester.pumpWidget(_host(
          RoadEtaButton(api: api, fromLat: 23.75, fromLng: 90.39, toLat: 23.8, toLng: 90.42),
          lang: 'bn'));
      expect(api.hits('/maps/eta'), isEmpty); // nothing until the tap
      await tester.tap(find.byKey(const ValueKey('mc_eta_ask')));
      await tester.pumpAndSettle();
      expect(api.hits('/maps/eta').length, 1);
      final t = await AppLocalizations.delegate.load(const Locale('bn'));
      expect(find.text(t.mapscRoadEtaResult('২৫')), findsOneWidget);
    });

    testWidgets('capped -> free Google Maps directions button', (tester) async {
      final api = _Api()..eta = {'state': 'user_cap', 'gmaps_url': 'https://www.google.com/maps/dir/?api=1'};
      await tester.pumpWidget(_host(
          RoadEtaButton(api: api, fromLat: 23.75, fromLng: 90.39, toLat: 23.8, toLng: 90.42)));
      await tester.tap(find.byKey(const ValueKey('mc_eta_ask')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mc_eta_open')), findsOneWidget);
    });
  });

  test('SOS code never touches a paid maps call', () {
    for (final f in [
      'lib/screens/journey_sos_screen.dart',
      'lib/widgets/sos_button.dart',
    ]) {
      final src = File(f).readAsStringSync();
      for (final bad in ['mapsReverse', 'mapsAutocomplete', 'mapsPlace', 'mapsEta',
        'AddressResolver', 'maps/maps_api.dart']) {
        expect(src.contains(bad), isFalse, reason: '$f uses $bad');
      }
    }
  });

  testWidgets('no Maps SDK key in this build -> the old map path', (tester) async {
    expect(await MapsSdk.available(), isFalse); // assets/maps/sdk.json committed false
  });
}
