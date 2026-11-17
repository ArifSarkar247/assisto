// staging (owner order 17 Nov): the "Assisto Test" app (applicationId
// com.assisto.assisto.staging) never sells anything. The checkout sheet says
// so honestly, never asks the server for a payment channel, never opens a
// gateway and never touches Play Billing. bn/en, 360 px, 200% font, dark.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/payments/checkout_sheet.dart';
import 'package:assisto/payments/store_billing.dart';
import 'package:assisto/theme.dart';

import 'pay1_fakes.dart';

Future<void> _pump(WidgetTester tester, FakePaymentsBackend b,
    {String lang = 'en',
    double scale = 1,
    Brightness br = Brightness.light,
    ValueChanged<bool?>? onResult}) async {
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
            onPressed: () async {
              final r = await CheckoutSheet.show(ctx, 'premium_monthly',
                  backend: b, flavour: 'apk');
              onResult?.call(r);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

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
    CheckoutSheet.purchasesDisabled = () => true;
  });
  tearDown(() {
    StoreBilling.debugOverride = null;
    CheckoutSheet.purchasesDisabled = () => false;
  });

  testWidgets('staging: honest "purchases are off", no server/gateway/Play call',
      (tester) async {
    final b = FakePaymentsBackend();
    bool? result = true;
    await _pump(tester, b, onResult: (r) => result = r);
    final t = AppLocalizations.of(tester.element(find.byType(CheckoutSheet)));
    expect(find.text(t.stagingPurchasesOffTitle), findsOneWidget);
    expect(find.text(t.stagingPurchasesOffBody), findsOneWidget);
    expect(b.calls, isEmpty, reason: 'the test app never asks for a channel');
    expect(launched, isEmpty);
    await tester.tap(find.text(t.stagingPurchasesOffOk));
    await tester.pumpAndSettle();
    expect(find.byType(CheckoutSheet), findsNothing);
    expect(result, isFalse, reason: 'nothing was bought');
    expect(tester.takeException(), isNull);
  });

  testWidgets('staging: Bangla, 200% font, dark, 360 px — no overflow',
      (tester) async {
    await _pump(tester, FakePaymentsBackend(),
        lang: 'bn', scale: 2, br: Brightness.dark);
    final t = AppLocalizations.of(tester.element(find.byType(CheckoutSheet)));
    expect(t.localeName, 'bn');
    expect(find.text(t.stagingPurchasesOffTitle), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('normal builds are unchanged: the sheet loads the channels',
      (tester) async {
    CheckoutSheet.purchasesDisabled = () => false;
    final b = FakePaymentsBackend();
    await _pump(tester, b);
    expect(b.calls, contains('config:apk'));
    final t = AppLocalizations.of(tester.element(find.byType(CheckoutSheet)));
    expect(find.text(t.stagingPurchasesOffTitle), findsNothing);
  });
}
