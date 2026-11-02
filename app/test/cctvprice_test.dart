// cctvprice — the CCTV plan on the app side:
//   * base plan ids for a camera count (1 camera buys the 2-camera base),
//     add-on plan ids; Play offer map + the exact offer picked (trial only
//     when Play lists it, never another base plan);
//   * buying: Play purchase -> server verify -> finish; restore re-sends only
//     CCTV tokens;
//   * the screen: tier picker 1..10 with exact prices (Bangla digits), yearly
//     = 12x, trial badge only when eligible, >10 = contact us, active plan =
//     change count, add-on per camera, website APK / not-on-sale honest text;
//     bn/en, light/dark, 200 % text, 48 dp tap targets.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:provider/provider.dart';

import 'package:assisto/billing/cctv_plan_screen.dart';
import 'package:assisto/billing/cctv_plan_source.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/payments/play_billing_impl.dart';
import 'package:assisto/payments/store_billing.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'cctvprice_fakes.dart';
import 'cctvprice_shots.dart';
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

Widget _app(Widget home, {String lang = 'en', double scale = 1.0, bool dark = false}) =>
    ChangeNotifierProvider<AppState>.value(
      value: _state(),
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

Future<void> _settle(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void _phone(WidgetTester tester, {double height = 2400}) {
  tester.view.physicalSize = Size(360 * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

PricingPhaseWrapper _phase(String f) => PricingPhaseWrapper(
    billingCycleCount: 0,
    billingPeriod: 'P1M',
    formattedPrice: f,
    priceAmountMicros: 1,
    priceCurrencyCode: 'BDT',
    recurrenceMode: RecurrenceMode.infiniteRecurring);

SubscriptionOfferDetailsWrapper _offer(String base, List<String> prices, {String? offerId}) =>
    SubscriptionOfferDetailsWrapper(
        basePlanId: base,
        offerId: offerId,
        offerTags: const [],
        offerIdToken: '$base-$offerId',
        pricingPhases: [for (final p in prices) _phase(p)]);

List<GooglePlayProductDetails> _cctv() =>
    GooglePlayProductDetails.fromProductDetails(ProductDetailsWrapper(
      description: '',
      name: 'CCTV',
      productId: 'cctv_plan',
      productType: ProductType.subs,
      title: 'CCTV',
      subscriptionOfferDetails: [
        _offer('c02-monthly', ['BDT 500.00']),
        _offer('c02-monthly', ['Free', 'BDT 500.00'], offerId: 'trial-7d'),
        _offer('c03-monthly', ['BDT 750.00']),
        _offer('c03-yearly', ['BDT 9,000.00']),
      ],
    ));

void main() {
  test('ARB placeholder order pinned (gen-l10n follows the metadata order)', () {
    expect(en.cplUsed('U', 'N'), 'U of N cameras in use');
    expect(en.cplChange('N', 'P'), 'Change to N cameras — P');
    expect(en.cplAddonActive('D', 'N'), 'Video add-on on: D days on N cameras');
    expect(en.cplHowPriced('B', 'E'), startsWith('B tk a month covers 2 cameras. Each extra camera is E'));
    expect(en.cplCurrentLine('N', 'P'), 'N cameras · P');
    expect(en.cplLimitsLine('G', 'A'), allOf(contains('G GB'), contains('A per camera')));
  });

  group('plan ids + Play offers', () {
    test('base plan per camera count; 1 camera buys the 2-camera base', () {
      expect(cctvBasePlan(1, false), 'c02-monthly');
      expect(cctvBasePlan(2, true), 'c02-yearly');
      expect(cctvBasePlan(10, false), 'c10-monthly');
      expect(cctvAddonPlan(7, 1), 'd7-c01');
      expect(cctvAddonPlan(30, 10), 'd30-c10');
    });

    test('offer map: base offers by base plan, the trial as base#offer (recurring price)', () {
      final m = playOfferMap(_cctv());
      expect(m['c02-monthly'], 'BDT 500.00');
      expect(m['c02-monthly#trial-7d'], 'BDT 500.00');
      expect(m['c03-yearly'], 'BDT 9,000.00');
    });

    test('the exact offer is bought, never another base plan', () {
      final l = _cctv();
      final trial = pickPlayOffer(l, basePlanId: 'c02-monthly', offerId: 'trial-7d')
          as GooglePlayProductDetails;
      expect(trial.productDetails.subscriptionOfferDetails![trial.subscriptionIndex!].offerId,
          'trial-7d');
      final base = pickPlayOffer(l, basePlanId: 'c02-monthly') as GooglePlayProductDetails;
      expect(base.productDetails.subscriptionOfferDetails![base.subscriptionIndex!].offerId, isNull);
      expect(pickPlayOffer(l, basePlanId: 'c05-monthly'), isNull);
      expect(pickPlayOffer(l, basePlanId: 'c03-monthly', offerId: 'trial-7d'), isNull);
    });
  });

  group('buyer', () {
    test('purchase -> server verify -> finish', () async {
      final api = FakeCctvApi();
      final store = FakeOffersStore();
      final b = CctvPlanBuyer(api, billing: () async => store);
      expect(await b.available(), isTrue);
      final r = await b.buy(
          productId: 'cctv_plan', basePlanId: 'c02-monthly', offerId: 'trial-7d', accountId: 'u1-abc');
      expect(r, CctvBuyStatus.done);
      expect(store.bought, ['cctv_plan/c02-monthly/trial-7d/u1-abc']);
      expect(api.verified, ['cctv_plan:ctok']);
      expect(store.finished, ['ctok']);
    });

    test('website APK: no Play client = unavailable, nothing bought', () async {
      final b = CctvPlanBuyer(FakeCctvApi(), billing: () async => null);
      expect(await b.available(), isFalse);
      expect(await b.buy(productId: 'cctv_plan', basePlanId: 'c02-monthly', accountId: 'x'),
          CctvBuyStatus.unavailable);
      expect(await b.offers('cctv_plan'), isEmpty);
    });

    test('restore re-sends only CCTV tokens', () async {
      final api = FakeCctvApi();
      final store = FakeOffersStore()
        ..ownedList = const [
          StoreOwned('cctv_plan', 't1'),
          StoreOwned('assisto_premium', 't2'),
          StoreOwned('cctv_video', 't3'),
        ];
      final b = CctvPlanBuyer(api, billing: () async => store);
      expect(await b.restore({'cctv_plan', 'cctv_video'}), 2);
      expect(api.verified, ['cctv_plan:t1', 'cctv_video:t3']);
    });
  });

  group('screen', () {
    testWidgets('new user (bn): exact prices, Bangla digits, trial badge, yearly 12x', (tester) async {
      _phone(tester);
      final api = FakeCctvApi();
      final store = FakeOffersStore();
      await tester.pumpWidget(_app(
          CctvPlanScreen(api: api, buyer: CctvPlanBuyer(api, billing: () async => store)),
          lang: 'bn'));
      await _settle(tester);
      expect(find.text(bn.cplNoPlan), findsOneWidget);
      expect(find.text(bn.cplPerMonth('৫০০')), findsOneWidget);
      expect(find.text(bn.cplTrialBadge), findsOneWidget);
      expect(find.text(bn.cplStartTrial), findsOneWidget);
      // 3 cameras
      await tester.tap(find.text('৩'));
      await _settle(tester);
      expect(find.text(bn.cplPerMonth('৭৫০')), findsOneWidget);
      expect(find.text(bn.cplTrialOnlyBase), findsOneWidget);
      expect(find.text(bn.cplBuy(bn.cplPerMonth('৭৫০'))), findsOneWidget);
      // yearly = exactly 12 x
      await tester.tap(find.text(bn.cplYearly));
      await _settle(tester);
      expect(find.text(bn.cplPerYear('৯,০০০')), findsOneWidget);
      expect(find.text(bn.cplYearlyMath('৭৫০')), findsOneWidget);
      // 10 cameras = 2,500
      await tester.tap(find.text(bn.cplYearly));
      await tester.tap(find.text('১০'));
      await _settle(tester);
      expect(find.text(bn.cplPerMonth('২,৫০০')), findsOneWidget);
      // the unpaid line is always there
      expect(find.textContaining('30 days'), findsOneWidget);
    });

    testWidgets('trial: bought with the trial offer, then verified', (tester) async {
      _phone(tester);
      final api = FakeCctvApi();
      final store = FakeOffersStore();
      await tester.pumpWidget(_app(
          CctvPlanScreen(api: api, buyer: CctvPlanBuyer(api, billing: () async => store))));
      await _settle(tester);
      await tester.tap(find.text(en.cplStartTrial));
      await _settle(tester);
      expect(store.bought, ['cctv_plan/c02-monthly/trial-7d/u1-abc']);
      expect(find.text(en.cplDone), findsOneWidget);
    });

    testWidgets('no trial when Play does not list it for this Google account', (tester) async {
      _phone(tester);
      final api = FakeCctvApi();
      final store = FakeOffersStore()..offerMap = {'c02-monthly': 'BDT 500.00'};
      await tester.pumpWidget(_app(
          CctvPlanScreen(api: api, buyer: CctvPlanBuyer(api, billing: () async => store))));
      await _settle(tester);
      expect(find.text(en.cplTrialBadge), findsNothing);
      await tester.tap(find.text(en.cplBuy(en.cplPerMonth('500'))));
      await _settle(tester);
      expect(store.bought, ['cctv_plan/c02-monthly//u1-abc']);
    });

    testWidgets('more than 10 cameras = contact us', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(CctvPlanScreen(
          api: FakeCctvApi(), preview: cctvPlanPayload(), previewOffers: kCctvOffers)));
      await _settle(tester);
      await tester.tap(find.text(en.cplMoreThan10));
      await _settle(tester);
      expect(find.text(en.cplContactButton), findsOneWidget);
      expect(find.text(en.cplStartTrial), findsNothing);
    });

    testWidgets('active plan: change count, current badge, add-on pick', (tester) async {
      _phone(tester);
      final api = FakeCctvApi(cctvPlanPayload(
          trial: false,
          used: 3,
          status: cctvActiveStatus(cams: 3, addon: true),
          addonCams: const [11],
          cameras: const [
            {'id': 11, 'name': 'Gate', 'vendor': 'imou'},
            {'id': 12, 'name': 'Till', 'vendor': 'phone'},
          ]));
      final store = FakeOffersStore();
      await tester.pumpWidget(_app(
          CctvPlanScreen(api: api, buyer: CctvPlanBuyer(api, billing: () async => store))));
      await _settle(tester);
      expect(find.text(en.cplCurrentLine('3', en.cplMonthly)), findsOneWidget);
      expect(find.text(en.cplCurrentBadge), findsWidgets);
      expect(find.text(en.cplTrialBadge), findsNothing);
      await tester.tap(find.text('5'));
      await _settle(tester);
      final change = find.text(en.cplChange('5', en.cplPerMonth('1,250')));
      expect(change, findsOneWidget);
      await tester.tap(change);
      await _settle(tester);
      expect(store.bought, ['cctv_plan/c05-monthly//u1-abc']);
      // add-on: choose the second camera
      await tester.scrollUntilVisible(find.text('Till'), 300);
      await tester.tap(find.text('Till'));
      await _settle(tester);
      expect(api.saved, [12, 11]);
    });

    testWidgets('not on sale / website APK: honest text, no buy button', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(CctvPlanScreen(
          api: FakeCctvApi(), preview: cctvPlanPayload(onSale: false), previewOffers: kCctvOffers)));
      await _settle(tester);
      expect(find.text(en.cplSaleSoon), findsWidgets);
      expect(find.text(en.cplStartTrial), findsNothing);
      await tester.pumpWidget(_app(CctvPlanScreen(api: FakeCctvApi(), preview: cctvPlanPayload())));
      await _settle(tester);
      expect(find.text(en.cplPlayOnly), findsOneWidget);
      expect(find.text(en.cplStartTrial), findsNothing);
    });

    testWidgets('load error offers retry', (tester) async {
      _phone(tester);
      final api = FakeCctvApi()..fail = true;
      await tester.pumpWidget(_app(
          CctvPlanScreen(api: api, buyer: CctvPlanBuyer(api, billing: () async => null))));
      await _settle(tester);
      expect(find.text(en.cplRetry), findsOneWidget);
      api.fail = false;
      await tester.tap(find.text(en.cplRetry));
      await _settle(tester);
      expect(find.text(en.cplNoPlan), findsOneWidget);
    });

    testWidgets('48 dp tap targets', (tester) async {
      _phone(tester);
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_app(CctvPlanScreen(
          api: FakeCctvApi(), preview: cctvPlanPayload(), previewOffers: kCctvOffers)));
      await _settle(tester);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      handle.dispose();
    });

    for (final lang in ['bn', 'en']) {
      for (final dark in [false, true]) {
        testWidgets('plan screens at 200% text — $lang ${dark ? 'dark' : 'light'}', (tester) async {
          _phone(tester, height: 800);
          for (final e in cctvpriceShots.entries) {
            await tester.pumpWidget(_app(e.value(lang), lang: lang, scale: 2.0, dark: dark));
            await _settle(tester, 6);
            final err = tester.takeException();
            expect(err, isNull, reason: '${e.key} ($lang, 2.0x): $err');
          }
        });
      }
    }
  });
}
