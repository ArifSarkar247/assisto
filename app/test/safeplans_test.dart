// safeplans — Safety plans screen, the "requests used up" sheet and the
// guardian-only ad unlock page:
//   * plan cards from the server numbers; the green "safety is always free"
//     card; the School Safe card never shows a price (Play Payments policy);
//   * not on sale -> honest text, no dead buy buttons;
//   * a child account never sees an ads card / watch button;
//   * the out sheet offers buy / ads / Safe Family only when each works;
//   * an ad counts only after the server says Google verified it;
//   * Bangla: Bangla digits, 200 % text, dark theme render.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:assisto/ads/ads_bridge.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/safe_plans/safe_ad_unlock_screen.dart';
import 'package:assisto/safe_plans/safe_plans_api.dart';
import 'package:assisto/safe_plans/safe_plans_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';
import 'safeplans_fakes.dart';

final en = lookupAppLocalizations(const Locale('en'));
final bn = lookupAppLocalizations(const Locale('bn'));

AppState _state(String lang) {
  final s = AppState();
  s.api = FakeApi();
  s.user = AppUser(id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return s;
}

Widget _app(Widget home, {String lang = 'en', double scale = 1.0, bool dark = false}) =>
    ChangeNotifierProvider<AppState>.value(
      value: _state(lang),
      child: MaterialApp(
        key: UniqueKey(),
        locale: Locale(lang),
        theme: dark ? AssistoTheme.dark : AssistoTheme.light,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
        home: home,
      ),
    );

void main() {
  setUp(() {
    SafePlansDeps.debugBilling = () async => null;
  });
  tearDown(() {
    SafePlansDeps.debugApi = null;
    SafePlansDeps.debugBilling = null;
    SafeAdUnlockScreen.debugShow = null;
  });

  testWidgets('plans screen: cards, always-free card, no school price', (tester) async {
    SafePlansDeps.debugApi = FakeSafeApi(safeStatus());
    await tester.pumpWidget(_app(const SafePlansScreen()));
    await tester.pumpAndSettle();
    expect(find.text(en.spAlwaysFreeTitle), findsOneWidget);
    expect(find.text(en.spRequestsLeft('3')), findsOneWidget);
    expect(find.text(en.spPlanChild), findsOneWidget);
    expect(find.text(en.spChildF3('15')), findsOneWidget);
    await tester.scrollUntilVisible(find.text(en.spSchoolTitle), 200);
    expect(find.textContaining('20'), findsNothing); // never the school price
    // no Play client here: honest "price not loaded" retry, never a dead buy
    expect(find.text(en.spPriceRetry), findsWidgets);
  });

  testWidgets('not on sale: honest text instead of buy buttons', (tester) async {
    SafePlansDeps.debugApi = FakeSafeApi(safeStatus(onSale: false));
    await tester.pumpWidget(_app(const SafePlansScreen()));
    await tester.pumpAndSettle();
    expect(find.text(en.spNotOnSale), findsWidgets);
    expect(find.textContaining('Buy for'), findsNothing);
  });

  testWidgets('child account: no ads card', (tester) async {
    SafePlansDeps.debugApi = FakeSafeApi(safeStatus(adsOk: false, why: 'child_account'));
    await tester.pumpWidget(_app(const SafePlansScreen()));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(find.text(en.spAdsOpen), findsNothing);
  });

  testWidgets('ad unlock page: child account sees no watch button', (tester) async {
    final api = FakeSafeApi(safeStatus(adsOk: false, why: 'child_account'));
    await tester.pumpWidget(_app(SafeAdUnlockScreen(api: api)));
    await tester.pumpAndSettle();
    expect(find.text(en.spAdChild), findsOneWidget);
    expect(find.text(en.spAdWatch), findsNothing);
    expect(api.tickets, isEmpty);
  });

  testWidgets('ad unlock page: counts only after Google verified', (tester) async {
    final api = FakeSafeApi(safeStatus());
    SafeAdUnlockScreen.debugShow = (_) async => RewardOutcome.earned;
    await tester.pumpWidget(_app(SafeAdUnlockScreen(api: api)));
    await tester.pumpAndSettle();
    expect(find.text(en.spAdProgress('2', '3')), findsOneWidget);
    await tester.tap(find.text(en.spAdWatch).first);
    await tester.pumpAndSettle();
    expect(api.tickets, ['request']);
    expect(find.text(en.spAdCounted), findsOneWidget);

    api.ticketStatus = 'rejected';
    SafeAdUnlockScreen.debugShow = (_) async => RewardOutcome.dismissed;
    await tester.tap(find.text(en.spAdWatch).first);
    await tester.pumpAndSettle();
    expect(find.text(en.spAdDismissed), findsOneWidget);
  });

  testWidgets('out sheet: buy / ads / Safe Family, SOS still works line', (tester) async {
    await tester.pumpWidget(_app(Builder(
        builder: (ctx) => Scaffold(
            body: Center(
                child: TextButton(
                    onPressed: () => showSafeCreditsOutSheet(ctx, {
                          'options': {'buy': true, 'ads': true, 'upgrade': true},
                          'ads_for_request': 3,
                        }),
                    child: const Text('go')))))));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text(en.spOutTitle), findsOneWidget);
    expect(find.text(en.spOutBody), findsOneWidget);
    expect(find.text(en.spOutBuy), findsOneWidget);
    expect(find.text(en.spOutAds('3')), findsOneWidget);
    expect(find.text(en.spOutUpgrade), findsOneWidget);
    await tester.tap(find.text(en.spNotNow));
    await tester.pumpAndSettle();
    expect(find.text(en.spOutTitle), findsNothing);
  });

  testWidgets('out sheet: nothing possible -> honest renew line, no dead buttons', (tester) async {
    await tester.pumpWidget(_app(Builder(
        builder: (ctx) => Scaffold(
            body: Center(
                child: TextButton(
                    onPressed: () => showSafeCreditsOutSheet(ctx, {
                          'options': {'buy': false, 'ads': false, 'upgrade': false},
                        }),
                    child: const Text('go')))))));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text(en.spOutNone), findsOneWidget);
    expect(find.text(en.spOutBuy), findsNothing);
  });

  testWidgets('school code sheet: pick child in one tap, wrong code message', (tester) async {
    SafePlansDeps.debugApi = FakeSafeApi(safeStatus());
    await tester.pumpWidget(_app(const SafePlansScreen()));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text(en.spEnterCode), 200);
    await tester.tap(find.text(en.spEnterCode));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, 'Rina'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'WRONG1');
    await tester.pump();
    await tester.tap(find.text(en.spCodeSend));
    await tester.pumpAndSettle();
    expect(find.text(en.spCodeBad), findsOneWidget);
  });

  testWidgets('Bangla, dark, 200 % text: Bangla digits, no overflow', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    SafePlansDeps.debugApi = FakeSafeApi(safeStatus(total: 12));
    await tester.pumpWidget(_app(const SafePlansScreen(), lang: 'bn', scale: 2.0, dark: true));
    await tester.pumpAndSettle();
    expect(find.text(bn.spRequestsLeft('১২')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
