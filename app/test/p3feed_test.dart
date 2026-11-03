// p3feed (owner PART 3): Today feed from official sources only — Bangladesh
// Bank's rate leads with an Official badge + date, other currencies are
// labelled indicative, official notice links open, cards with no real data
// sit under "Not connected yet" with the honest reason, and an offline phone shows
// today's prayer times from the cached week.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/world/world_today_screen.dart';
import 'package:assisto/state.dart';

import 'world_fake.dart';

Widget _app(Widget child, {String lang = 'en'}) =>
    ChangeNotifierProvider<AppState>(
      create: (_) => AppState(),
      child: MaterialApp(
        locale: Locale(lang),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: child,
      ),
    );

class _DownApi extends FakeWorldApi {
  @override
  Future<Map<String, dynamic>> today() async => throw StateError('offline');
}

String _d(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('official BB rate leads with badge, date and indicative label',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(WorldTodayScreen(api: FakeWorldApi())));
    await tester.pumpAndSettle();
    expect(find.text('Bangladesh Bank rate — 1 US dollar'), findsOneWidget);
    expect(find.text('Official'), findsOneWidget);
    expect(find.textContaining('Rate date:'), findsOneWidget);
    expect(find.textContaining('Source: Bangladesh Bank'), findsOneWidget);
    expect(find.textContaining('indicative market rate'), findsOneWidget);
  });

  testWidgets('no official row until the owner enters it', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
        _app(WorldTodayScreen(api: FakeWorldApi(officialFx: false))));
    await tester.pumpAndSettle();
    expect(find.text('Official'), findsNothing);
    expect(find.textContaining('indicative market rate'), findsNothing);
    expect(find.text('US dollar (USD)'), findsOneWidget);
  });

  testWidgets('notices card lists official links grouped, 48dp rows',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(WorldTodayScreen(api: FakeWorldApi())));
    await tester.pumpAndSettle();
    expect(find.text('Official notices & links'), findsOneWidget);
    expect(find.text('Electricity / load-shedding'), findsOneWidget);
    final tile = find.widgetWithText(ListTile, 'DESCO (Dhaka North) — power notices');
    expect(tile, findsOneWidget);
    expect(tester.getSize(tile).height, greaterThanOrEqualTo(48));
  });

  testWidgets('cards with no real data are under Not connected yet with a reason',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(WorldTodayScreen(api: FakeWorldApi())));
    await tester.pumpAndSettle();
    expect(find.text('Not connected yet'), findsOneWidget);
    expect(
        find.text(
            'Cricket live — not connected — no licensed source yet'),
        findsOneWidget);
    expect(find.textContaining('official figure not entered yet'),
        findsOneWidget);
    expect(find.text('Cricket live'), findsNothing); // never a fake card
  });

  testWidgets('offline: cached week gives today\'s prayer times',
      (tester) async {
    final today = _d(DateTime.now());
    final cached = {
      'city': {'id': 'dhaka', 'name': 'Dhaka'},
      'cards': {
        'prayer': {
          'times': {'fajr': '04:41', 'isha': '18:37'},
          'next': 'fajr',
          'note': 'Local calculation',
          'days': [
            {
              'date': today,
              'times': {'fajr': '04:52', 'isha': '18:31'}
            },
          ],
        },
      },
      'hidden': <String, String>{},
    };
    SharedPreferences.setMockInitialValues(
        {'world_cache_v1_today_en': jsonEncode(cached)});
    await tester.pumpWidget(_app(WorldTodayScreen(api: _DownApi())));
    await tester.pumpAndSettle();
    expect(find.text('04:52'), findsOneWidget);
    expect(find.text('04:41'), findsNothing);
  });

  testWidgets('Bangla: official rate in Bangla digits', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(
        WorldTodayScreen(api: FakeWorldApi(lang: 'bn')),
        lang: 'bn'));
    await tester.pumpAndSettle();
    expect(find.text('৳১২২.০০'), findsOneWidget);
    expect(find.text('অফিসিয়াল'), findsOneWidget);
    expect(find.text('এখনো সংযুক্ত নয়'), findsOneWidget);
  });
}
