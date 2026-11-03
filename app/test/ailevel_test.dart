// aifinal PART 3: the answer level picker above the AI chat input.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/ai_level_picker.dart';

Map<String, dynamic> _payload({bool enabled = true, bool bestOk = true}) => {
      'enabled': enabled,
      'default': 'normal',
      'levels': [
        {'id': 'normal', 'name': 'Normal', 'credits': 1, 'max_chars': 2000, 'available': true},
        {'id': 'better', 'name': 'Better', 'credits': 1, 'max_chars': 3000, 'available': true},
        {'id': 'best', 'name': 'Best', 'credits': 17, 'max_chars': 4000, 'available': bestOk},
      ],
    };

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
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('pickAiLevel: remembered when available, else default; never dearer', () {
    final s = AiLevelState.parse(_payload(bestOk: false));
    expect(pickAiLevel(s, 'better'), 'better');
    expect(pickAiLevel(s, 'best'), 'normal');
    expect(pickAiLevel(s, null), 'normal');
    expect(AiLevelState.parse({'enabled': false}).enabled, isFalse);
  });

  testWidgets('hidden while the owner switch is off', (t) async {
    String? got = 'x';
    await t.pumpWidget(_app(AiLevelPicker(
        load: () async => _payload(enabled: false), onChanged: (l) => got = l)));
    await t.pumpAndSettle();
    expect(find.byType(ChoiceChip), findsNothing);
    expect(got, isNull);
  });

  for (final lang in ['en', 'bn']) {
    testWidgets('shows credits before sending, unavailable level disabled, remembers ($lang)',
        (t) async {
      String? got;
      await t.pumpWidget(_app(
          AiLevelPicker(load: () async => _payload(bestOk: false), onChanged: (l) => got = l),
          lang: lang, scale: 2, dark: lang == 'bn'));
      await t.pumpAndSettle();
      final l10n = AppLocalizations.of(t.element(find.byType(AiLevelPicker)));
      expect(find.byType(ChoiceChip), findsNWidgets(3));
      expect(got, 'normal');
      expect(find.text(l10n.ailvEstimate(lang == 'bn' ? '১' : '1')), findsOneWidget);
      expect(find.textContaining(l10n.ailvUnavailable), findsOneWidget);
      // the unavailable Best chip cannot be picked
      await t.tap(find.textContaining('Best'));
      await t.pumpAndSettle();
      expect(got, 'normal');
      await t.tap(find.textContaining('Better'));
      await t.pumpAndSettle();
      expect(got, 'better');
      final p = await SharedPreferences.getInstance();
      expect(p.getString(aiLevelPrefKey), 'better');
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('better hint is a line of text only', (t) async {
    await t.pumpWidget(_app(const AiBetterHint({'hint_better': true})));
    final l10n = AppLocalizations.of(t.element(find.byType(AiBetterHint)));
    expect(find.text(l10n.ailvHintBetter), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
    expect(AiBetterHint.shows({'hint_better': false}), isFalse);
  });
}
