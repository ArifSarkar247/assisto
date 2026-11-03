// quranread (owner order 3 Nov 11:45, part B): Learn to read Quran.
//
// Proves: the lessons follow the Noorani order (9 stages, Qaida 1-7, Nazera
// 8-9); every Quran word/ayah reference resolves in the REAL bundled Tanzil
// Uthmani file (sha256 pinned = verbatim, CC BY 3.0); the recitation helper's
// letter matching; progress, daily goal, streak, course completion and the
// courseResult() seam for agent/learncert; the Arabic locale picker; and the
// screens (experimental banner, big letters, honest "no audio", check sheet,
// mark learned persists, 200% font without overflow).
import 'dart:convert';
import 'dart:io';

import 'package:assisto/feature_registry.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/l10n/quran_learn_content.dart';
import 'package:assisto/quran_learn/course_result.dart';
import 'package:assisto/quran_learn/learn_progress.dart';
import 'package:assisto/quran_learn/qaida_model.dart';
import 'package:assisto/quran_learn/quran_learn_screen.dart';
import 'package:assisto/quran_learn/recite_check.dart';
import 'package:assisto/quran_learn/recite_listener.dart';
import 'package:assisto/quran_learn/recite_sheet.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api.dart' show FakeMode;
import 'quran_learn_fixture.dart';
import 'screenshots_test.dart' as gallery;

Future<void> _pump(WidgetTester tester, Widget screen,
    {String lang = 'en', double scale = 1.0, Size size = const Size(400, 900)}) async {
  final app = gallery.galleryStub(lang: lang, mode: FakeMode.data);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: app,
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
        child: child!,
      ),
      home: screen,
    ),
  ));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Iterable<QlItem> _allItems() =>
    kQlStages.expand((s) => s.lessons).expand((l) => l.items);

final _bnDigitsOnly = RegExp(r'[0-9]');

void main() {
  group('lessons (our own text, Noorani order)', () {
    test('9 stages in the Noorani order, Qaida 1-7 and Nazera 8-9', () {
      expect(kQlStages.map((s) => s.n), [1, 2, 3, 4, 5, 6, 7, 8, 9]);
      expect(kQlStages.map((s) => s.title.en), [
        'Letters and makhraj',
        'Harakat (fatha, kasra, damma)',
        'Tanween',
        'Jazm (sukun)',
        'Tashdeed (shadda)',
        'Madd',
        'Words',
        'Ayat',
        'Basic tajweed',
      ]);
      for (final s in kQlStages) {
        expect(s.course, s.n <= 7 ? kCourseQaida : kCourseNazera, reason: '${s.n}');
        expect(s.lessons, isNotEmpty);
        for (final l in s.lessons) {
          expect(l.items, isNotEmpty, reason: l.id);
        }
      }
    });

    test('ids unique; each item has text or a Quran ref (never both)', () {
      final ids = _allItems().map((i) => i.id).toList();
      expect(ids.toSet().length, ids.length);
      final lessonIds = kQlStages.expand((s) => s.lessons).map((l) => l.id).toList();
      expect(lessonIds.toSet().length, lessonIds.length);
      for (final i in _allItems()) {
        expect((i.ar == null) != (i.ref == null), isTrue, reason: i.id);
      }
    });

    test('29 letters, each with its Arabic name and a makhraj note', () {
      final letters = kQlStages[0].lessons.expand((l) => l.items).toList();
      expect(letters.length, 29);
      for (final i in letters) {
        expect(i.check, isNotNull, reason: i.id);
        expect(i.note!.bn, startsWith('মাখরাজ'), reason: i.id);
        expect(i.note!.en, startsWith('Makhraj'), reason: i.id);
      }
      // the seven heavy letters are flagged
      expect(letters.where((i) => i.heavy).map((i) => i.ar).toSet(),
          {'خ', 'ص', 'ض', 'غ', 'ط', 'ق', 'ظ'});
    });

    test('Bangla lesson text uses Bangla digits only', () {
      for (final s in kQlStages) {
        expect(_bnDigitsOnly.hasMatch(s.title.bn + s.summary.bn), isFalse);
        for (final l in s.lessons) {
          expect(_bnDigitsOnly.hasMatch(l.title.bn + l.intro.bn), isFalse, reason: l.id);
          for (final i in l.items) {
            expect(_bnDigitsOnly.hasMatch('${i.say?.bn}${i.note?.bn}'), isFalse,
                reason: i.id);
          }
        }
      }
    });

    test('every Quran reference resolves in the real Uthmani text', () {
      final u = realUthmani();
      var refs = 0;
      for (final i in _allItems().where((i) => i.ref != null)) {
        expect(u.text(i.ref!), isNotNull, reason: '${i.id} ${i.ref!.label()}');
        refs++;
      }
      expect(refs, greaterThan(40));
      // spot checks against the mushaf
      // word ranges cut the real line on spaces (bismillah skipped in 112:1)
      expect(qlSkeleton(u.text(const QlRef(112, 1, 4))!), qlSkeleton('قل هو الله احد'));
      expect(qlSkeleton(u.text(const QlRef(1, 4, 1, 1))!), qlSkeleton('يوم'));
      expect(qlSkeleton(u.text(const QlRef(86, 7, 1, 2))!), qlSkeleton('من بين'));
      expect(u.text(const QlRef(86, 7, 1, 2))!.split(' ').length, 2);
      expect(u.text(const QlRef(1, 8)), isNull); // Al-Fatiha has 7 ayat
      expect(u.text(const QlRef(1, 1, 3, 9)), isNull); // past the last word
    });
  });

  group('Tanzil Uthmani file (licensed, verbatim)', () {
    test('bundled file is the exact Tanzil download, notice kept', () {
      final raw = utf8.decode(
          gzip.decode(File('assets/quran/quran-uthmani.txt.gz').readAsBytesSync()));
      expect(sha256.convert(utf8.encode(raw)).toString(),
          '7f30c647331a61100ebf24a80507dc0fcdd9f2df97f1312b5b2dfcb982a7f326');
      final u = realUthmani();
      expect(u.notice, contains('Tanzil Quran Text (Uthmani, Version 1.1)'));
      expect(u.notice, contains('Creative Commons Attribution 3.0'));
      expect(File('assets/quran/SOURCES.txt').readAsStringSync(),
          contains('quran-uthmani.txt.gz'));
      expect(File('assets/fonts/AmiriQuran-OFL.txt').readAsStringSync(),
          contains('SIL Open Font License'));
    });
  });

  group('recitation helper (letters only)', () {
    test('skeleton drops marks, alif and hamza; unifies variants', () {
      expect(qlSkeleton('ٱلْحَمْدُ لِلَّهِ'), 'لحمدلله');
      expect(qlSkeleton('الحمد لله'), 'لحمدلله');
      expect(qlSkeleton('رَحْمَةٌ'), 'رحمه');
      expect(qlSkeleton('هُدًى'), 'هدي');
      expect(qlCanCheck('أَ'), isFalse);
      expect(qlCanCheck('بَ'), isTrue);
    });

    test('a plain-spelling reading of the ayah is good', () {
      final r = checkRecitation('ٱلْحَمْدُ لِلَّهِ رَبِّ ٱلْعَٰلَمِينَ',
          'الحمد لله رب العالمين');
      expect(r.score, greaterThanOrEqualTo(95));
      expect(r.verdict, ReciteVerdict.good);
      expect(r.words.every((w) => w.ok), isTrue);
    });

    test('a missed word is "close" and that word is marked', () {
      final r = checkRecitation('قُلْ هُوَ ٱللَّهُ أَحَدٌ', 'قل هو الله');
      expect(r.verdict, ReciteVerdict.close);
      expect(r.words.map((w) => w.ok), [true, true, true, false]);
    });

    test('unrelated speech asks to retry', () {
      final r = checkRecitation('قُلْ أَعُوذُ بِرَبِّ ٱلْفَلَقِ', 'صباح الخير يا جميل');
      expect(r.verdict, ReciteVerdict.retry);
    });

    test('a letter is accepted by its name or its sound', () {
      expect(checkRecitation('ب', 'باء', alsoAccept: ['باء']).verdict,
          ReciteVerdict.good);
      expect(checkRecitation('ب', 'با', alsoAccept: ['باء']).verdict,
          ReciteVerdict.good);
      expect(checkRecitation('ب', 'سين', alsoAccept: ['باء']).verdict,
          ReciteVerdict.retry);
      expect(checkRecitation('ب', '', alsoAccept: ['باء']).score, 0);
    });

    test('Arabic recogniser locale: Saudi first, any Arabic, else none', () {
      expect(ReciteListener.pickArabic(['en_US', 'ar-SA', 'ar_EG']), 'ar-SA');
      expect(ReciteListener.pickArabic(['ar_EG', 'bn_BD']), 'ar_EG');
      expect(ReciteListener.pickArabic(['ar_MA']), 'ar_MA');
      expect(ReciteListener.pickArabic(['ar']), 'ar');
      expect(ReciteListener.pickArabic(['bn_BD', 'en_US']), isNull);
      expect(ReciteListener.pickArabic(const []), isNull);
    });
  });

  group('progress, daily goal, courseResult', () {
    final day1 = DateTime(2026, 11, 3, 9);
    final day2 = DateTime(2026, 11, 4, 20);

    test('mark learned counts towards today; unmark does not double count', () {
      final p = QlProgress();
      p.toggle('l_ba', day1);
      p.toggle('l_ta', day1);
      expect(p.today(day1), 2);
      p.toggle('l_ta', day1); // unmark
      expect(p.learned, {'l_ba'});
      expect(p.today(day1), 2);
      expect(p.streak(day1), 1);
      expect(p.streak(day2), 1); // not lost until the day ends
      expect(p.streak(DateTime(2026, 11, 6)), 0);
      p.toggle('l_ta', day2);
      expect(p.streak(day2), 2);
    });

    test('json round trip; bad goal falls back to 10', () {
      final p = QlProgress(goal: 20, lastLesson: 'letters2')
        ..toggle('l_ba', day1)
        ..recordScore('l_ba', 140);
      final q = QlProgress.fromJson(
          jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(q.learned, {'l_ba'});
      expect(q.goal, 20);
      expect(q.lastLesson, 'letters2');
      expect(q.best['l_ba'], 100);
      expect(QlProgress.fromJson({'goal': 7}).goal, QlProgress.defaultGoal);
    });

    test('store survives a corrupt value', () async {
      SharedPreferences.setMockInitialValues({QlProgress.prefsKey: '{oops'});
      final p = await QlProgressStore.load();
      expect(p.learned, isEmpty);
      p.toggle('l_ba', day1);
      await QlProgressStore.save(p);
      expect((await QlProgressStore.load()).learned, {'l_ba'});
    });

    test('courseResult: none -> stage_n -> completed (date kept)', () async {
      final p = QlProgress();
      expect(await courseResult(kCourseQaida, progress: p), isNull);
      expect(await courseResult('english_ielts', progress: p), isNull);
      p.toggle('l_ba', day1);
      final r1 = (await courseResult(kCourseQaida, progress: p))!;
      expect(r1.stage, 'stage_0');
      expect(r1.completed, isFalse);
      // learn all of stage 1
      for (final i in kQlStages[0].lessons.expand((l) => l.items)) {
        if (!p.learned.contains(i.id)) p.toggle(i.id, day1);
      }
      expect(resultOf(p, kCourseQaida)!.stage, 'stage_1');
      // learn the rest of the Qaida on day 2
      for (final s in kQlStages.where((s) => s.course == kCourseQaida)) {
        for (final i in s.lessons.expand((l) => l.items)) {
          if (!p.learned.contains(i.id)) p.toggle(i.id, day2);
        }
      }
      final r = resultOf(p, kCourseQaida)!;
      expect(r.completed, isTrue);
      expect(r.stage, 'completed');
      expect(QlProgress.dayKey(r.date), '2026-11-04');
      expect(r.score, isNull); // the helper is not a grade
      expect(r.toJson()['course'], 'quran_qaida');
      // Nazera is separate and still open
      expect(resultOf(p, kCourseNazera)!.completed, isFalse);
      expect(p.nextLesson()!.stage.n, 8);
      // unmark + re-mark later never moves the completion date
      final last = kQlStages[6].lessons.last.items.last.id;
      p.toggle(last, DateTime(2026, 12, 1));
      p.toggle(last, DateTime(2026, 12, 1));
      expect(QlProgress.dayKey(resultOf(p, kCourseQaida)!.date), '2026-11-04');
    });
  });

  group('switch', () {
    test('quran_learn is OFF by default and routed', () {
      expect(kFeatureDefaults['quran_learn'], isFalse);
      expect(kRouteFeature['quran_learn'], 'quran_learn');
    });
  });

  group('screens', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('home: experimental banner, today card, 9 stages (bn digits)',
        (tester) async {
      await _pump(tester, QuranLearnScreen(progress: qlShotProgress()), lang: 'bn');
      expect(find.byKey(const Key('ql-experimental')), findsOneWidget);
      expect(find.byKey(const Key('ql-today')), findsOneWidget);
      expect(find.byKey(const Key('ql-continue')), findsOneWidget);
      // today 6 of 10 in Bangla digits
      expect(find.textContaining('৬'), findsWidgets);
      await tester.scrollUntilVisible(find.byKey(const Key('ql-stage-9')), 300);
      for (var n = 1; n <= 9; n++) {
        expect(find.byKey(Key('ql-stage-$n')), findsOneWidget);
      }
    });

    testWidgets('daily goal sheet changes and saves the goal', (tester) async {
      final p = qlShotProgress();
      await _pump(tester, QuranLearnScreen(progress: p));
      await tester.tap(find.byKey(const Key('ql-goal')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ql-goal-20')));
      await tester.pumpAndSettle();
      expect(p.goal, 20);
      expect((await QlProgressStore.load()).goal, 20);
    });

    testWidgets('letters: tap a big letter, honest no-audio, mark learned',
        (tester) async {
      final p = QlProgress();
      await _pump(tester,
          QuranLessonScreen(stage: kQlStages[0], lesson: kQlStages[0].lessons[0], progress: p));
      expect(find.byKey(const Key('ql-focus')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('ql-tile-l_ba'), skipOffstage: false));
      await tester.pump();
      await tester.tap(find.byKey(const Key('ql-tile-l_ba')));
      await tester.pump();
      final focus = tester.widget<Text>(find.byKey(const Key('ql-focus-text')));
      expect(focus.data, 'ب');
      expect(find.textContaining('lips'), findsWidgets); // makhraj note
      // Listen: no licensed audio -> explains, never a fake sound
      await tester.ensureVisible(find.byKey(const Key('ql-listen-l_ba'), skipOffstage: false));
      await tester.pump();
      await tester.tap(find.byKey(const Key('ql-listen-l_ba')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ql-no-audio')), findsOneWidget);
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      // mark learned -> progress + saved
      await tester.ensureVisible(find.byKey(const Key('ql-learned-l_ba'), skipOffstage: false));
      await tester.pump();
      await tester.tap(find.byKey(const Key('ql-learned-l_ba')));
      await tester.pump();
      expect(p.learned, contains('l_ba'));
      await tester.pump();
      expect((await QlProgressStore.load()).learned, contains('l_ba'));
      // alif has no checkable letter: the check button is replaced by a note
      await tester.ensureVisible(find.byKey(const Key('ql-tile-l_alif'), skipOffstage: false));
      await tester.pump();
      await tester.tap(find.byKey(const Key('ql-tile-l_alif')));
      await tester.pump();
      expect(find.byKey(const Key('ql-check-l_alif')), findsOneWidget); // name ألف is checkable
    });

    testWidgets('ayat lesson shows the real Uthmani text with its reference',
        (tester) async {
      preloadRealUthmani();
      await _pump(tester,
          QuranLessonScreen(stage: kQlStages[7], lesson: kQlStages[7].lessons[1], progress: QlProgress()));
      expect(find.text(realUthmani().text(const QlRef(112, 1, 4))!), findsOneWidget);
      expect(find.text('Quran 112:1'), findsOneWidget);
      expect(find.byKey(const Key('ql-check-a112_1')), findsOneWidget);
    });

    testWidgets('check sheet: helper label, score, missed word', (tester) async {
      await _pump(
          tester,
          const Scaffold(
              body: ReciteSheet(
                  expected: 'قُلْ هُوَ ٱللَّهُ أَحَدٌ', initialHeard: 'قل هو الله')));
      expect(find.text('Helper - not a replacement for a teacher'), findsOneWidget);
      expect(find.byKey(const Key('ql-recite-result')), findsOneWidget);
      expect(find.textContaining('Letters matched'), findsOneWidget);
    });

    testWidgets('200% font at 360 dp: lesson + home without overflow',
        (tester) async {
      preloadRealUthmani();
      await _pump(
          tester,
          QuranLessonScreen(
              stage: kQlStages[8], lesson: kQlStages[8].lessons[2], progress: QlProgress()),
          lang: 'bn',
          scale: 2.0,
          size: const Size(360, 780));
      expect(tester.takeException(), isNull);
      await _pump(tester,
          QuranLessonScreen(stage: kQlStages[4], lesson: kQlStages[4].lessons[0], progress: QlProgress()),
          lang: 'bn', scale: 2.0, size: const Size(360, 780));
      expect(tester.takeException(), isNull);
      await _pump(tester, QuranLearnScreen(progress: qlShotProgress()),
          lang: 'bn', scale: 2.0, size: const Size(360, 780));
      expect(tester.takeException(), isNull);
    });
  });
}
