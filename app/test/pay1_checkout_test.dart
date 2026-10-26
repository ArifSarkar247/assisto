// pay1: the checkout sheet per flavour (Play first on Play builds, gateway
// only on the website APK), owner switches respected, gateway + Play purchase
// flows with fakes, honest errors, bn/en, no overflow at 360 px / large font.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/payments/checkout_sheet.dart';
import 'package:assisto/payments/payments_api.dart';
import 'package:assisto/payments/play_prices.dart';
import 'package:assisto/payments/store_billing.dart';
import 'package:assisto/theme.dart';

import 'pay1_fakes.dart';

Future<void> _pump(WidgetTester tester, FakePaymentsBackend b,
    {String flavour = 'play',
    String sku = 'premium_monthly',
    String lang = 'en',
    double scale = 1,
    Brightness br = Brightness.light}) async {
  await tester.binding.setSurfaceSize(const Size(360, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
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
    themeMode: br == Brightness.light ? ThemeMode.light : ThemeMode.dark,
    builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!),
    home: Scaffold(
      body: Builder(
        builder: (ctx) => Center(
          child: FilledButton(
            onPressed: () =>
                CheckoutSheet.show(ctx, sku, backend: b, flavour: flavour),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

AppLocalizations _t(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(CheckoutSheet)));

void main() {
  late FakeStoreBilling billing;
  late List<Uri> launched;

  setUp(() {
    billing = FakeStoreBilling();
    StoreBilling.debugOverride = billing;
    launched = [];
    CheckoutSheet.launcher = (u) async {
      launched.add(u);
      return true;
    };
  });
  tearDown(() {
    StoreBilling.debugOverride = null;
    PlayPrices.debugReset();
  });

  testWidgets('Play build: Google Play ONLY — EPS never offered, even when the '
      'server switch says the gateway is live (owner rule 26 Oct)',
      (tester) async {
    final b = FakePaymentsBackend(); // gateway enabled + ready on the server
    await _pump(tester, b);
    final t = _t(tester);
    expect(b.calls.first, 'config:play');
    expect(find.byKey(const ValueKey('pay-option-play')), findsOneWidget);
    expect(find.byKey(const ValueKey('pay-option-gateway')), findsNothing);
    expect(find.text(t.payPlayTitle), findsOneWidget);
    expect(find.text(t.payGatewayTitle), findsNothing);
    // credout: Play's own formatted price, never the server's taka number
    expect(find.text('BDT 199.00'), findsOneWidget);
    expect(find.textContaining('৳199'), findsNothing);
    expect(find.textContaining('BDT 199.00'), findsNWidgets(2)); // header + option
    expect(tester.takeException(), isNull);
  });

  testWidgets('website APK: gateway only — Play is never offered or attempted',
      (tester) async {
    // even if a server answered with a play channel, the APK hides it
    final b = FakePaymentsBackend(cfg: pay1Config(play: true));
    await _pump(tester, b, flavour: 'apk');
    expect(b.calls.first, 'config:apk');
    expect(find.byKey(const ValueKey('pay-option-play')), findsNothing);
    expect(find.byKey(const ValueKey('pay-option-gateway')), findsOneWidget);
    expect(billing.bought, isEmpty);
  });

  testWidgets('owner switch off -> that option is hidden (no dead option)',
      (tester) async {
    final b = FakePaymentsBackend(cfg: pay1Config(gwEnabled: false));
    await _pump(tester, b);
    expect(find.byKey(const ValueKey('pay-option-gateway')), findsNothing);
    expect(find.byKey(const ValueKey('pay-option-play')), findsOneWidget);
    expect(b.calls.where((c) => c.startsWith('checkout')), isEmpty);
  });

  testWidgets('keys not added -> options hidden; none live -> honest note',
      (tester) async {
    final b = FakePaymentsBackend(
        cfg: pay1Config(playReady: false, gwReady: false));
    await _pump(tester, b);
    final t = _t(tester);
    expect(find.byKey(const ValueKey('pay-option-play')), findsNothing);
    expect(find.byKey(const ValueKey('pay-option-gateway')), findsNothing);
    expect(find.text(t.payNoneAvailable), findsOneWidget);
  });

  test('PayConfig.canBuy: only a LIVE channel (switch on + keys) sells', () {
    expect(pay1Config().canBuy('premium_monthly', 'play'), isTrue);
    expect(pay1Config(play: false).canBuy('pack_p50', 'apk'), isTrue);
    // Play is never live on the website APK, whatever the server says.
    expect(pay1Config(gwEnabled: false).anyUsable('apk'), isFalse);
    expect(pay1Config(gwEnabled: false).anyUsable('play'), isTrue);
    expect(pay1Config(playReady: false, gwReady: false).anyUsable('play'),
        isFalse);
    expect(pay1Config().canBuy('premium_lifetime', 'play'), isFalse);
    // owner rule 26 Oct: the gateway is never a way to pay on the Play build
    expect(pay1Config(play: false).canBuy('premium_monthly', 'play'), isFalse);
    expect(pay1Config(play: false).anyUsable('play'), isFalse);
    expect(pay1Config().live('play').map((c) => c.id), ['play']);
  });

  testWidgets('gateway: order -> browser -> check -> paid', (tester) async {
    final b = FakePaymentsBackend(cfg: pay1Config(play: false));
    await _pump(tester, b, flavour: 'apk');
    final t = _t(tester);
    await tester.tap(find.byKey(const ValueKey('pay-option-gateway')));
    await tester.pumpAndSettle();
    expect(b.calls, contains('checkout:premium_monthly:apk'));
    expect(launched.single.host, 'sandboxpg.eps.com.bd');
    expect(find.text(t.payWaitingTitle), findsOneWidget);
    // still pending -> honest "not confirmed yet"
    await tester.tap(find.text(t.payCheckNow));
    await tester.pumpAndSettle();
    expect(find.text(t.payStillPending), findsOneWidget);
    b.orderResults.add(const PayResult(
        ok: true, data: {'ok': true, 'order': {'id': 41, 'status': 'paid'}}));
    await tester.tap(find.text(t.payCheckNow));
    await tester.pumpAndSettle();
    expect(find.text(t.paySuccessTitle), findsOneWidget);
    expect(find.text(t.paySuccessPlan('Premium')), findsOneWidget);
  });

  testWidgets('gateway: server refusal shows the server message', (tester) async {
    final b = FakePaymentsBackend(cfg: pay1Config(play: false))
      ..checkoutResult = const PayResult(
          ok: false,
          reason: 'managed_by_play',
          message: 'Your subscription runs through Google Play — change it there.');
    await _pump(tester, b, flavour: 'apk');
    await tester.tap(find.byKey(const ValueKey('pay-option-gateway')));
    await tester.pumpAndSettle();
    expect(find.textContaining('runs through Google Play'), findsOneWidget);
    expect(launched, isEmpty);
  });

  testWidgets('gateway: browser cannot open -> honest error', (tester) async {
    CheckoutSheet.launcher = (_) async => false;
    final b = FakePaymentsBackend(cfg: pay1Config(play: false));
    await _pump(tester, b, flavour: 'apk');
    await tester.tap(find.byKey(const ValueKey('pay-option-gateway')));
    await tester.pumpAndSettle();
    expect(find.text(_t(tester).payOpenFailed), findsOneWidget);
  });

  testWidgets('Play: precheck -> buy -> server verify -> finish -> success',
      (tester) async {
    final b = FakePaymentsBackend();
    await _pump(tester, b);
    await tester.tap(find.byKey(const ValueKey('pay-option-play')));
    await tester.pumpAndSettle();
    expect(b.calls, contains('precheck:premium_monthly'));
    expect(billing.bought.single, 'assisto_premium/monthly/true/u7-abc');
    expect(b.calls, contains('verify:sub:assisto_premium:tok-1'));
    expect(billing.finished, ['tok-1']);
    expect(find.text(_t(tester).paySuccessTitle), findsOneWidget);
  });

  testWidgets('Play pack: verified as a pack, credits message', (tester) async {
    final b = FakePaymentsBackend()
      ..verifyResult = const PayResult(
          ok: true, data: {'ok': true, 'state': 'granted', 'granted': 55});
    await _pump(tester, b, sku: 'pack_p50');
    final t = _t(tester);
    expect(find.textContaining(t.payCreditsN(55)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pay-option-play')));
    await tester.pumpAndSettle();
    expect(billing.bought.single, 'credits_p50//false/u7-abc');
    expect(b.calls, contains('verify:pack:credits_p50:tok-1'));
    expect(find.text(t.paySuccessCredits(55)), findsOneWidget);
  });

  testWidgets('Play: user cancels -> back to the options, nothing verified',
      (tester) async {
    billing.next = const StoreBuyResult(StoreBuyStatus.cancelled);
    final b = FakePaymentsBackend();
    await _pump(tester, b);
    await tester.tap(find.byKey(const ValueKey('pay-option-play')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pay-option-play')), findsOneWidget);
    expect(b.calls.where((c) => c.startsWith('verify')), isEmpty);
  });

  testWidgets('Play: pending payment is honest', (tester) async {
    billing.next = const StoreBuyResult(StoreBuyStatus.pending);
    final b = FakePaymentsBackend();
    await _pump(tester, b);
    await tester.tap(find.byKey(const ValueKey('pay-option-play')));
    await tester.pumpAndSettle();
    expect(find.text(_t(tester).payPlayPending), findsOneWidget);
  });

  testWidgets('Play: server refuses the token -> not finished, message shown',
      (tester) async {
    final b = FakePaymentsBackend()
      ..verifyResult = const PayResult(
          ok: false,
          reason: 'other_account',
          message: 'This purchase belongs to another Assisto account.');
    await _pump(tester, b);
    await tester.tap(find.byKey(const ValueKey('pay-option-play')));
    await tester.pumpAndSettle();
    expect(find.textContaining('another Assisto account'), findsOneWidget);
    expect(billing.finished, isEmpty);
  });

  testWidgets('Play: precheck refusal stops before Google', (tester) async {
    final b = FakePaymentsBackend()
      ..precheckResult = const PayResult(
          ok: false, reason: 'prepaid_active', message: 'Your prepaid plan is still running.');
    await _pump(tester, b);
    await tester.tap(find.byKey(const ValueKey('pay-option-play')));
    await tester.pumpAndSettle();
    expect(find.textContaining('prepaid plan is still running'), findsOneWidget);
    expect(billing.bought, isEmpty);
  });

  testWidgets('Play client unavailable on this phone -> price unavailable, '
      'buy disabled, retry (never a server taka price)', (tester) async {
    StoreBilling.debugOverride = null; // flavour play but not a Play build
    final b = FakePaymentsBackend();
    await _pump(tester, b);
    final t = _t(tester);
    expect(find.text(t.payPriceUnavailable), findsOneWidget);
    expect(find.textContaining('৳'), findsNothing);
    expect(find.byKey(const ValueKey('pay-price-retry')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pay-option-play')));
    await tester.pumpAndSettle();
    expect(b.calls.where((c) => c.startsWith('precheck')), isEmpty);
    expect(find.text(t.payPlayUnavailable), findsNothing);
    // the store comes back -> retry shows Play's price and enables buying
    StoreBilling.debugOverride = billing;
    await tester.tap(find.byKey(const ValueKey('pay-price-retry')));
    await tester.pumpAndSettle();
    expect(find.text('BDT 199.00'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pay-option-play')));
    await tester.pumpAndSettle();
    expect(b.calls, contains('precheck:premium_monthly'));
  });

  testWidgets('config fails to load -> retry', (tester) async {
    final b = FakePaymentsBackend(failConfig: true);
    await _pump(tester, b);
    final t = _t(tester);
    expect(find.text(t.payNetwork), findsOneWidget);
    b.failConfig = false;
    await tester.tap(find.text(t.retry));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pay-option-play')), findsOneWidget);
  });

  for (final lang in ['bn', 'en']) {
    for (final br in Brightness.values) {
      testWidgets('no clipped text: $lang ${br.name}, 1.3x font, 360 px',
          (tester) async {
        final b = FakePaymentsBackend(cfg: pay1Config(gwEnabled: false));
        await _pump(tester, b, lang: lang, scale: 1.3, br: br);
        expect(tester.takeException(), isNull);
        expect(find.text(_t(tester).payChooseTitle), findsOneWidget);
      });
    }
  }
}
