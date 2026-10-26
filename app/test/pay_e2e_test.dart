// pay-e2e: restore purchases (same account / other account / pending /
// offline), the Play status banner (active, cancelled, grace, on hold,
// paused) with its Google Play deep link, and the checkout sheet's
// double-tap / offline-after-payment / no-steering behaviour. bn + en,
// dark mode, 200 % font at 360 px. Fakes only — no Play, no network.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/payments/checkout_sheet.dart';
import 'package:assisto/payments/payments_api.dart';
import 'package:assisto/payments/play_restore.dart';
import 'package:assisto/payments/store_billing.dart';
import 'package:assisto/theme.dart';

import 'pay1_fakes.dart';

const _ok = PayResult(
    ok: true, data: {'ok': true, 'entitled': true, 'state': 'SUBSCRIPTION_STATE_ACTIVE'});
const _granted = PayResult(ok: true, data: {'ok': true, 'state': 'granted'});
const _other = PayResult(ok: false, reason: 'other_account');
const _net = PayResult.network;

Widget _app(Widget home,
        {String lang = 'en', double scale = 1, Brightness br = Brightness.light}) =>
    MaterialApp(
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
      home: Scaffold(body: SingleChildScrollView(child: home)),
    );

Future<AppLocalizations> _pump(WidgetTester tester, Widget w,
    {String lang = 'en', double scale = 1, Brightness br = Brightness.light}) async {
  await tester.binding.setSurfaceSize(const Size(360, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_app(w, lang: lang, scale: scale, br: br));
  await tester.pumpAndSettle();
  return AppLocalizations.of(tester.element(find.byWidget(w)));
}

Map<String, dynamic> _play(String status, {int days = 20}) => {
      'status': status,
      'sku': 'premium_monthly',
      'product_id': 'assisto_premium',
      'base_plan': 'monthly',
      'package': 'com.assisto.assisto',
      'auto_renew': status == 'active',
      'expires_at': DateTime.now().add(Duration(days: days)).toUtc().toIso8601String(),
    };

void main() {
  late FakeStoreBilling billing;
  setUp(() {
    billing = FakeStoreBilling();
    StoreBilling.debugOverride = billing;
  });
  tearDown(() => StoreBilling.debugOverride = null);

  group('restorePlayPurchases', () {
    test('sub + pack restored; unknown products and duplicate tokens skipped',
        () async {
      final b = FakePaymentsBackend();
      b.verifyByToken['s1'] = [_ok];
      b.verifyByToken['p1'] = [_granted];
      billing.ownedList = const [
        StoreOwned('assisto_premium', 's1'),
        StoreOwned('credits_p50', 'p1'),
        StoreOwned('assisto_premium', 's1'), // same token twice
        StoreOwned('some_other_app_item', 'x9'),
      ];
      final o = await restorePlayPurchases(b, billing, b.cfg);
      expect(o.found, 2);
      expect(o.restored, 2);
      expect(b.calls.where((c) => c.startsWith('verify')).toList(), [
        'verify:sub:assisto_premium:s1',
        'verify:pack:credits_p50:p1',
      ]);
      // the device grants nothing and finishes nothing on restore
      expect(billing.finished, isEmpty);
    });

    test('a token of another Assisto account is refused, not granted',
        () async {
      final b = FakePaymentsBackend();
      b.verifyByToken['s1'] = [_other];
      billing.ownedList = const [StoreOwned('assisto_premium', 's1')];
      final o = await restorePlayPurchases(b, billing, b.cfg);
      expect((o.restored, o.otherAccount), (0, 1));
    });

    test('pending and offline are counted honestly', () async {
      final b = FakePaymentsBackend();
      b.verifyByToken['p1'] = [
        const PayResult(ok: false, reason: 'error', data: {'state': 'pending'})
      ];
      b.verifyByToken['s1'] = [_net];
      billing.ownedList = const [
        StoreOwned('credits_p50', 'p1'),
        StoreOwned('assisto_premium', 's1'),
      ];
      final o = await restorePlayPurchases(b, billing, b.cfg);
      expect((o.pending, o.failed, o.restored), (1, 1, 0));
    });
  });

  group('RestorePurchasesButton', () {
    testWidgets('restores and tells the user; double tap runs once',
        (tester) async {
      final b = FakePaymentsBackend();
      b.verifyByToken['s1'] = [_ok];
      billing.ownedList = const [StoreOwned('assisto_premium', 's1')];
      var reloaded = 0;
      final w = RestorePurchasesButton(
          backend: b,
          cfg: b.cfg,
          // slow Play: the second tap lands while the first restore runs
          billing: () =>
              Future.delayed(const Duration(milliseconds: 300), () => billing),
          onRestored: () => reloaded++);
      final t = await _pump(tester, w);
      await tester.tap(find.byKey(const ValueKey('pay-restore')));
      await tester.tap(find.byKey(const ValueKey('pay-restore')),
          warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text(t.payRestoreDone(1)), findsOneWidget);
      expect(b.calls.where((c) => c.startsWith('verify')).length, 1);
      expect(reloaded, 1);
    });

    testWidgets('other account -> explains which account owns it',
        (tester) async {
      final b = FakePaymentsBackend();
      b.verifyByToken['s1'] = [_other];
      billing.ownedList = const [StoreOwned('assisto_premium', 's1')];
      final t = await _pump(tester,
          RestorePurchasesButton(backend: b, cfg: b.cfg, billing: () async => billing),
          lang: 'bn');
      await tester.tap(find.byKey(const ValueKey('pay-restore')));
      await tester.pumpAndSettle();
      expect(find.text(t.payRestoreOtherAccount), findsOneWidget);
    });

    testWidgets('nothing owned -> honest note',
        (tester) async {
      final b = FakePaymentsBackend();
      final t = await _pump(tester,
          RestorePurchasesButton(backend: b, cfg: b.cfg, billing: () async => billing));
      await tester.tap(find.byKey(const ValueKey('pay-restore')));
      await tester.pumpAndSettle();
      expect(find.text(t.payRestoreNone), findsOneWidget);
    });

    testWidgets('Play missing on this phone -> no other method named',
        (tester) async {
      final b = FakePaymentsBackend();
      final t = await _pump(tester,
          RestorePurchasesButton(backend: b, cfg: b.cfg, billing: () async => null));
      await tester.tap(find.byKey(const ValueKey('pay-restore')));
      await tester.pumpAndSettle();
      expect(find.text(t.payPlayUnavailableNoAlt), findsOneWidget);
      expect(t.payPlayUnavailableNoAlt.contains('bKash'), isFalse);
    });
  });

  group('PlayStatusCard', () {
    late List<Uri> opened;
    setUp(() {
      opened = [];
      PlayStatusCard.launcher = (u) async {
        opened.add(u);
        return true;
      };
    });

    testWidgets('grace -> warning + Fix payment opens Play for this sub',
        (tester) async {
      final t = await _pump(tester, PlayStatusCard(play: _play('grace')));
      expect(find.byKey(const ValueKey('play-status-grace')), findsOneWidget);
      expect(find.text(t.payFixPayment), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('play-manage')));
      await tester.pumpAndSettle();
      expect(opened.single.toString(),
          'https://play.google.com/store/account/subscriptions?sku=assisto_premium&package=com.assisto.assisto');
    });

    testWidgets('on hold / paused / cancelled / active texts + buttons',
        (tester) async {
      final t = await _pump(tester, PlayStatusCard(play: _play('on_hold')));
      expect(find.text(t.payPlayOnHold), findsOneWidget);
      expect(find.text(t.payFixPayment), findsOneWidget);
      for (final s in ['paused', 'canceled', 'active']) {
        await tester.pumpWidget(_app(PlayStatusCard(key: ValueKey(s), play: _play(s))));
        await tester.pumpAndSettle();
        expect(find.text(t.payManageSub), findsOneWidget, reason: s);
      }
      expect(find.byKey(const ValueKey('play-status-active')), findsOneWidget);
    });

    testWidgets('Play page cannot open -> honest snackbar', (tester) async {
      PlayStatusCard.launcher = (u) async => false;
      final t = await _pump(tester, PlayStatusCard(play: _play('grace')));
      await tester.tap(find.byKey(const ValueKey('play-manage')));
      await tester.pumpAndSettle();
      expect(find.text(t.payOpenFailed), findsOneWidget);
    });

    for (final lang in ['bn', 'en']) {
      testWidgets('no overflow: $lang, dark, 200 % font', (tester) async {
        for (final s in ['grace', 'on_hold', 'canceled', 'paused', 'active']) {
          await _pump(tester, PlayStatusCard(key: ValueKey(s), play: _play(s)),
              lang: lang, scale: 2, br: Brightness.dark);
          expect(tester.takeException(), isNull, reason: s);
          final btn = tester.getSize(find.byKey(const ValueKey('play-manage')));
          expect(btn.height, greaterThanOrEqualTo(48));
        }
        await _pump(tester,
            RestorePurchasesButton(
                backend: FakePaymentsBackend(),
                cfg: pay1Config(),
                billing: () async => billing),
            lang: lang, scale: 2, br: Brightness.dark);
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byKey(const ValueKey('pay-restore'))).height,
            greaterThanOrEqualTo(48));
      });
    }
  });

  group('checkout sheet (Play)', () {
    Future<AppLocalizations> open(WidgetTester tester, FakePaymentsBackend b) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_app(Builder(
          builder: (ctx) => FilledButton(
              onPressed: () => CheckoutSheet.show(ctx, 'premium_monthly',
                  backend: b, flavour: 'play'),
              child: const Text('open')))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return AppLocalizations.of(tester.element(find.byType(CheckoutSheet)));
    }

    testWidgets('double tap on Google Play starts ONE purchase', (tester) async {
      final b = FakePaymentsBackend();
      await open(tester, b);
      await tester.tap(find.byKey(const ValueKey('pay-option-play')));
      await tester.tap(find.byKey(const ValueKey('pay-option-play')),
          warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(billing.bought.length, 1);
      expect(b.calls.where((c) => c.startsWith('precheck')).length, 1);
    });

    testWidgets('paid on Play but offline -> retried, then "being confirmed"',
        (tester) async {
      final b = FakePaymentsBackend();
      b.verifyByToken['tok-1'] = [_net, _net, _net];
      final t = await open(tester, b);
      await tester.tap(find.byKey(const ValueKey('pay-option-play')));
      await tester.pumpAndSettle(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      expect(b.calls.where((c) => c.startsWith('verify')).length, 3);
      expect(find.text(t.payPlayPending), findsOneWidget);
      expect(find.text(t.payFailedBody), findsNothing); // never "no money taken"
      expect(billing.finished, isEmpty);
    });

    testWidgets('offline then back -> verified on retry, purchase finished',
        (tester) async {
      final b = FakePaymentsBackend();
      b.verifyByToken['tok-1'] = [_net, _ok];
      final t = await open(tester, b);
      await tester.tap(find.byKey(const ValueKey('pay-option-play')));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text(t.paySuccessTitle), findsOneWidget);
      expect(billing.finished, ['tok-1']);
    });

    testWidgets('Play unavailable, gateway not offered -> no other method named',
        (tester) async {
      StoreBilling.debugOverride = null; // test build is not the Play build
      final b = FakePaymentsBackend(cfg: pay1Config(gwEnabled: false));
      final t = await open(tester, b);
      await tester.tap(find.byKey(const ValueKey('pay-option-play')));
      await tester.pumpAndSettle();
      expect(find.text(t.payPlayUnavailableNoAlt), findsOneWidget);
      expect(find.text(t.payPlayUnavailable), findsNothing);
    });
  });
}
