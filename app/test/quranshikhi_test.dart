// quranshikhi (owner order 9 Nov 21:55, lane 16): Quran Shikhi letter lesson.
//
// Proves: Al-Fatiha + the last 10 suras (105-114) are lessons whose ayat come
// ONLY from the bundled verbatim Tanzil Uthmani file (never typed); the
// joining-letters drill reads by letter names; the four letter forms; the
// letter lesson shows Bangla AND English together in both app languages,
// each line can be hidden (never both) and the choice is saved; every
// explanation carries "under review"; the streak chip; the listen-and-repeat
// sheet says "practice measure, not a replacement for a teacher" and why the
// microphone is used; 200% font at 360 dp without overflow.
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/l10n/quran_learn_content.dart';
import 'package:assisto/quran_learn/learn_progress.dart';
import 'package:assisto/quran_learn/qaida_model.dart';
import 'package:assisto/quran_learn/quran_learn_screen.dart';
import 'package:assisto/quran_learn/recite_sheet.dart';
import 'package:assisto/quran_learn/shikhi_widgets.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
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

QlLesson _lesson(String id) =>
    kQlStages.expand((s) => s.lessons).firstWhere((l) => l.id == id);

Widget _letterLesson({String item = 'l_ba', QlProgress? p}) => QuranLessonScreen(
    key: UniqueKey(),
    stage: kQlStages[0],
    lesson: kQlStages[0].lessons[0],
    progress: p ?? QlProgress(),
    initialItem: item);

void main() {
  group('content', () {
    test('Al-Fatiha + the last 10 suras, every ayah a reference to the real text', () {
      final u = realUthmani();
      const suras = {
        'fatiha': (1, 7), 'fil': (105, 5), 'quraysh': (106, 4), 'maun': (107, 7),
        'kawthar': (108, 3), 'kafirun': (109, 6), 'nasr': (110, 3), 'masad': (111, 5),
        'ikhlas': (112, 4), 'falaq': (113, 5), 'nas': (114, 6),
      };
      for (final e in suras.entries) {
        final l = _lesson(e.key);
        final (sura, n) = e.value;
        expect(l.items.length, n, reason: e.key);
        for (var a = 0; a < n; a++) {
          final i = l.items[a];
          expect(i.ar, isNull, reason: 'Quran text is never typed: ${i.id}');
          expect((i.ref!.sura, i.ref!.ayah), (sura, a + 1), reason: i.id);
          expect(u.text(i.ref!), isNotEmpty, reason: i.id);
        }
      }
      // Ayah 1 of 105-114 starts after the basmala (4 words) - the rest is
      // the verbatim line.
      final fil1 = _lesson('fil').items.first.ref!;
      expect(fil1.from, 4);
      expect(u.text(fil1), startsWith('أَلَمْ'));
    });

    test('joining letters: our own drill, read by the letter names', () {
      final j = _lesson('joining');
      expect(kQlStages[0].lessons.last.id, 'joining');
      expect(j.items, hasLength(8));
      for (final i in j.items) {
        expect(i.ref, isNull);
        final letters = i.ar!.runes.length;
        expect(i.check!.split(' '), hasLength(letters), reason: i.id);
        expect(i.say!.bn, isNotEmpty);
        expect(i.say!.en, isNotEmpty);
        expect(i.note!.bn, isNotEmpty);
        expect(i.note!.en, isNotEmpty);
      }
      expect(j.items.where(qsIsLetter), isEmpty); // drills, not single letters
    });

    test('exactly the 29 alphabet items are letters with forms', () {
      final all = kQlStages.expand((s) => s.lessons).expand((l) => l.items);
      expect(all.where(qsIsLetter), hasLength(29));
    });

    test('letter forms: 4, 2 for the six non-joiners, 1 for hamza; letter kept', () {
      expect(qsLetterForms('ب').map((f) => f.$2), ['ب', 'بـ', 'ـبـ', 'ـب']);
      expect(qsLetterForms('د').map((f) => f.$2), ['د', 'ـد']);
      expect(qsLetterForms('ء').map((f) => f.$2), ['ء']);
      for (final i in kQlStages.expand((s) => s.lessons).expand((l) => l.items).where(qsIsLetter)) {
        final f = qsLetterForms(i.ar!);
        expect(f.length, i.ar == 'ء' ? 1 : (kQsNonLeftJoining.contains(i.ar) ? 2 : 4), reason: i.id);
        for (final x in f) {
          expect(x.$2.replaceAll('ـ', ''), i.ar, reason: i.id);
        }
      }
    });
  });

  group('letter lesson screen', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      QsLinePrefs.debugReset();
    });

    testWidgets('bn app: Bangla AND English makhraj, forms, under review', (tester) async {
      await _pump(tester, _letterLesson(), lang: 'bn');
      final ba = kQlStages[0].lessons[0].items.firstWhere((i) => i.id == 'l_ba');
      expect(tester.widget<Text>(find.byKey(const Key('ql-focus-text'))).data, 'ب');
      expect(find.text(ba.note!.bn), findsOneWidget);
      expect(find.text(ba.note!.en), findsOneWidget);
      expect(find.text(ba.say!.bn), findsWidgets);
      expect(find.text(ba.say!.en), findsWidgets);
      expect(find.byKey(const Key('qs-forms')), findsOneWidget);
      for (var k = 0; k < 4; k++) {
        expect(find.byKey(Key('qs-form-$k')), findsOneWidget);
      }
      expect(find.byKey(const Key('qs-under-review')), findsWidgets);
      expect(find.byKey(const Key('ql-experimental')), findsNothing); // home only
    });

    testWidgets('en app shows the Bangla line too (owner exception)', (tester) async {
      await _pump(tester, _letterLesson());
      final ba = kQlStages[0].lessons[0].items.firstWhere((i) => i.id == 'l_ba');
      expect(find.text(ba.note!.en), findsOneWidget);
      expect(find.text(ba.note!.bn), findsOneWidget);
    });

    testWidgets('hide a line; the last line can not be hidden; choice saved', (tester) async {
      await _pump(tester, _letterLesson(), lang: 'bn');
      final ba = kQlStages[0].lessons[0].items.firstWhere((i) => i.id == 'l_ba');
      await tester.tap(find.byKey(const Key('qs-line-en')));
      await tester.pump();
      expect(find.text(ba.note!.en), findsNothing);
      expect(find.text(ba.note!.bn), findsOneWidget);
      // Bangla is now the only line: tapping it keeps it.
      await tester.tap(find.byKey(const Key('qs-line-bn')));
      await tester.pump();
      expect(find.text(ba.note!.bn), findsOneWidget);
      expect((await SharedPreferences.getInstance()).getString(QsLinePrefs.prefsKey), 'bn');
      await tester.tap(find.byKey(const Key('qs-line-en')));
      await tester.pump();
      expect(find.text(ba.note!.en), findsOneWidget);
      expect((await SharedPreferences.getInstance()).getString(QsLinePrefs.prefsKey), 'both');
    });

    testWidgets('saved choice is restored', (tester) async {
      SharedPreferences.setMockInitialValues({QsLinePrefs.prefsKey: 'en'});
      QsLinePrefs.debugReset();
      await _pump(tester, _letterLesson(), lang: 'bn');
      final ba = kQlStages[0].lessons[0].items.firstWhere((i) => i.id == 'l_ba');
      expect(find.text(ba.note!.bn), findsNothing);
      expect(find.text(ba.note!.en), findsOneWidget);
    });

    testWidgets('non-joining letter shows two forms + why', (tester) async {
      await _pump(tester, _letterLesson(item: 'l_alif'));
      expect(find.byKey(const Key('qs-form-1')), findsOneWidget);
      expect(find.byKey(const Key('qs-form-2')), findsNothing);
      expect(find.textContaining('never joins the letter after it'), findsOneWidget);
    });

    testWidgets('streak chip on the lesson when practised on days in a row', (tester) async {
      await _pump(tester, _letterLesson(p: qlShotProgress()));
      expect(find.byKey(const Key('qs-streak')), findsOneWidget);
      await _pump(tester, _letterLesson(p: QlProgress()));
      expect(find.byKey(const Key('qs-streak')), findsNothing);
    });

    testWidgets('joining lesson: the drill with names, no forms', (tester) async {
      await _pump(
          tester,
          QuranLessonScreen(
              stage: kQlStages[0], lesson: _lesson('joining'), progress: QlProgress()));
      expect(tester.widget<Text>(find.byKey(const Key('ql-focus-text'))).data, 'بتث');
      expect(find.byKey(const Key('qs-forms')), findsNothing);
      expect(find.text('Ba - Ta - Tha'), findsOneWidget);
      expect(find.byKey(const Key('ql-check-j_ba')), findsOneWidget);
    });

    testWidgets('new sura lesson shows the verbatim ayah', (tester) async {
      preloadRealUthmani();
      await _pump(tester,
          QuranLessonScreen(stage: kQlStages[7], lesson: _lesson('nasr'), progress: QlProgress()));
      expect(find.text(realUthmani().text(const QlRef(110, 2))!), findsOneWidget);
    });

    testWidgets('listen-and-repeat: practice measure + microphone reason', (tester) async {
      await _pump(
          tester,
          const Scaffold(
              body: ReciteSheet(expected: 'بَ', initialHeard: 'با')));
      expect(find.text('Practice measure, not a replacement for a teacher'), findsOneWidget);
      expect(find.byKey(const Key('qs-mic-reason')), findsOneWidget);
    });

    testWidgets('200% font at 360 dp: letter + joining lessons, bn and en', (tester) async {
      for (final lang in ['bn', 'en']) {
        await _pump(tester, _letterLesson(), lang: lang, scale: 2.0, size: const Size(360, 780));
        expect(tester.takeException(), isNull, reason: lang);
        await _pump(
            tester,
            QuranLessonScreen(
                key: UniqueKey(), stage: kQlStages[0], lesson: _lesson('joining'), progress: QlProgress()),
            lang: lang,
            scale: 2.0,
            size: const Size(360, 780));
        expect(tester.takeException(), isNull, reason: lang);
      }
    });
  });
}
