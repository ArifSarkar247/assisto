// bizsales-proof — COD confirmation card in the seller's chat: the stage in
// plain words, the honest risk counts (unknown is never "safe"), and ONE
// button that sends the Yes / No confirmation (POST orders/<id>/cod).
// bn + en, 200% text without overflow, Bangla digits only in bn.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/business/bizagent/seller_inbox_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';
import 'p1_bizagent_fakes.dart';

AppState _state(FakeApi api, String lang) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(id: 1, name: 'Me', phone: '', email: 'me@example.invalid',
      autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return s;
}

Future<AppLocalizations> _pump(WidgetTester tester,
    {String lang = 'en', double scale = 1.0, Size size = const Size(360, 6000)}) async {
  await tester.binding.setSurfaceSize(size);
  const home = SellerChatScreen(threadId: 6);
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: _state(FakeApi(mode: FakeMode.data, lang: lang), lang),
    child: MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AssistoTheme.light,
      builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: home,
    ),
  ));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return AppLocalizations.of(tester.element(find.byType(SellerChatScreen)));
}

void main() {
  setUp(p1Posts.clear);

  testWidgets('en: stage, honest risk, one send button only where it can be asked',
      (tester) async {
    final t = await _pump(tester);
    expect(find.byKey(const ValueKey('bsp-cod-71')), findsOneWidget);
    expect(find.byKey(const ValueKey('bsp-cod-72')), findsOneWidget);
    expect(find.text(t.bspCodStageNone), findsOneWidget);
    expect(find.text(t.bspCodStageAsked), findsOneWidget);
    expect(find.textContaining('1 delivered, 2 returned'), findsOneWidget);
    expect(find.textContaining('not treated as safe'), findsOneWidget);
    expect(find.byKey(const ValueKey('bsp-cod-send-71')), findsOneWidget);
    expect(find.byKey(const ValueKey('bsp-cod-send-72')), findsNothing);   // already asked
    await tester.ensureVisible(find.byKey(const ValueKey('bsp-cod-send-71')));
    await tester.tap(find.byKey(const ValueKey('bsp-cod-send-71')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(p1Posts.map((e) => e.key), contains('/bizagent/orders/71/cod'));
    expect(find.text(t.bspCodSentDone), findsOneWidget);
  });

  testWidgets('bn: Bangla digits only on the COD cards', (tester) async {
    await _pump(tester, lang: 'bn');
    final bad = <String>[];
    for (final key in const ['bsp-cod-71', 'bsp-cod-72']) {
      for (final w in tester.widgetList<Text>(
          find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text)))) {
        final s = w.data ?? w.textSpan?.toPlainText() ?? '';
        if (RegExp(r'[0-9]').hasMatch(s)) bad.add(s);
      }
    }
    expect(bad, isEmpty, reason: 'ASCII digits in bn UI: $bad');
    expect(find.textContaining('ডেলিভারি ১, ফেরত ২'), findsOneWidget);
  });

  for (final lang in const ['en', 'bn']) {
    testWidgets('$lang 200% text, small phone: COD cards do not overflow', (tester) async {
      await _pump(tester, lang: lang, scale: 2.0, size: const Size(360, 740));
      expect(tester.takeException(), isNull);
    });
  }
}
