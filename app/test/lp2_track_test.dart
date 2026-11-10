// lpfinish: the Start screen's "Going abroad" / "Other languages" chips open
// REAL courses (no "next stage" sheet, no feature-flag dead end): syllabus,
// a lesson with instant checks, a practice test marked by the server with a
// practice-score footer; listening without recorded audio is read by the
// phone's own voice; one course = one chip; Bangla digits; 200 % font; dark.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:assisto/ads/ad_banner_slot.dart';
import 'package:assisto/ads/ad_rules.dart' show AdConfig;
import 'package:assisto/api.dart';
import 'package:assisto/feature_flags.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/language_partner_screen.dart';
import 'package:assisto/screens/lp2/lp_data.dart';
import 'package:assisto/screens/lp2/lp_mock.dart' show debugLpPlay;
import 'package:assisto/screens/lp2/lp_track.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';
import 'fake_lp2.dart';

Widget _app(Widget child, ApiClient api, {String lang = 'en', bool dark = false, double scale = 1}) {
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

final _spoken = <String>[];
final _ascii = RegExp(r'[0-9]');

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugLpAsset = (a) async => File(a).readAsStringSync();
    debugLpPlay = (_) async {};
    debugLpTtsSpeak = (text, lang) async => _spoken.add('$lang|$text');
    LpOffline.debugDisabled = true;
    AdBannerSlot.debugLoadConfig = () async => AdConfig.fromJson({'plan': 'premium', 'paid': true, 'ads_enabled': false});
    LpContent.debugReset();
    lp2Posts.clear();
    _spoken.clear();
  });
  tearDown(() => FeatureFlags.instance.debugOverride = null);

  test('one course = one chip; six languages, seven tracks', () {
    final all = [...kLpAbroadChips, ...kLpOtherChips];
    expect(all.map((c) => c.id).toSet().length, all.length);
    final tracks = [for (final c in all) ...c.tracks];
    expect(tracks.toSet().length, tracks.length);
    expect(tracks.toSet(), {'jlpt_n5', 'jft_basic', 'eps_topik', 'de_a1', 'ar_work', 'hsk1', 'fr_a1'});
    expect(all.map((c) => c.id).toSet(), {'ja', 'ko', 'de', 'ar', 'zh', 'fr'});
  });

  for (final flag in [false, true]) {
    testWidgets('Korea chip opens the real course (language_packs=$flag) — never a "next stage" sheet', (t) async {
      FeatureFlags.instance.debugOverride = {'language_packs': flag};
      await t.pumpWidget(_app(const LanguagePartnerScreen(), FakeApi(mode: FakeMode.data, lang: 'en')));
      await t.pumpAndSettle();
      final chip = find.byKey(const ValueKey('lp2-chip-ko'));
      await t.scrollUntilVisible(chip, 200, scrollable: find.byType(Scrollable).first);
      await t.tap(chip);
      await t.pumpAndSettle();
      expect(find.byType(LpTrackScreen), findsOneWidget);
      expect(find.textContaining('next stage'), findsNothing);
      expect(find.text('Korean for EPS-TOPIK'), findsOneWidget);
      expect(find.byKey(const ValueKey('lp2-lesson-ko-w01-l1')), findsOneWidget);
      // the honest planned week is not shown as an empty promise
      expect(find.text('Week 5'), findsNothing);
    });
  }

  testWidgets('lesson: new words with the phone voice, instant check, model answer, done', (t) async {
    await t.pumpWidget(_app(const LpTrackScreen(title: 'Korea', tracks: ['eps_topik']), FakeApi(mode: FakeMode.data)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('lp2-lesson-ko-w01-l1')));
    await t.pumpAndSettle();
    expect(find.text('사장님'), findsOneWidget);
    await t.tap(find.byIcon(Icons.volume_up_rounded).first);
    await t.pumpAndSettle();
    expect(_spoken.first, 'ko-KR|사장님');
    // listening practice is read by the phone voice
    final play = find.byKey(const Key('lp2-tts-play'));
    await t.scrollUntilVisible(play, 200, scrollable: find.byType(Scrollable).first);
    await t.tap(play);
    await t.pumpAndSettle();
    expect(_spoken.last, 'ko-KR|안녕하세요.');
    await t.tap(find.text('A. 안녕하세요').first);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('lp2-check-ko-l1-p1')));
    await t.pumpAndSettle();
    expect(find.text('শুভেচ্ছা বলল।'), findsOneWidget);
    final model = find.byKey(const ValueKey('lp2-model-ko-l1-w1'));
    await t.scrollUntilVisible(model, 200, scrollable: find.byType(Scrollable).first);
    await t.tap(model);
    await t.pumpAndSettle();
    expect(find.text('저는 민수예요.'), findsWidgets);
    final done = find.byKey(const Key('lp2-lesson-done'));
    await t.scrollUntilVisible(done, 200, scrollable: find.byType(Scrollable).first);
    await t.tap(done);
    await t.pumpAndSettle();
    expect(find.byType(LpLessonScreen), findsNothing);
  });

  testWidgets('practice test: timer, answer, server marking, explanations, practice footer', (t) async {
    await t.pumpWidget(_app(const LpTrackScreen(title: 'Korea', tracks: ['eps_topik']), FakeApi(mode: FakeMode.data)));
    await t.pumpAndSettle();
    final sec = find.byKey(const ValueKey('lp2-track-sec-eps-topik-001-reading'));
    await t.scrollUntilVisible(sec, 200, scrollable: find.byType(Scrollable).first);
    await t.tap(sec);
    await t.pumpAndSettle();
    expect(find.byType(LpTrackTestRunner), findsOneWidget);
    await t.tap(find.text('C. 가방'));
    await t.pump();
    await t.tap(find.byKey(const Key('lp2-track-submit')));
    await t.pumpAndSettle();
    final mark = lp2Posts.firstWhere((p) => p['path'] == 'lp/mocks/eps-topik-001/mark');
    expect(mark['section'], 'reading');
    expect((mark['answers'] as Map)['1'], 'C');
    expect(find.byKey(const Key('lp2-track-result')), findsOneWidget);
    expect(find.text('1 of 2 right'), findsOneWidget);
    expect(find.text('Score 4 of 8'), findsOneWidget);
    expect(find.text('কারখানা = 공장।'), findsOneWidget);
    await t.tap(find.byKey(const Key('lp2-track-close')));
    await t.pumpAndSettle();
    expect(find.byType(LpTrackTestRunner), findsNothing);
  });

  testWidgets('track listening question plays the phone voice up to the exam repeat count', (t) async {
    await t.pumpWidget(_app(
        const LpTrackTestRunner(
            mock: {'id': 'eps-topik-001', 'title_en': 'EPS-TOPIK practice test 1'}, section: 'listening', sectionTitle: 'Listening'),
        FakeApi(mode: FakeMode.data)));
    await t.pumpAndSettle();
    final play = find.byKey(const Key('lp2-tts-play'));
    await t.tap(play);
    await t.pumpAndSettle();
    await t.tap(play);
    await t.pumpAndSettle();
    expect(_spoken, ['ko-KR|이것은 가방입니다.', 'ko-KR|이것은 가방입니다.']);
    expect(t.widget<IconButton>(play).onPressed, isNull); // heard twice, like the real test
  });

  testWidgets('IELTS part without recorded audio: the phone voice reads it in the part accent', (t) async {
    await t.pumpWidget(_app(
        const Scaffold(
            body: LpTtsPlayer(tts: {'lang': 'en-AU', 'lines': ['Good morning, Riverside Kitchen.', 'Hello.'], 'repeat': 1}, replay: false)),
        FakeApi(mode: FakeMode.data)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('lp2-tts-play')));
    await t.pumpAndSettle();
    expect(_spoken.single, 'en-AU|Good morning, Riverside Kitchen.\nHello.');
    expect(find.text('Read by your phone\'s own voice'), findsOneWidget);
  });

  for (final dark in [false, true]) {
    testWidgets('Bangla course page: Bangla digits only, 200 % font, dark=$dark', (t) async {
      await t.pumpWidget(_app(const LpTrackScreen(title: 'কোরিয়া', tracks: ['eps_topik']),
          FakeApi(mode: FakeMode.data, lang: 'bn'), lang: 'bn', dark: dark, scale: 2));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      final texts = t.widgetList<Text>(find.byType(Text)).map((w) => w.data ?? '').toList();
      expect(texts.where((s) => _ascii.hasMatch(s) && !s.contains('EPS')), isEmpty, reason: texts.join(' | '));
    });
  }
}
