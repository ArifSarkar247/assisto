// qjourney (quality push 9 Nov): Nearby's empty Favourites view is no
// longer a dead end — it has a button back to the places near you.
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/maps/place_search.dart' show PlaceRecents;
import 'package:assisto/models.dart';
import 'package:assisto/nearby/area_cache.dart';
import 'package:assisto/screens/nearby_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api.dart';

const _here = (lat: 23.7380, lon: 90.3950);

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

void main() {
  for (final lang in ['en', 'bn']) {
    testWidgets('empty Favourites -> one button back to nearby places ($lang)', (tester) async {
      final (t, _) = await _pump(
          tester, NearbyScreen(debugLocation: _here, cache: AreaCache(MemoryAreaStore())),
          lang: lang);
      await tester.tap(find.widgetWithText(FilterChip, t.nearbyFavourites));
      await tester.pumpAndSettle();
      expect(find.text(t.nearbyNoFavourites), findsOneWidget);
      final btn = find.byKey(const ValueKey('qj_nearby_fav_browse'));
      expect(btn, findsOneWidget);
      expect(find.descendant(of: btn, matching: find.text(t.qjNearbyFavBrowse)), findsOneWidget);
      expect(tester.getSize(btn).height, greaterThanOrEqualTo(48));
      await tester.tap(btn);
      await tester.pumpAndSettle();
      expect(find.text(t.nearbyNoFavourites), findsNothing);
      expect(find.text('Dhaka Medical College Hospital'), findsOneWidget);
    });
  }

  // qjourney (owner V2): "a new recent place replaced the previous one" —
  // every place is kept and the list follows visits + time of day.
  group('recent places', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('keeps more than 5 places; a new one never pushes out the others', () async {
      final day = DateTime(2026, 11, 9, 12);
      for (var i = 0; i < 12; i++) {
        await PlaceRecents.add(
            (name: 'P$i', address: '', lat: 23.7 + i / 100, lng: 90.4), now: day);
      }
      final all = await PlaceRecents.load(now: day);
      expect(all.length, 12);
      expect(all.first.name, 'P11'); // newest first among equals
    });

    test('sorted by how often and by this time of day', () async {
      final morning = DateTime(2026, 11, 9, 9);
      final evening = DateTime(2026, 11, 9, 19);
      const office = (name: 'Office', address: '', lat: 23.78, lng: 90.41);
      const home = (name: 'Home', address: '', lat: 23.75, lng: 90.39);
      for (var d = 0; d < 3; d++) {
        await PlaceRecents.add(office, now: morning);
        await PlaceRecents.add(home, now: evening);
      }
      await PlaceRecents.add((name: 'Shop', address: '', lat: 23.70, lng: 90.30), now: evening);
      expect((await PlaceRecents.load(now: morning)).first.name, 'Office');
      expect((await PlaceRecents.load(now: evening)).first.name, 'Home');
    });
  });
}
