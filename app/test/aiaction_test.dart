// aifinal PART 5: AI action buttons — fixed allow-list, confirm before run.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/ai_action_buttons.dart';

Widget _app(Widget w, {String lang = 'en', double scale = 1, bool dark = false}) => MaterialApp(
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
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      builder: (ctx, c) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: c!),
      home: Scaffold(body: SingleChildScrollView(child: w)),
    );

void main() {
  test('unknown or invented ids are dropped; max three', () {
    final ids = AiActionButtons.idsOf({
      'actions': [
        {'id': 'transfer_money'},
        {'id': 'call_999'},
        {'id': 'invoice'},
        {'id': 'reminder'},
        {'id': 'safe_journey'},
      ]
    });
    expect(ids, ['call_999', 'invoice', 'reminder']);
    expect(AiActionButtons.idsOf({'actions': 'x'}), isEmpty);
  });

  for (final lang in ['en', 'bn']) {
    testWidgets('nothing runs without tap + confirm ($lang)', (t) async {
      final opened = <String>[];
      await t.pumpWidget(_app(
          AiActionButtons(const {
            'actions': [
              {'id': 'call_999'},
              {'id': 'invoice'}
            ]
          }, opener: (c, id, r) async => opened.add(id)),
          lang: lang, scale: 2, dark: lang == 'bn'));
      final l10n = AppLocalizations.of(t.element(find.byType(AiActionButtons)));
      expect(find.text(l10n.aiactCall999), findsOneWidget);
      await t.tap(find.byKey(const Key('aiact-call_999')));
      await t.pumpAndSettle();
      expect(find.text(l10n.aiactConfirmCall), findsOneWidget);
      await t.tap(find.text(l10n.cancel));
      await t.pumpAndSettle();
      expect(opened, isEmpty);
      await t.tap(find.byKey(const Key('aiact-invoice')));
      await t.pumpAndSettle();
      await t.tap(find.text(l10n.aimdOpenLink));
      await t.pumpAndSettle();
      expect(opened, ['invoice']);
      expect(t.getSize(find.byKey(const Key('aiact-invoice'))).height, greaterThanOrEqualTo(48));
      expect(t.takeException(), isNull);
    });
  }
}
