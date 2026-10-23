// p4-world: Unseen World widget tests — the web-answer tile is hidden until
// a search key is connected, Today cards turn off and sync, key-gated cards
// never show, hubs render with honest hidden states, MCQ round flow.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/world/world_ask_screen.dart';
import 'package:assisto/screens/world/world_guide_hub_screen.dart';
import 'package:assisto/screens/world/world_hub_screen.dart';
import 'package:assisto/screens/world/world_jobs_screen.dart';
import 'package:assisto/screens/world/world_mcq_screen.dart';
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

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('hub hides "Ask anything" without a search key', (tester) async {
    await tester.pumpWidget(
        _app(WorldHubScreen(api: FakeWorldApi(searchReady: false))));
    await tester.pumpAndSettle();
    expect(find.text('Ask anything'), findsNothing);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Jobs hub'), findsOneWidget);
    expect(find.text('Government services'), findsOneWidget);
  });

  testWidgets('hub shows "Ask anything" when connected', (tester) async {
    await tester.pumpWidget(_app(WorldHubScreen(api: FakeWorldApi())));
    await tester.pumpAndSettle();
    expect(find.text('Ask anything'), findsOneWidget);
  });

  testWidgets(
      'Today: real cards only, key-gated sports never shown, toggle syncs',
      (tester) async {
    final api = FakeWorldApi();
    await tester.pumpWidget(_app(WorldTodayScreen(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('Prayer times'), findsOneWidget);
    expect(find.text('Weather'), findsOneWidget);
    expect(find.text('Cricket live'), findsNothing); // needs a licensed key
    expect(find.text('Fuel price'), findsNothing); // owner has not entered it
    await tester.tap(find.byTooltip('Choose cards'));
    await tester.pumpAndSettle();
    expect(find.text('Cricket live'),
        findsNothing); // not even offered without a key
    expect(find.text('Not available yet'),
        findsOneWidget); // fuel: honest state in the sheet
    await tester.tap(find.widgetWithText(SwitchListTile, 'Weather'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(api.saved.single['cards']['weather'], false);
    expect(find.text('Weather'), findsNothing);
    expect(find.text('Prayer times'), findsOneWidget);
  });

  testWidgets('Today: Bangla digits in bn', (tester) async {
    await tester.pumpWidget(
        _app(WorldTodayScreen(api: FakeWorldApi(lang: 'bn')), lang: 'bn'));
    await tester.pumpAndSettle();
    expect(find.text('০৪:৪১'), findsOneWidget);
  });

  testWidgets('Ask: answer with numbered sources and charge line',
      (tester) async {
    final api = FakeWorldApi();
    await tester.pumpWidget(_app(WorldAskScreen(api: api, credits: 4)));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('Each new answer uses 4 credits'), findsOneWidget);
    await tester.enterText(
        find.byType(TextField), 'How do I renew an e-passport?');
    await tester.pump();
    await tester.tap(find.byTooltip('Ask'));
    await tester.pumpAndSettle();
    expect(api.asks, 1);
    expect(find.textContaining('[1]'), findsWidgets);
    expect(find.textContaining('epassport.gov.bd'), findsWidgets);
    expect(find.text('4 credits used for this answer.'), findsOneWidget);
  });

  testWidgets('Jobs: alerts hidden without a lawful feed key', (tester) async {
    await tester.pumpWidget(_app(WorldJobsScreen(api: FakeWorldApi())));
    await tester.pumpAndSettle();
    expect(find.textContaining('BPSC'), findsOneWidget);
    expect(find.text('Job alerts'), findsNothing);
  });

  testWidgets('Jobs: alerts shown when connected', (tester) async {
    await tester.pumpWidget(
        _app(WorldJobsScreen(api: FakeWorldApi(alertsReady: true))));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Job alerts'), 200);
    expect(find.text('Job alerts'), findsOneWidget);
  });

  testWidgets(
      'Farmers hub: photo helper hidden without a vision key; AI hidden when off',
      (tester) async {
    await tester.pumpWidget(_app(WorldGuideHubScreen(
        hubId: 'farmers',
        api: FakeWorldApi(photoReady: false, aiReady: false))));
    await tester.pumpAndSettle();
    expect(find.text('Check a crop with a photo'), findsNothing);
    expect(find.text('Ask Assisto AI'), findsNothing);
    expect(find.text('Krishi Call Centre 16123'), findsOneWidget);
  });

  testWidgets('Gov hub: form help + fee with reviewed date', (tester) async {
    await tester.pumpWidget(
        _app(WorldGuideHubScreen(hubId: 'gov', api: FakeWorldApi())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('e-Passport'));
    await tester.pumpAndSettle();
    expect(find.text('Fee'), findsOneWidget);
    expect(find.textContaining('Last reviewed by Assisto'), findsWidgets);
    await tester.scrollUntilVisible(find.text('AI help filling forms'), 200);
    expect(find.text('AI help filling forms'), findsOneWidget);
  });

  testWidgets('Health hub: medicine price link hidden without DGDA data',
      (tester) async {
    await tester.pumpWidget(
        _app(WorldGuideHubScreen(hubId: 'health', api: FakeWorldApi())));
    await tester.pumpAndSettle();
    expect(find.text('Look up official medicine prices'), findsNothing);
  });

  testWidgets('MCQ: answer, finish, see score', (tester) async {
    await tester.pumpWidget(_app(WorldMcqScreen(api: FakeWorldApi())));
    await tester.pumpAndSettle();
    expect(find.text('Question 1 of 2'), findsOneWidget);
    await tester.tap(find.text('Dhaka'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('12'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('See my score'));
    await tester.pumpAndSettle();
    expect(find.text('2 of 2 correct'), findsOneWidget);
    expect(find.text('Right answer: Dhaka'), findsOneWidget);
  });
}
