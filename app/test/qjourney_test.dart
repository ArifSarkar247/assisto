// qjourney (quality push 9 Nov): Nearby's empty Favourites view is no
// longer a dead end — it has a button back to the places near you.
import 'package:assisto/l10n/app_localizations.dart';
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
}
