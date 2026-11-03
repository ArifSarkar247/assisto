// aifinal PART 6: every AI answer carries the "AI generated" label.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/ai_generated_label.dart';

void main() {
  test('shows for AI answers, not for offline Brain answers', () {
    expect(AiGeneratedLabel.shows({'ai_generated': true}, null), isTrue);
    expect(AiGeneratedLabel.shows({}, 'ai'), isTrue);
    expect(AiGeneratedLabel.shows({'source': 'brain'}, 'brain'), isFalse);
  });

  for (final lang in ['en', 'bn']) {
    testWidgets('label renders at 200% font ($lang)', (t) async {
      await t.pumpWidget(MaterialApp(
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
        themeMode: lang == 'bn' ? ThemeMode.dark : ThemeMode.light,
        builder: (ctx, c) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(textScaler: const TextScaler.linear(2)),
            child: c!),
        home: const Scaffold(body: SizedBox(width: 320, child: AiGeneratedLabel())),
      ));
      final l10n = AppLocalizations.of(t.element(find.byType(AiGeneratedLabel)));
      expect(find.text(l10n.aiGenLabel), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}
