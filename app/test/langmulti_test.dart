// langmulti: the Arabic (Gulf work), German, French, Spanish and Chinese packs
// render in the generic Language Partner pages: Arabic letters + Bangla
// pronunciation notes, Chinese tones, a DELE-format-style mock, Bangla-first
// text; no overflow at 200 % font in dark mode at 360 dp (bn + en).
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/language_pack_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';
import 'fake_langmulti.dart';

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

void main() {
  testWidgets('Arabic script lesson: letters with Bangla pronunciation notes (bn)', (t) async {
    await t.pumpWidget(_app(LessonPage(pack: Object(), lesson: langmultiLesson('ar-s1')), FakeApi(lang: 'bn'), lang: 'bn'));
    await t.pumpAndSettle();
    expect(find.textContaining('ب'), findsWidgets);
    expect(find.textContaining('উচ্চারণ: ব'), findsWidgets);
    expect(find.text('বর্ণমালা ১: আলিফ থেকে রা'), findsOneWidget);
  });

  testWidgets('Arabic rights lesson in English shows English meanings', (t) async {
    await t.pumpWidget(_app(LessonPage(pack: Object(), lesson: langmultiLesson('ar-x1')), FakeApi(lang: 'en')));
    await t.pumpAndSettle();
    expect(find.text('Salary, passport and your rights'), findsOneWidget);
    expect(find.textContaining('passport'), findsWidgets);
  });

  testWidgets('Chinese tones lesson shows pinyin', (t) async {
    await t.pumpWidget(_app(LessonPage(pack: Object(), lesson: langmultiLesson('zh-p1')), FakeApi(lang: 'en')));
    await t.pumpAndSettle();
    expect(find.text('Pinyin and the four tones'), findsOneWidget);
    expect(find.textContaining('mā'), findsWidgets);
  });

  testWidgets('Spanish mock (DELE format style) shows Bangla-first questions and a writing box', (t) async {
    await t.pumpWidget(_app(MockTestPage(pack: Object(), mock: langmultiMock('es')), FakeApi(lang: 'bn'), lang: 'bn'));
    await t.pump(const Duration(milliseconds: 100)); // the mock clock ticks every second: no pumpAndSettle
    expect(find.textContaining('কোন প্ল্যাটফর্ম?'), findsOneWidget);
    // the writing box sits below the 12 questions (lazy list): scroll to it
    await t.scrollUntilVisible(find.byType(TextField).first, 400, scrollable: find.byType(Scrollable).first);
    expect(find.byType(TextField), findsWidgets);
  });

  for (final lang in ['bn', 'en']) {
    testWidgets('200% font + dark at 360 dp: Arabic, Chinese, German lessons + Arabic mock ($lang)', (t) async {
      t.view.physicalSize = const Size(360 * 3, 780 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      for (final id in ['ar-s1', 'ar-x1', 'zh-p1', 'de-a1-1']) {
        await t.pumpWidget(_app(LessonPage(pack: Object(), lesson: langmultiLesson(id)), FakeApi(lang: lang),
            lang: lang, scale: 2, dark: true));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull, reason: id);
      }
      await t.pumpWidget(_app(MockTestPage(pack: Object(), mock: langmultiMock('ar')), FakeApi(lang: lang),
          lang: lang, scale: 2, dark: true));
      await t.pump(const Duration(milliseconds: 100));
      expect(t.takeException(), isNull);
    });
  }
}
