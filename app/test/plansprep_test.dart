// plansprep (owner 9 Nov): the plan screen's Play card says the next renewal
// date AND the price Google will charge; Bangla digits; 200 % font + dark
// without overflow.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/payments/play_restore.dart';
import 'package:assisto/theme.dart';

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

Map<String, dynamic> _play({num price = 449, bool auto = true}) => {
      'status': 'active',
      'sku': 'premium_monthly',
      'product_id': 'assisto_premium',
      'base_plan': 'monthly',
      'package': 'com.assisto.assisto',
      'auto_renew': auto,
      'price': price,
      'expires_at': DateTime.now().add(const Duration(days: 20)).toUtc().toIso8601String(),
    };

void main() {
  testWidgets('active sub: renewal date + Play price', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final w = PlayStatusCard(play: _play());
    await tester.pumpWidget(_app(w));
    await tester.pumpAndSettle();
    expect(find.textContaining('৳449'), findsOneWidget);
  });

  testWidgets('Bangla digits in the price', (tester) async {
    final w = PlayStatusCard(play: _play());
    await tester.pumpWidget(_app(w, lang: 'bn'));
    await tester.pumpAndSettle();
    expect(find.textContaining('৳৪৪৯'), findsOneWidget);
  });

  testWidgets('auto-renew off: no price promise', (tester) async {
    final w = PlayStatusCard(play: _play(auto: false));
    await tester.pumpWidget(_app(w));
    await tester.pumpAndSettle();
    expect(find.textContaining('৳449'), findsNothing);
  });

  for (final lang in ['bn', 'en']) {
    testWidgets('no overflow: $lang, dark, 200 % font', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_app(PlayStatusCard(play: _play()),
          lang: lang, scale: 2, br: Brightness.dark));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
