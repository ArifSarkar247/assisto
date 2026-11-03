// p2lang: IELTS practice screens — hub + streak, entry card behind the flag,
// pronunciation result, writing checklist + AI estimate, reading grading,
// load failure, Bangla digits, 200 % font.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:assisto/api.dart';
import 'package:assisto/feature_flags.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/ielts_screen.dart';
import 'package:assisto/screens/language_partner_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';
import 'fake_ielts.dart';

Widget _app(Widget child, ApiClient api, {String lang = 'en', double scale = 1, bool dark = false}) {
  final s = AppState();
  s.api = api;
  s.locale = Locale(lang);
  s.loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: s,
    child: MaterialApp(
      locale: Locale(lang),
      theme: dark ? AssistoTheme.dark : AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (ctx, w) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: w!),
      home: child,
    ),
  );
}

final _asciiDigit = RegExp(r'[0-9]');

void main() {
  tearDown(() => FeatureFlags.instance.debugOverride = null);

  testWidgets('hub shows the streak, the estimate label and six modules', (t) async {
    await t.pumpWidget(_app(const IeltsScreen(), FakeApi(mode: FakeMode.data, lang: 'en')));
    await t.pumpAndSettle();
    expect(find.text('3-day practice streak'), findsOneWidget);
    expect(find.text('Practice estimate — not an official IELTS band.'), findsOneWidget);
    for (final m in ['Pronunciation check', 'Speaking', 'Writing', 'Reading', 'Listening', 'IELTS vocabulary']) {
      await t.scrollUntilVisible(find.text(m), 100);
      expect(find.text(m), findsOneWidget);
    }
  });

  testWidgets('hub in Bangla: no ASCII digits, Bangla streak', (t) async {
    await t.pumpWidget(_app(const IeltsScreen(), FakeApi(mode: FakeMode.data, lang: 'bn'), lang: 'bn'));
    await t.pumpAndSettle();
    final texts = t.widgetList<Text>(find.byType(Text)).map((w) => w.data ?? '').toList();
    expect(texts.where((s) => _asciiDigit.hasMatch(s)), isEmpty);
    expect(texts.any((s) => s.contains('৩')), isTrue); // Bangla 3
  });

  testWidgets('load failure shows retry, never a blank page', (t) async {
    await t.pumpWidget(_app(const IeltsScreen(), FakeApi(mode: FakeMode.fail, lang: 'en')));
    await t.pumpAndSettle();
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
  });

  testWidgets('Language Partner shows the IELTS card only when language_packs is on', (t) async {
    FeatureFlags.instance.debugOverride = {'language_packs': false};
    await t.pumpWidget(_app(const LanguagePartnerScreen(), FakeApi(mode: FakeMode.data, lang: 'en')));
    await t.pumpAndSettle();
    expect(find.text('IELTS practice'), findsNothing);
    FeatureFlags.instance.debugOverride = {'language_packs': true};
    await t.pumpWidget(_app(const LanguagePartnerScreen(key: ValueKey(2)), FakeApi(mode: FakeMode.data, lang: 'en')));
    await t.pumpAndSettle();
    expect(find.text('IELTS practice'), findsOneWidget);
    await t.tap(find.text('IELTS practice'));
    await t.pumpAndSettle();
    expect(find.text('3-day practice streak'), findsOneWidget);
  });

  testWidgets('pronunciation result: score, coloured words, honest estimate', (t) async {
    final row = (fakeIeltsContent()['pron'] as List).first as Map<String, dynamic>;
    await t.pumpWidget(_app(
        IeltsPronPractice(ctx: Object(), row: row, debugHeard: 'students start is school spring'),
        FakeApi(lang: 'en')));
    await t.pumpAndSettle();
    expect(find.text('80% of the words were recognised'), findsOneWidget);
    expect(find.text('in'), findsOneWidget); // the missed word has its own chip
    expect(find.byIcon(Icons.cancel_rounded), findsWidgets);
    expect(find.textContaining('not a sound-by-sound analysis'), findsOneWidget);
  });

  testWidgets('pronunciation: Check with nothing heard explains what to do', (t) async {
    final row = (fakeIeltsContent()['pron'] as List).first as Map<String, dynamic>;
    await t.pumpWidget(_app(IeltsPronPractice(ctx: Object(), row: row), FakeApi(lang: 'en')));
    await t.pumpAndSettle();
    await t.tap(find.text('Check'));
    await t.pump();
    expect(find.textContaining('Nothing heard yet'), findsOneWidget);
  });

  testWidgets('writing: checklist + AI estimate + credits, labelled estimate', (t) async {
    final row = ((fakeIeltsContent()['writing'] as Map)['t2'] as List).first as Map<String, dynamic>;
    await t.pumpWidget(_app(IeltsWritingPractice(ctx: Object(), task: 't2', row: row), FakeApi(lang: 'en')));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'Online study is useful. However, classrooms help too.');
    await t.pump();
    expect(find.text('8 words · at least 250'), findsOneWidget);
    await t.tap(find.text('Check my answer (free)'));
    await t.pumpAndSettle();
    expect(find.text('4 of 7 checks passed'), findsOneWidget);
    // the multi-line TextField is a Scrollable too: scroll the page itself
    await t.scrollUntilVisible(find.text('3 AI credits used'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('about band 6'), findsWidgets);
    expect(find.text('Practice estimate — not an official IELTS band.'), findsOneWidget);
  });

  testWidgets('writing: empty answer is refused with a reason', (t) async {
    final row = ((fakeIeltsContent()['writing'] as Map)['t1'] as List).first as Map<String, dynamic>;
    await t.pumpWidget(_app(IeltsWritingPractice(ctx: Object(), task: 't1', row: row), FakeApi(lang: 'en')));
    await t.pumpAndSettle();
    await t.tap(find.text('Check my answer (free)'));
    await t.pump();
    expect(find.text('Write or say your answer first.'), findsOneWidget);
  });

  testWidgets('reading: answer, grade, see explanations', (t) async {
    final row = (fakeIeltsContent()['reading'] as List).first as Map<String, dynamic>;
    await t.pumpWidget(_app(IeltsReadingPractice(ctx: Object(), row: row), FakeApi(lang: 'en')));
    await t.pumpAndSettle();
    await t.tap(find.text('True').first);
    await t.pump();
    await t.scrollUntilVisible(find.text('Check answers'), 200);
    await t.tap(find.text('Check answers'));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.textContaining('Answer: False'), 200);
    expect(find.textContaining('Answer: False'), findsOneWidget);
    await t.scrollUntilVisible(find.text('1 of 2 correct'), 200);
    expect(find.text('1 of 2 correct'), findsOneWidget);
  });

  for (final lang in ['bn', 'en']) {
    testWidgets('200% font + dark: hub and writing result do not overflow ($lang)', (t) async {
      t.view.physicalSize = const Size(360 * 3, 780 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(const IeltsScreen(), FakeApi(lang: lang), lang: lang, scale: 2, dark: true));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      final row = ((fakeIeltsContent()['writing'] as Map)['t2'] as List).first as Map<String, dynamic>;
      await t.pumpWidget(_app(
          IeltsWritingPractice(ctx: Object(), task: 't2', row: row, debugText: 'Hello', debugResult: fakeIeltsWritingResult()),
          FakeApi(lang: lang), lang: lang, scale: 2, dark: true));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
  }
}
