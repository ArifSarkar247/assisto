// plans-credits (board row 7; LIVE_TRUTH: "the buy-credits button is covered
// by the trial card", "one place shows one price, another a different one").
//  * Plans page at PHONE size with a 3-button nav bar: "Buy credits" is on the
//    first screen, tappable, above the nav bar — and lands ON the packs;
//  * Credits page: a "Buy credits" button in the balance card only when a
//    pack can really be bought (NO SHOWPIECES), it scrolls to the packs;
//  * the CCTV plan line on the Plans page shows the SERVER's numbers
//    (bn digits in Bangla), "open to see prices" when they are not loaded.
import 'package:assisto/feature_flags.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/plans_v2/plans_buy_section.dart';
import 'package:assisto/screens/credits_screen.dart';
import 'package:assisto/screens/plans_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api.dart';

const _phone = Size(360, 800);
const _nav = 48.0; // 3-button navigation bar

Widget _wrap(Widget child, String lang) => MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AssistoTheme.light,
      home: child,
    );

Future<void> _pump(WidgetTester tester, Widget screen,
    {String lang = 'en', Size size = _phone}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2.0;
  tester.view.padding = const FakeViewPadding(bottom: _nav * 2);
  tester.view.viewPadding = const FakeViewPadding(bottom: _nav * 2);
  addTearDown(tester.view.reset);
  final s = AppState()
    ..api = FakeApi(lang: lang)
    ..user = AppUser(
        id: 1,
        name: 'Me',
        phone: '+8801700000000',
        email: '',
        autonomyLevel: 2,
        language: lang)
    ..locale = Locale(lang)
    ..loading = false;
  await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(value: s, child: _wrap(screen, lang)));
  await tester.pumpAndSettle();
}

/// The widget is fully on screen and above the navigation bar.
void _expectClearOfNavBar(WidgetTester tester, Finder f) {
  expect(f, findsOneWidget);
  final r = tester.getRect(f);
  expect(r.top, greaterThanOrEqualTo(0));
  expect(r.bottom, lessThanOrEqualTo(_phone.height - _nav),
      reason: 'under the navigation bar: $r');
  expect(r.height, greaterThanOrEqualTo(48));
}

void main() {
  tearDown(() {
    FakeApi.payLive = false;
    FakeApi.planSlug = 'premium';
    FeatureFlags.instance.resetForTest();
  });

  for (final lang in ['en', 'bn']) {
    testWidgets('$lang: Plans page — Buy credits on the first screen, lands on the packs',
        (tester) async {
      FakeApi.payLive = true;
      FakeApi.planSlug = 'free';
      await _pump(tester, const PlansScreen(), lang: lang);
      final buy = find.byKey(const Key('plans-buy-credits'));
      // NOT scrolled: it is visible the moment the page opens
      _expectClearOfNavBar(tester, buy);
      await tester.tap(buy);
      await tester.pumpAndSettle();
      expect(find.byType(CreditsScreen), findsOneWidget);
      // the screen opened ON the packs (no hunting below the balance cards)
      _expectClearOfNavBar(tester, find.byKey(const ValueKey('pack-buy-p20')));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Credits page: Buy credits in the balance card only with a live channel',
      (tester) async {
    FakeApi.payLive = false;
    await _pump(tester, const CreditsScreen());
    expect(find.byKey(const Key('credits-buy-top')), findsNothing); // no showpiece
    FakeApi.payLive = true;
    await _pump(tester, const CreditsScreen());
    final top = find.byKey(const Key('credits-buy-top'));
    _expectClearOfNavBar(tester, top);
    await tester.tap(top);
    await tester.pumpAndSettle();
    _expectClearOfNavBar(tester, find.byKey(const ValueKey('pack-buy-p50')));
  });

  testWidgets('Credits page: the last row scrolls clear of the navigation bar',
      (tester) async {
    FakeApi.payLive = true;
    await _pump(tester, const CreditsScreen());
    final scroll = tester.widget<SingleChildScrollView>(find
        .descendant(
            of: find.byType(RefreshIndicator), matching: find.byType(SingleChildScrollView))
        .first);
    final pad = scroll.padding!.resolve(TextDirection.ltr);
    expect(pad.bottom, greaterThanOrEqualTo(_nav), reason: 'withNavBarInset missing');
  });

  group('CCTV plan line = the server\'s numbers', () {
    setUp(() => FeatureFlags.instance
        .applyForTest({'features': {'cctv_watchman': true}, 'preview': <String>[]}));

    Map<String, dynamic> cctv({bool trial = true}) => {
          'base_cameras': 3,
          'base_price': 777,
          'tiers': [
            {'cameras': 3, 'monthly': 777, 'yearly': 9324},
          ],
          'trial_days': 5,
          'trial_available': trial,
        };

    Future<String> line(WidgetTester tester, String lang, Map<String, dynamic>? c) async {
      await tester.pumpWidget(_wrap(
          Scaffold(
              body: PlansBuySection(
                  flavour: 'apk', preview: const {'recommend': null}, cctvPreview: c)),
          lang));
      await tester.pumpAndSettle();
      return tester.widget<Text>(find.byKey(const Key('bi-plans-cctv-line'))).data!;
    }

    testWidgets('en / bn / no trial / not loaded', (tester) async {
      expect(await line(tester, 'en', cctv()), 'From ৳777 a month for 3 cameras · 5 days free');
      expect(await line(tester, 'bn', cctv()), '৩টি ক্যামেরা মাসে ৳৭৭৭ থেকে · ৫ দিন ফ্রি');
      expect(await line(tester, 'en', cctv(trial: false)), 'From ৳777 a month for 3 cameras');
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      expect(await line(tester, 'en', null), t.pcCctvSeePrices);
      expect(await line(tester, 'en', {'tiers': []}), t.pcCctvSeePrices); // never a typed price
    });
  });
}
