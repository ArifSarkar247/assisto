// learnwire: Language Partner framework gaps (per-language question text and
// options, writing checklists, speaking prompts, Chinese/Japanese character
// counts, pack-defined role-plays, Gulf tile -> Arabic) and the learning
// certificate wiring (offer button under graded results, Quran "Get my
// certificate" after a finished course; both only with the switch on).
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/feature_flags.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/quran_learn/learn_progress.dart';
import 'package:assisto/quran_learn/quran_learn_screen.dart';
import 'package:assisto/screens/language_pack_screen.dart';
import 'package:assisto/screens/learn_cert_screen.dart' show LearnCertClaimSheet;
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'app_fonts.dart';
import 'fake_api.dart';
import 'fake_langmulti.dart';
import 'fake_learnwire.dart';

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
      home: Scaffold(body: child),
    ),
  );
}

void _tall(WidgetTester t) {
  t.view.physicalSize = const Size(1080, 9000);
  t.view.devicePixelRatio = 2.5;
  addTearDown(t.view.reset);
}

void main() {
  setUpAll(loadAppFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FeatureFlags.instance.debugOverride = null;
  });
  tearDown(() => FeatureFlags.instance.debugOverride = null);

  group('pure helpers', () {
    test('pickLang: UI language first, the other only when missing', () {
      final q = {'text': 'T', 'text_bn': 'বাংলা', 'text_en': 'English'};
      expect(pickLang(true, q, 'text'), 'বাংলা');
      expect(pickLang(false, q, 'text'), 'English');
      expect(pickLang(false, {'text': 'T', 'text_bn': 'বাংলা'}, 'text'), 'বাংলা');
      expect(pickLang(true, {'text': 'T', 'text_bn': '', 'text_en': 'E'}, 'text'), 'E');
      expect(pickLang(true, {'text': 'T'}, 'text'), 'T');
      expect(pickLang(false, {'options': ['a'], 'options_en': <String>[], 'options_bn': ['খ']}, 'options'),
          ['খ']);
    });

    test('Chinese / Japanese writing counts characters, not spaces', () {
      expect(writingCount('zh', '我是学生。'), 4);
      expect(writingCount('zh', '我 是 学 生'), 4);
      expect(writingCount('ja', 'わたしは がくせい です'), 10);
      expect(writingCount('de', 'Ich bin heute krank.'), 4);
      expect(writingCount('zh', ''), 0);
    });

    test('checklist: any phrase, case-insensitive, empty text never passes', () {
      final c = [
        {'any': ['krank'], 'en': 'ill', 'bn': 'অসুস্থ'},
        {'any': ['morgen'], 'en': 'tomorrow', 'bn': 'কাল'},
      ];
      expect(runChecks(c, 'Ich bin KRANK'), [true, false]);
      expect(runChecks(c, ''), [false, false]);
    });

    test('Gulf zones (UTC+3 / UTC+4) open Arabic', () {
      expect(isGulfOffset(180), isTrue);
      expect(isGulfOffset(240), isTrue);
      expect(isGulfOffset(540), isFalse);
      expect(isGulfOffset(null), isFalse);
    });
  });

  testWidgets('MCQ shows English text + options in English, Bangla in Bangla (Arabic mock)', (t) async {
    _tall(t);
    final mock = langmultiMock('ar');
    final q = ((mock['sections'] as List).first as Map)['questions'] as List;
    final q0 = (q.first as Map).cast<String, dynamic>();
    for (final lang in ['en', 'bn']) {
      await t.pumpWidget(_app(MockTestPage(pack: Object(), mock: mock, lang: 'ar'), FakeApi(lang: lang), lang: lang));
      await t.pump(const Duration(milliseconds: 100));
      final want = '${q0['text_$lang'] ?? q0['text']}';
      expect(find.textContaining(want.split('\n').first), findsWidgets, reason: lang);
      final opts = (q0['options_$lang'] ?? q0['options']) as List;
      expect(find.text('${opts.first}'), findsWidgets, reason: lang);
    }
  });

  testWidgets('Arabic mock renders writing checklist and speaking prompts', (t) async {
    _tall(t);
    await t.pumpWidget(_app(MockTestPage(pack: Object(), mock: langmultiMock('ar'), lang: 'ar'), FakeApi(lang: 'en')));
    await t.pump(const Duration(milliseconds: 100));
    // lazy list: scroll to the writing and speaking parts (the mock clock
    // ticks every second, so no pumpAndSettle while it runs)
    final list = find.byType(Scrollable).first;
    await t.scrollUntilVisible(find.text('Country written in Arabic'), 400, scrollable: list);
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('Checklist — key words, not a grade'), findsWidgets);
    const speak = 'Greet, say your name and that you are from Bangladesh.';
    await t.scrollUntilVisible(find.text(speak), 400, scrollable: list);
    await t.pump(const Duration(milliseconds: 100));
    await t.tap(find.text(speak));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byType(SpeakPromptPage), findsOneWidget);
    expect(find.text('Try to say:'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('Chinese writing box counts characters live; ticks come from the server', (t) async {
    _tall(t);
    await t.pumpWidget(_app(MockTestPage(pack: Object(), mock: lwZhMock(), lang: 'zh'), FakeApi(lang: 'en')));
    await t.pump(const Duration(milliseconds: 100));
    await t.enterText(find.byType(TextField).first, '我 在 工厂 工作');
    await t.pump();
    expect(find.text('6 characters (spaces not counted) · Aim: 8 to 60'), findsOneWidget);
    // graded: the server's open-row checklist turns into ticks / crosses
    await t.pumpWidget(_app(
        MockTestPage(pack: Object(), mock: lwZhMock(), lang: 'zh', debugResult: {
          'level': 'HSK1', 'score_pct': 0, 'correct': 0, 'total': 0, 'weak': <String>[], 'rows': <Map>[],
          'open': [
            {'id': 'zh-lw-w1', 'checks': [{'ok': false}, {'ok': true}]}
          ],
        }),
        FakeApi(lang: 'en')));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(find.byIcon(Icons.cancel_rounded), findsOneWidget);
  });

  testWidgets('speaking checklist from what the phone heard (Bangla, Bangla digits)', (t) async {
    _tall(t);
    final sp = ((lwZhMock()['sections'] as List)[1] as Map)['speak_prompts'] as List;
    await t.pumpWidget(_app(
        SpeakPromptPage(prompt: (sp.first as Map).cast<String, dynamic>(), debugHeard: '你好，我叫阿里。'),
        FakeApi(lang: 'bn'),
        lang: 'bn'));
    await t.pumpAndSettle();
    expect(find.text('পরিচয় দিন: নাম আর দেশ।'), findsOneWidget);
    expect(find.text('প্রায় ৩০ সেকেন্ড'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget); // name said
    expect(find.byIcon(Icons.cancel_rounded), findsOneWidget); // country not said
    expect(find.textContaining('বলার নম্বর নয়'), findsOneWidget);
  });

  testWidgets('certificate offer: hidden while the switch is off, opens the claim sheet when on', (t) async {
    _tall(t);
    final res = {
      'level': 'HSK2', 'score_pct': 72, 'correct': 7, 'total': 10, 'weak': <String>[], 'rows': <Map>[],
      'cert': {'course': 'lang_zh', 'level': 'H2', 'score': 72, 'token': 'tok'},
    };
    FeatureFlags.instance.debugOverride = {'learning_certificate': false};
    await t.pumpWidget(_app(MockTestPage(pack: Object(), mock: lwZhMock(), lang: 'zh', debugResult: res),
        FakeApi(lang: 'en')));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('lw-cert-offer')), findsNothing);
    FeatureFlags.instance.debugOverride = {'learning_certificate': true};
    await t.pumpWidget(_app(MockTestPage(pack: Object(), mock: lwZhMock(), lang: 'zh', debugResult: res),
        FakeApi(lang: 'en')));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('lw-cert-offer')), findsOneWidget);
    await t.tap(find.byKey(const Key('lw-cert-offer')));
    await t.pumpAndSettle();
    expect(find.byType(LearnCertClaimSheet), findsOneWidget);
    // no token -> no button
    await t.pumpWidget(_app(
        MockTestPage(pack: Object(), mock: lwZhMock(), lang: 'zh', debugResult: {...res, 'cert': null}),
        FakeApi(lang: 'en')));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('lw-cert-offer')), findsNothing);
  });

  testWidgets('Probashi tile: a Gulf zone opens Arabic directly, other zones keep the hub', (t) async {
    FeatureFlags.instance.debugOverride = {'language_packs': true};
    await t.pumpWidget(_app(const LearnForWorkTile(abroadOffsetMin: 240), FakeApi(lang: 'en')));
    await t.pump();
    expect(find.text('Working in a Gulf country? Learn work Arabic'), findsOneWidget);
    expect(find.text('All languages'), findsOneWidget);
    await t.tap(find.byKey(const Key('lw-work-tile')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    final pack = t.widget<LanguagePackScreen>(find.byType(LanguagePackScreen));
    expect(pack.lang, 'ar');

    await t.pumpWidget(_app(const LearnForWorkTile(abroadOffsetMin: 540), FakeApi(lang: 'en')));
    await t.pump();
    expect(find.text('Working in a Gulf country? Learn work Arabic'), findsOneWidget); // the second button
    expect(find.text('All languages'), findsNothing);

    FeatureFlags.instance.debugOverride = {'language_packs': false};
    await t.pumpWidget(_app(const LearnForWorkTile(abroadOffsetMin: 240), FakeApi(lang: 'en')));
    await t.pump();
    expect(find.byKey(const Key('lw-work-tile')), findsNothing);
  });

  testWidgets('Quran: finished Qaida offers the certificate only with the switch on', (t) async {
    _tall(t);
    QlProgress done() => lwQaidaDone();
    FeatureFlags.instance.debugOverride = {'learning_certificate': false};
    await t.pumpWidget(_app(QuranLearnScreen(progress: done()), FakeApi(lang: 'en')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('ql-cert-quran_qaida')), findsNothing);

    FeatureFlags.instance.debugOverride = {'learning_certificate': true};
    await t.pumpWidget(_app(QuranLearnScreen(progress: done()), FakeApi(lang: 'en')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('ql-cert-quran_qaida')), findsOneWidget);
    expect(find.byKey(const Key('ql-cert-quran_nazera')), findsNothing); // Nazera not finished
    final hint = t.widgetList<Text>(find.textContaining('reading practice completed')).first.data!;
    expect(hint.toLowerCase(), isNot(contains('ijaz')));
    expect(hint.toLowerCase(), isNot(contains('qari')));
    await t.tap(find.byKey(const Key('ql-cert-quran_qaida')));
    await t.pumpAndSettle();
    expect(find.byType(LearnCertClaimSheet), findsOneWidget);
  });

  testWidgets('JFT-style mock: one section at a time, no going back', (t) async {
    _tall(t);
    await t.pumpWidget(_app(MockTestPage(pack: Object(), mock: lwJftMock(), lang: 'ja'), FakeApi(lang: 'en')));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('Section 1 of 2'), findsOneWidget);
    expect(find.textContaining('lw-q1'), findsOneWidget);
    expect(find.textContaining('lw-q2'), findsNothing);
    expect(find.text('Finish and see my level'), findsNothing);
    await t.tap(find.byKey(const Key('lw-next-section')));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('Section 2 of 2'), findsOneWidget);
    expect(find.textContaining('lw-q1'), findsNothing); // the earlier section is gone
    expect(find.textContaining('lw-q2'), findsOneWidget);
    expect(find.byKey(const Key('lw-next-section')), findsNothing);
    // after grading every section shows again for review
    await t.pumpWidget(_app(
        MockTestPage(pack: Object(), mock: lwJftMock(), lang: 'ja', debugResult: const {
          'level': 'N5', 'score_pct': 50, 'correct': 1, 'total': 2,
        }),
        FakeApi(lang: 'en')));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('lw-q1'), findsOneWidget);
    expect(find.textContaining('lw-q2'), findsOneWidget);
    expect(find.byKey(const Key('lw-section-of')), findsNothing);
  });

  testWidgets('pack extras: work path + phone-voice listening tiles', (t) async {
    _tall(t);
    await t.pumpWidget(_app(
        LanguagePackScreen(lang: 'ko', title: 'Korean', debugPack: {
          'stt_locale': 'ko-KR',
          'levels': const [],
          'extras': const [
            {'id': 'work_path', 'en': 'Work in Korea: the EPS-TOPIK path', 'bn': 'কোরিয়ায় কাজ'},
            {'id': 'listening', 'en': 'Listening practice — phone voice, not exam audio', 'bn': 'শোনা'},
            {'id': 'unknown', 'en': 'Never shown', 'bn': 'না'},
          ],
        }),
        FakeApi(lang: 'en')));
    await t.pumpAndSettle();
    expect(find.text('Work in Korea: the EPS-TOPIK path'), findsOneWidget);
    expect(find.text('Listening practice — phone voice, not exam audio'), findsOneWidget);
    expect(find.text('Never shown'), findsNothing); // no dead tile for an id the app cannot open
  });

  testWidgets('lesson lines: Listen reads the line with the phone voice in the course language', (t) async {
    final said = <String>[];
    debugPackSpeak = (text, locale) async {
      said.add('$locale|$text');
      return said.length == 1 ? 'ok' : 'no_voice';
    };
    addTearDown(() => debugPackSpeak = null);
    await t.pumpWidget(_app(
        LessonPage(pack: Object(), ttsLocale: 'ko-KR', lesson: const {
          'id': 'ko-lw', 'title_en': 'Greetings', 'title_bn': 'সম্ভাষণ',
          'items': [
            {'kind': 'note', 'target': 'ㅏ ㅓ', 'bn': 'নোট', 'en': 'note'},
            {'kind': 'vocab', 'target': '안녕하세요', 'roman': 'annyeonghaseyo', 'bn': 'হ্যালো', 'en': 'Hello'},
          ],
        }),
        FakeApi(lang: 'en')));
    await t.pumpAndSettle();
    expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget); // not on the note
    await t.tap(find.byIcon(Icons.volume_up_rounded));
    await t.pump();
    expect(said, ['ko-KR|안녕하세요']);
    await t.tap(find.byIcon(Icons.volume_up_rounded));
    await t.pump();
    expect(find.text('This phone has no voice for this language yet.'), findsOneWidget);
  });

  for (final lang in ['bn', 'en']) {
    testWidgets('200% font + dark at 360 dp: Arabic mock + speaking page + Gulf tile ($lang)', (t) async {
      t.view.physicalSize = const Size(360 * 3, 780 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      FeatureFlags.instance.debugOverride = {'language_packs': true, 'learning_certificate': true};
      await t.pumpWidget(_app(MockTestPage(pack: Object(), mock: langmultiMock('ar'), lang: 'ar'),
          FakeApi(lang: lang), lang: lang, scale: 2, dark: true));
      await t.pump(const Duration(milliseconds: 100));
      expect(t.takeException(), isNull);
      final sp = ((lwZhMock()['sections'] as List)[1] as Map)['speak_prompts'] as List;
      await t.pumpWidget(_app(SpeakPromptPage(prompt: (sp.first as Map).cast<String, dynamic>(), debugHeard: '我叫阿里'),
          FakeApi(lang: lang), lang: lang, scale: 2, dark: true));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.pumpWidget(_app(const SingleChildScrollView(child: LearnForWorkTile(abroadOffsetMin: 180)),
          FakeApi(lang: lang), lang: lang, scale: 2, dark: true));
      await t.pump();
      expect(t.takeException(), isNull);
    });
  }
}
