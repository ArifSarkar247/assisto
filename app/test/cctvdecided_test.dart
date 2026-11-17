// cctvprice — the owner's CCTV decisions (17 Nov 2026 12:35) on the app side:
//   * the trial copy says honestly that EZVIZ cameras are not in the trial;
//   * an EZVIZ owner (server trial_block = ezviz) gets no trial button, only
//     the honest line, and buys the plan directly;
//   * Premium AI (400 tk per camera per month) shows ONLY when the server
//     says it is on sale (never a dead card) and buys ai-cNN from Play.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:assisto/billing/cctv_plan_screen.dart';
import 'package:assisto/billing/cctv_plan_source.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'cctvprice_fakes.dart';
import 'fake_api.dart';

final en = lookupAppLocalizations(const Locale('en'));
final bn = lookupAppLocalizations(const Locale('bn'));

AppState _state() {
  final s = AppState();
  s.api = FakeApi();
  s.user = AppUser(id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  return s;
}

Widget _app(Widget home, {String lang = 'en', double scale = 1.0}) =>
    ChangeNotifierProvider<AppState>.value(
      value: _state(),
      child: MaterialApp(
        key: UniqueKey(),
        locale: Locale(lang),
        theme: AssistoTheme.light,
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

Future<void> _settle(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void _phone(WidgetTester tester, {double height = 2600}) {
  tester.view.physicalSize = Size(360 * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('trial copy says EZVIZ is not in the trial (bn)', (tester) async {
    _phone(tester);
    final api = FakeCctvApi();
    final store = FakeOffersStore();
    await tester.pumpWidget(_app(
        CctvPlanScreen(api: api, buyer: CctvPlanBuyer(api, billing: () async => store)),
        lang: 'bn'));
    await _settle(tester);
    expect(find.text(bn.cplTrialBadge), findsOneWidget);
    expect(find.byKey(const Key('cpl-trial-no-ezviz')), findsOneWidget);
    expect(find.text(bn.cplTrialNoEzviz), findsOneWidget);
    expect(bn.cplTrialNoEzviz, contains('EZVIZ'));
    expect(bn.cplTrialNoEzviz, contains('৭'));
  });

  testWidgets('EZVIZ owner: no trial, honest line, buys the plan directly', (tester) async {
    _phone(tester);
    final api = FakeCctvApi(cctvPlanPayload(trial: false, trialBlock: 'ezviz'));
    final store = FakeOffersStore();
    await tester.pumpWidget(_app(
        CctvPlanScreen(api: api, buyer: CctvPlanBuyer(api, billing: () async => store))));
    await _settle(tester);
    expect(find.text(en.cplStartTrial), findsNothing);
    expect(find.text(en.cplTrialBadge), findsNothing);
    expect(find.byKey(const Key('cpl-trial-ezviz-you')), findsOneWidget);
    expect(find.text(en.cplTrialEzvizYou), findsOneWidget);
    await tester.tap(find.text(en.cplBuy(en.cplPerMonth('500'))));
    await _settle(tester);
    expect(store.bought, ['cctv_plan/c02-monthly//u1-abc']);   // no trial offer
  });

  testWidgets('Premium AI hidden while not on sale (never a dead card)', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(CctvPlanScreen(
        api: FakeCctvApi(),
        preview: cctvPlanPayload(trial: false, status: cctvActiveStatus(cams: 3)),
        previewOffers: kCctvOffers)));
    await _settle(tester);
    expect(find.byKey(const Key('cpl-premium-ai')), findsNothing);
  });

  testWidgets('Premium AI on sale: 400 per camera, buys ai-c03 (bn digits)', (tester) async {
    _phone(tester);
    final api = FakeCctvApi(cctvPlanPayload(
        trial: false, used: 3, premiumOnSale: true, status: cctvActiveStatus(cams: 3)));
    final store = FakeOffersStore();
    await tester.pumpWidget(_app(
        CctvPlanScreen(api: api, buyer: CctvPlanBuyer(api, billing: () async => store)),
        lang: 'bn'));
    await _settle(tester);
    await tester.ensureVisible(find.byKey(const Key('cpl-premium-ai')));
    await _settle(tester, 3);
    expect(find.text(bn.cplPremiumPrice('৪০০')), findsOneWidget);
    expect(find.text(bn.cplPremiumTotal('৩', '১,২০০')), findsOneWidget);
    await tester.tap(find.text(bn.cplPremiumBuy('১,২০০')));
    await _settle(tester);
    expect(store.bought, ['cctv_premium_ai/ai-c03//u1-abc']);
    expect(api.verified, ['cctv_premium_ai:ctok']);
  });

  testWidgets('Premium AI needs the plan first', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(CctvPlanScreen(
        api: FakeCctvApi(),
        preview: cctvPlanPayload(premiumOnSale: true),
        previewOffers: kCctvOffers)));
    await _settle(tester);
    await tester.ensureVisible(find.byKey(const Key('cpl-premium-ai')));
    await _settle(tester, 3);
    expect(find.text(en.cplPremiumNeedsPlan), findsOneWidget);
  });

  testWidgets('decided states at 200% text, bn + en, no overflow', (tester) async {
    _phone(tester, height: 800);
    for (final lang in ['bn', 'en']) {
      for (final p in [
        cctvPlanPayload(trial: false, trialBlock: 'ezviz'),
        cctvPlanPayload(trial: false, used: 3, premiumOnSale: true, status: cctvActiveStatus(cams: 3)),
      ]) {
        await tester.pumpWidget(_app(
            CctvPlanScreen(api: FakeCctvApi(), preview: p, previewOffers: kCctvOffers),
            lang: lang,
            scale: 2.0));
        await _settle(tester, 6);
        expect(tester.takeException(), isNull);
      }
    }
  });
}
