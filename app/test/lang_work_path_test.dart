// langkoja: Korea → EPS-TOPIK / Japan → JFT-Basic work paths (Probashi corner)
// and phone-voice listening practice — switch, steps + official links, course
// entry, TTS honest fallbacks, grading, Bangla digits, 200 % font, load failure.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:assisto/api.dart';
import 'package:assisto/feature_flags.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/lang_work_path.dart';
import 'package:assisto/screens/language_pack_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';
import 'fake_langkoja.dart';

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

Widget _tiles() => const Scaffold(body: SingleChildScrollView(child: WorkLanguagePathTiles()));

void main() {
  tearDown(() => FeatureFlags.instance.debugOverride = null);

  testWidgets('Probashi tiles appear only when language_packs is on', (t) async {
    FeatureFlags.instance.debugOverride = {'language_packs': false};
    await t.pumpWidget(_app(_tiles(), FakeApi(lang: 'en')));
    expect(find.text('Work in Korea → EPS-TOPIK path'), findsNothing);
    await t.pumpWidget(const SizedBox()); // fresh route: the home page is cached by the Navigator
    FeatureFlags.instance.debugOverride = {'language_packs': true};
    await t.pumpWidget(_app(_tiles(), FakeApi(lang: 'en')));
    await t.pumpAndSettle();
    expect(find.text('Work in Korea → EPS-TOPIK path'), findsOneWidget);
    expect(find.text('Work in Japan → JFT-Basic path'), findsOneWidget);
  });

  testWidgets('Korea path: tile opens steps, official links and the course button', (t) async {
    FeatureFlags.instance.debugOverride = {'language_packs': true};
    await t.pumpWidget(_app(_tiles(), FakeApi(lang: 'en')));
    await t.pumpAndSettle();
    await t.tap(find.text('Work in Korea → EPS-TOPIK path'));
    await t.pumpAndSettle();
    expect(find.text('Start the course'), findsOneWidget);
    expect(find.text('Work in Korea: the EPS path'), findsOneWidget);
    expect(find.textContaining('only BOESL runs it'), findsOneWidget);
    await t.scrollUntilVisible(find.text('BOESL (Bangladesh)'), 200);
    expect(find.text('BOESL (Bangladesh)'), findsOneWidget);
    expect(find.text('Official websites'), findsOneWidget);
    await t.scrollUntilVisible(find.text('Assisto practice estimate — not an official exam result.'), 200);
    expect(find.text('Assisto practice estimate — not an official exam result.'), findsOneWidget);
    await t.scrollUntilVisible(find.text('Start the course'), -200);
    await t.tap(find.text('Start the course'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(LanguagePackScreen), findsOneWidget);
  });

  testWidgets('Japan path in Bangla: steps numbered with Bangla digits, no ASCII digits', (t) async {
    await t.pumpWidget(_app(const WorkPathScreen(lang: 'ja', title: 'JFT-Basic'), FakeApi(lang: 'bn'), lang: 'bn'));
    await t.pumpAndSettle();
    expect(find.text('জাপানে কাজ: JFT-Basic পথ'), findsOneWidget);
    expect(find.text('১'), findsOneWidget);
    for (final w in t.widgetList<Text>(find.byType(Text))) {
      final s = w.data ?? '';
      expect(_asciiDigit.hasMatch(s), isFalse, reason: s);
    }
  });

  testWidgets('path load failure shows an honest retry, never a blank page', (t) async {
    await t.pumpWidget(_app(const WorkPathScreen(lang: 'ko', title: 'EPS-TOPIK'), FakeApi(mode: FakeMode.fail, lang: 'en')));
    await t.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Start the course'), findsNothing);
  });

  testWidgets('listening: Listen speaks the line in ko-KR; no voice -> install offer', (t) async {
    final calls = <String>[];
    var reply = 'ok';
    await t.pumpWidget(_app(
        ListeningPracticePage(
            lang: 'ko',
            title: 'EPS-TOPIK',
            debugData: fakeListening('ko'),
            debugSpeak: (text, loc) async {
              calls.add('$loc|$text');
              return reply;
            }),
        FakeApi(lang: 'en')));
    await t.pumpAndSettle();
    expect(find.textContaining("not exam audio"), findsWidgets);
    expect(find.text('물 좀 주세요.'), findsNothing); // the line is hidden until asked
    await t.tap(find.text('Listen').first);
    await t.pumpAndSettle();
    expect(calls, ['ko-KR|물 좀 주세요.']);
    expect(find.byType(SnackBar), findsNothing);
    reply = 'no_voice';
    await t.tap(find.text('Listen').first);
    await t.pumpAndSettle();
    expect(find.text('This phone has no voice for this language yet.'), findsOneWidget);
    expect(find.text('Voice settings'), findsOneWidget);
    await t.tap(find.text('Show the line').first);
    await t.pumpAndSettle();
    expect(find.text('물 좀 주세요.'), findsOneWidget);
  });

  testWidgets('listening: check with no answer asks to choose; then grades with explanations', (t) async {
    await t.pumpWidget(_app(const ListeningPracticePage(lang: 'ko', title: 'EPS-TOPIK'), FakeApi(lang: 'en')));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('Check answers'), 200);
    await t.ensureVisible(find.text('Check answers'));
    await t.pumpAndSettle();
    await t.tap(find.text('Check answers'));
    await t.pump();
    expect(find.text('Choose an answer for at least one question first.'), findsOneWidget);
    await t.scrollUntilVisible(find.text('물'), -200);
    await t.ensureVisible(find.text('물'));
    await t.pumpAndSettle();
    await t.tap(find.text('물'));
    await t.pump();
    await t.scrollUntilVisible(find.text('Check answers'), 200);
    await t.ensureVisible(find.text('Check answers'));
    await t.pumpAndSettle();
    await t.tap(find.text('Check answers'));
    await t.pumpAndSettle();
    await t.drag(find.byType(ListView), const Offset(0, 3000));
    await t.pumpAndSettle();
    expect(find.text('1 of 2 correct'), findsOneWidget);
    await t.scrollUntilVisible(find.text('Right answer: 안전모'), 200);
    expect(find.text('Right answer: 안전모'), findsOneWidget);
    expect(find.text('A hard hat.'), findsOneWidget);
  });

  testWidgets('listening result in Bangla at 200 % font: Bangla digits, no overflow', (t) async {
    t.view.physicalSize = const Size(360 * 3, 760 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(_app(
        ListeningPracticePage(lang: 'ko', title: 'EPS-TOPIK', debugData: fakeListening('ko'), debugResult: fakeListeningResult()),
        FakeApi(lang: 'bn'),
        lang: 'bn',
        scale: 2,
        dark: true));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('২টির মধ্যে ১টি সঠিক'), findsOneWidget);
  });
}
