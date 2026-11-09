// citycov: "Map a stop" field collection — one tap at the phone's own
// location, no names, no free text; waiting reports nearby can be confirmed;
// limit / far answers are explained. Server side: backend/core/tests_citycov.py.
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/city/city_field_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api.dart';

class _Api extends FakeApi {
  final List<(String, Map<String, dynamic>)> posts = [];
  _Api({super.mode});

  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) async {
    posts.add((path, body));
    return super.postJson(path, body);
  }
}

const _here = (lat: 23.8075, lon: 90.3670);

Future<AppLocalizations> _pump(WidgetTester tester, Widget screen, FakeApi api,
    {String lang = 'en', double scale = 1.0, ThemeData? theme}) async {
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
        theme: theme ?? AssistoTheme.light,
        builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
        home: screen,
      )));
  await tester.pumpAndSettle();
  return AppLocalizations.of(tester.element(find.byWidget(screen)));
}

void main() {
  testWidgets('Add a stop here: one tap posts only the location (no name, no text)', (tester) async {
    final api = _Api();
    final t = await _pump(tester, const CityFieldScreen(debugHere: _here), api);
    expect(find.text(t.cityMapBenefit), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('city_map_add_here')));
    await tester.pumpAndSettle();
    final p = api.posts.where((e) => e.$1 == '/city/field-stops').toList();
    expect(p, hasLength(1));
    expect(p.single.$2.keys.toSet(), {'lat', 'lon'});
    expect(find.text(t.cityMapThanks('3')), findsOneWidget);
    // a second tap is not possible (button done)
    final b = tester.widget<FilledButton>(find.byKey(const ValueKey('city_map_add_here')));
    expect(b.onPressed, isNull);
  });

  testWidgets('This bus stops here sends the route id; Yes confirms a waiting report', (tester) async {
    final api = _Api();
    final t = await _pump(tester, const CityFieldScreen(debugHere: _here), api);
    expect(find.text('Shikor Paribahan'), findsWidgets);
    await tester.ensureVisible(find.byKey(const ValueKey('city_map_route_leg-mirpur-a')));
    await tester.pumpAndSettle();
    expect(find.text('Leguna: Mirpur 10 - Kalshi'), findsOneWidget);
    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('city_map_route_leg-mirpur-a')), matching: find.text(t.cityMapThisBus)));
    await tester.pumpAndSettle();
    expect(api.posts.last.$2['route_id'], 'leg-mirpur-a');
    expect(api.posts.last.$2.containsKey('name'), isFalse);
    // waiting report 41 (2 of 3) -> my "yes" confirms it
    expect(find.textContaining(t.cityMapPeople('2', '3')), findsOneWidget);
    await tester.pump(const Duration(seconds: 6)); // let the snack bar go
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('city_map_item_41')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('city_map_item_41')), matching: find.text(t.cityMapYes)));
    await tester.pumpAndSettle();
    expect(api.posts.last.$2['id'], 41);
    expect(find.text(t.cityMapConfirmed), findsOneWidget);
    // my own report (42) cannot be confirmed by me again
    expect(find.descendant(of: find.byKey(const ValueKey('city_map_item_42')), matching: find.text(t.cityMapYes)),
        findsNothing);
  });

  testWidgets('empty area: benefit line, big button, how-to', (tester) async {
    final t = await _pump(tester, const CityFieldScreen(debugHere: _here), _Api(mode: FakeMode.empty));
    expect(find.byKey(const ValueKey('city_map_add_here')), findsOneWidget);
    expect(find.text(t.cityMapNoBuses), findsOneWidget);
    expect(find.text(t.cityMapNoneWaiting), findsOneWidget);
  });

  testWidgets('Bangla, 200% font, dark: no overflow', (tester) async {
    final t = await _pump(tester, const CityFieldScreen(debugHere: _here), _Api(),
        lang: 'bn', scale: 2.0, theme: AssistoTheme.dark);
    expect(tester.takeException(), isNull);
    expect(find.text(t.cityMapAddHere), findsOneWidget);
    expect(find.textContaining('৩'), findsWidgets); // Bangla digits
  });
}
