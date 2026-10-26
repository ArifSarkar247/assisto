// pay-e2e (follow-up): Business yearly on the Plans screen (monthly <-> yearly
// toggle sends the right sku, server price shown, hidden when not sold),
// Business yearly on Google Play (base plan missing -> honest "unavailable",
// nothing verified), and the Seller Agent plan card on the Play build (no
// Play product -> honest note, no dead buy button), and the owner rule
// (26 Oct): the Play build never offers EPS / links to /premium for digital
// goods.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/payments/checkout_sheet.dart';
import 'package:assisto/payments/payments_api.dart';
import 'package:assisto/payments/play_prices.dart';
import 'package:assisto/payments/store_billing.dart';
import 'package:assisto/screens/business/bizagent/seller_agent_screen.dart';
import 'package:assisto/screens/credits_screen.dart';
import 'package:assisto/screens/plans_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';
import 'p1_bizagent_fakes.dart';
import 'pay1_fakes.dart';

Widget _wrap(Widget child, {String lang = 'en'}) => MaterialApp(
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

Future<AppLocalizations> _pumpScreen(WidgetTester tester, Widget screen,
    {String lang = 'en'}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1080, 7000);
  tester.view.devicePixelRatio = 2.0;
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
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: s, child: _wrap(screen, lang: lang)));
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return AppLocalizations.of(tester.element(find.byType(screen.runtimeType)));
}

Future<String> _tapBusinessBuy(WidgetTester tester) async {
  final btn = find.byKey(const ValueKey('plan-buy-business'));
  await tester.ensureVisible(btn);
  await tester.tap(btn);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  final sku = tester.widget<CheckoutSheet>(find.byType(CheckoutSheet)).sku;
  Navigator.of(tester.element(find.byType(CheckoutSheet))).pop();
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(find.byType(CheckoutSheet), findsNothing);
  return sku;
}

Future<void> _toggle(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  tearDown(() {
    FakeApi.payLive = false;
    FakeApi.planSlug = 'premium';
    FakeApi.payOmit = {};
    FakeApi.playLive = false;
    debugPayFlavour = null;
    StoreBilling.debugOverride = null;
    PlayPrices.debugReset();
  });

  group('Plans: Business yearly', () {
    testWidgets('monthly <-> yearly toggle sends the matching sku + server price',
        (tester) async {
      FakeApi.payLive = true;
      FakeApi.planSlug = 'free';
      final t = await _pumpScreen(tester, const PlansScreen());
      expect(await _tapBusinessBuy(tester), 'business_monthly');
      await _toggle(tester, t.plansYearly);
      expect(find.textContaining('5,808'), findsOneWidget); // server yearly price
      expect(await _tapBusinessBuy(tester), 'business_yearly');
      await _toggle(tester, t.plansMonthly);
      expect(find.textContaining('5,808'), findsNothing);
      expect(await _tapBusinessBuy(tester), 'business_monthly');
    });

    testWidgets('on Business monthly: yearly card is buyable (period change)',
        (tester) async {
      FakeApi.payLive = true;
      FakeApi.planSlug = 'business';
      final t = await _pumpScreen(tester, const PlansScreen());
      // monthly view: Business is the current plan, no buy button
      expect(find.byKey(const ValueKey('plan-buy-business')), findsNothing);
      await _toggle(tester, t.plansYearly);
      expect(await _tapBusinessBuy(tester), 'business_yearly');
    });

    testWidgets('server does not sell Business yearly -> card stays monthly',
        (tester) async {
      FakeApi.payLive = true;
      FakeApi.planSlug = 'free';
      FakeApi.payOmit = {'business_yearly'};
      final t = await _pumpScreen(tester, const PlansScreen());
      await _toggle(tester, t.plansYearly);
      expect(find.textContaining('5,808'), findsNothing);
      expect(await _tapBusinessBuy(tester), 'business_monthly');
    });

    testWidgets('no live channel -> no Business buy button in either view',
        (tester) async {
      FakeApi.payLive = false;
      FakeApi.planSlug = 'free';
      final t = await _pumpScreen(tester, const PlansScreen(), lang: 'bn');
      expect(find.byKey(const ValueKey('plan-buy-business')), findsNothing);
      await _toggle(tester, t.plansYearly);
      expect(find.byKey(const ValueKey('plan-buy-business')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  // credout (owner 26 Oct): the Play build shows ONLY Play's own prices.
  group('Play build: prices come from Google Play', () {
    testWidgets('plans show Play formattedPrice (monthly + annual), never the '
        'server taka', (tester) async {
      debugPayFlavour = 'play';
      FakeApi.playLive = true;
      FakeApi.planSlug = 'free';
      final billing = FakeStoreBilling();
      StoreBilling.debugOverride = billing;
      final t = await _pumpScreen(tester, const PlansScreen());
      final premium = find.byKey(const ValueKey('plan-price-premium'));
      expect(tester.widget<Text>(premium).data, 'BDT 199.00');
      expect(tester.widget<Text>(find.byKey(const ValueKey('plan-price-business'))).data,
          'BDT 499.00');
      expect(find.text('৳199'), findsNothing);
      expect(find.text('৳499'), findsNothing);
      await _toggle(tester, t.plansYearly);
      expect(tester.widget<Text>(find.byKey(const ValueKey('plan-price-annual'))).data,
          'BDT 1,990.00');
      expect(tester.widget<Text>(find.byKey(const ValueKey('plan-price-business'))).data,
          'BDT 5,808.00');
      expect(find.textContaining('5,808'), findsOneWidget); // Play's, not ৳5,808
      // one cached query for every Play product (plans + packs)
      expect(billing.priceQueries.length, 1);
      expect(billing.priceQueries.single,
          containsAll(<String>['assisto_premium', 'assisto_business', 'credits_p20']));
    });

    testWidgets('store unavailable: honest "price unavailable", buy disabled, retry',
        (tester) async {
      debugPayFlavour = 'play';
      FakeApi.playLive = true;
      FakeApi.planSlug = 'free';
      StoreBilling.debugOverride = null; // no Play client -> no prices
      final t = await _pumpScreen(tester, const PlansScreen());
      expect(tester.widget<Text>(find.byKey(const ValueKey('plan-price-premium'))).data,
          t.payPriceUnavailable);
      expect(find.byKey(const ValueKey('plan-buy-premium')), findsNothing);
      expect(find.byKey(const ValueKey('plan-price-retry-premium')), findsOneWidget);
      expect(find.text('৳199'), findsNothing);
      // the store is back -> retry shows Play's price and the buy button
      StoreBilling.debugOverride = FakeStoreBilling();
      final retry = find.byKey(const ValueKey('plan-price-retry-premium'));
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(tester.widget<Text>(find.byKey(const ValueKey('plan-price-premium'))).data,
          'BDT 199.00');
      expect(find.byKey(const ValueKey('plan-buy-premium')), findsOneWidget);
    });

    testWidgets('website APK keeps the server taka prices', (tester) async {
      debugPayFlavour = 'apk';
      FakeApi.payLive = true;
      FakeApi.planSlug = 'free';
      await _pumpScreen(tester, const PlansScreen());
      expect(tester.widget<Text>(find.byKey(const ValueKey('plan-price-premium'))).data,
          '৳199');
    });

    testWidgets('credits screen packs: Play formattedPrice in Bangla digits', (tester) async {
      debugPayFlavour = 'play';
      FakeApi.playLive = true;
      FakeApi.payLive = true; // creditsPacks() lists the packs
      StoreBilling.debugOverride = FakeStoreBilling();
      await _pumpScreen(tester, const CreditsScreen(), lang: 'bn');
      final bn = String.fromCharCodes([0x09EB, 0x09E6, 0x2E, 0x09E6, 0x09E6]); // ৫০.০০
      expect(find.text('BDT $bn'), findsOneWidget);
      expect(find.text('\u09F3\u09EB\u09E6'), findsNothing); // never ৳৫০
    });
  });

  group('Google Play: Business yearly', () {
    PayConfig cfg() => PayConfig.fromJson({
          'channels': [
            {'id': 'play', 'enabled': true, 'ready': true},
          ],
          'products': {
            'play': [
              {
                'sku': 'business_yearly', 'kind': 'sub', 'plan': 'business',
                'period': 'yearly', 'months': 12, 'price_bdt': 5808,
                'title': 'Business', 'play_product_id': 'assisto_business',
                'play_base_plan': 'annual', // Play base plans: monthly | annual
              }
            ],
          },
          'play_account_id': 'u7-abc',
        });

    Future<AppLocalizations> open(WidgetTester tester, FakePaymentsBackend b) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_wrap(Scaffold(
          body: Builder(
              builder: (ctx) => FilledButton(
                  onPressed: () => CheckoutSheet.show(ctx, 'business_yearly',
                      backend: b, flavour: 'play'),
                  child: const Text('open'))))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return AppLocalizations.of(tester.element(find.byType(CheckoutSheet)));
    }

    testWidgets('buys assisto_business / yearly with the account id', (tester) async {
      final billing = FakeStoreBilling();
      StoreBilling.debugOverride = billing;
      final b = FakePaymentsBackend(cfg: cfg());
      final t = await open(tester, b);
      // credout: Play's own formatted price, never the server's taka
      expect(find.text('BDT 5,808.00'), findsWidgets);
      expect(find.textContaining('৳5,808'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('pay-option-play')));
      await tester.pumpAndSettle();
      expect(b.calls, contains('precheck:business_yearly'));
      expect(billing.bought.single, 'assisto_business/annual/true/u7-abc');
      expect(b.calls, contains('verify:sub:assisto_business:tok-1'));
      expect(find.text(t.paySuccessTitle), findsOneWidget);
    });

    testWidgets('yearly base plan missing in Play Console -> unavailable, nothing verified',
        (tester) async {
      final billing = FakeStoreBilling()
        ..next = const StoreBuyResult(StoreBuyStatus.unavailable,
            error: 'base plan not active in Play Console');
      StoreBilling.debugOverride = billing;
      final b = FakePaymentsBackend(cfg: cfg());
      final t = await open(tester, b);
      await tester.tap(find.byKey(const ValueKey('pay-option-play')));
      await tester.pumpAndSettle();
      expect(find.text(t.payPlayUnavailableNoAlt), findsOneWidget);
      expect(b.calls.where((c) => c.startsWith('verify')), isEmpty);
      expect(billing.finished, isEmpty);
    });

    testWidgets('same sku already running -> server refusal shown, Google never opened',
        (tester) async {
      final billing = FakeStoreBilling();
      StoreBilling.debugOverride = billing;
      final b = FakePaymentsBackend(cfg: cfg())
        ..precheckResult = const PayResult(
            ok: false,
            reason: 'already_active',
            message: 'You already have this plan through Google Play.');
      await open(tester, b);
      await tester.tap(find.byKey(const ValueKey('pay-option-play')));
      await tester.pumpAndSettle();
      expect(find.text('You already have this plan through Google Play.'),
          findsOneWidget);
      expect(billing.bought, isEmpty);
    });
  });

  // Owner rule 26 Oct: on the Play build every digital good is sold ONLY
  // through Google Play Billing — no EPS option, no link to /premium.
  group('Play build never offers EPS for digital goods', () {
    testWidgets('server gateway live, Play off -> Plans and Credits show no buy',
        (tester) async {
      debugPayFlavour = 'play';
      FakeApi.payLive = true; // the fake config lists only the gateway
      FakeApi.planSlug = 'free';
      final t = await _pumpScreen(tester, const PlansScreen());
      expect(find.byKey(const ValueKey('plan-buy-premium')), findsNothing);
      expect(find.byKey(const ValueKey('plan-buy-business')), findsNothing);
      await _toggle(tester, t.plansYearly);
      expect(find.byKey(const ValueKey('plan-buy-annual')), findsNothing);
      expect(find.byKey(const ValueKey('plan-buy-business')), findsNothing);
      expect(find.text(t.payGatewayTitle), findsNothing);
      await _pumpScreen(tester, const CreditsScreen());
      expect(find.byKey(const ValueKey('pack-buy-p50')), findsNothing);
    });

    testWidgets('same data on the website APK -> EPS buy buttons exist',
        (tester) async {
      debugPayFlavour = 'apk';
      FakeApi.payLive = true;
      FakeApi.planSlug = 'free';
      await _pumpScreen(tester, const PlansScreen());
      expect(find.byKey(const ValueKey('plan-buy-premium')), findsOneWidget);
    });

    test('no app code links to the website checkout (/premium, /pay)', () {
      // the WEBSITE pages (not API paths such as /premium/offer)
      final bad = RegExp(
          r'''lifeassisto\.com/(premium|pay)|['"]/premium['"?#]|['"]/pay/return''');
      final hits = <String>[];
      final sep = Platform.pathSeparator;
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        if (f.path.contains('${sep}l10n$sep')) continue;
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (bad.hasMatch(lines[i])) hits.add('${f.path}:${i + 1}');
        }
      }
      expect(hits, isEmpty);
    });
  });

  group('Seller Agent plans on the Play build', () {
    setUp(() {
      p1Posts.clear();
      p1Connected = false; // no active plan -> the buy area is shown
    });

    for (final lang in ['en', 'bn']) {
      testWidgets('no Play product -> honest note, no buy button ($lang)',
          (tester) async {
        debugPayFlavour = 'play';
        final t = await _pumpScreen(tester, const SellerAgentScreen(), lang: lang);
        expect(find.text(t.baBuyPlayNote), findsOneWidget);
        expect(find.text(t.baBuyNotReady), findsNothing);
        expect(find.textContaining('1490'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('website APK keeps its own note', (tester) async {
      debugPayFlavour = 'apk';
      final t = await _pumpScreen(tester, const SellerAgentScreen());
      expect(find.text(t.baBuyNotReady), findsOneWidget);
      expect(find.text(t.baBuyPlayNote), findsNothing);
    });
  });
}
