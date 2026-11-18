// quranview (lane 14): bilingual ayah view + tafsir / shane nuzul sheet.
// Spec: owner_actions/QURAN_BILINGUAL_SPEC_BN.md.
import 'dart:async';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/quran/ayah_view_screen.dart';
import 'package:assisto/quran/quran_ayah_audio.dart';
import 'package:assisto/quran/quran_bilingual_api.dart';
import 'package:assisto/quran/quran_store.dart';
import 'package:assisto/quran/quran_tafsir_sheet.dart';
import 'package:assisto/screens/quran_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api.dart' show FakeMode;
import 'quran_fixture.dart';
import 'quranview_fixture.dart';
import 'screenshots_test.dart' as gallery;

Future<void> _pump(WidgetTester tester, Widget screen,
    {String lang = 'en', Brightness b = Brightness.light}) async {
  final app = gallery.galleryStub(lang: lang, mode: FakeMode.data);
  // tall surface: the lazy ListView builds every block (no scroll needed)
  await tester.binding.setSurfaceSize(const Size(400, 4000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  // Flutter 3.50: setSurfaceSize alone no longer sizes the test view -> set
  // the view itself too, so the lazy list keeps every block built.
  tester.view.physicalSize = const Size(400, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
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
      theme: b == Brightness.light ? AssistoTheme.light : AssistoTheme.dark,
      home: screen,
    ),
  ));
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// ListView children are built lazily: scroll the outer list to [f].
Future<void> _see(WidgetTester tester, Finder f) => tester.scrollUntilVisible(
    f, 250, scrollable: find.byType(Scrollable).first);

QuranBilingualApi _api({bool qfOn = true, List<String>? log}) =>
    QuranBilingualApi((p) async {
      log?.add(p);
      return fakeQuranViewGet(p, qfOn: qfOn)!;
    });

class _FakePlayer implements QvPlayer {
  final played = <String>[];
  final _done = StreamController<void>.broadcast();
  bool stopped = false;
  @override
  Future<void> playUrl(String url) async => played.add(url);
  @override
  Future<void> stop() async => stopped = true;
  @override
  Stream<void> get completed => _done.stream;
  void finish() => _done.add(null);
  @override
  Future<void> dispose() async {}
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    QuranBilingualApi.clearForTest();
  });

  group('ayah view', () {
    testWidgets('English app mode still shows Bangla AND English, each with a source line',
        (tester) async {
      final d = realQuranData();
      await _pump(tester, AyahViewScreen(data: d, sura: 1, aya: 1, api: _api()));
      // Arabic = the bundled Tanzil Uthmani text, unchanged
      expect(find.text(d.ar(const AyaRef(1, 1))), findsOneWidget);
      // Bangla meaning (QuranEnc Zakaria) + English meaning (Saheeh), verbatim
      expect(find.text(qvMeaning(1)['bn']['items'][0]['text'] as String), findsOneWidget);
      expect(find.text(qvMeaning(1)['en']['items'][0]['text'] as String), findsOneWidget);
      expect(find.textContaining('version 1.1.1'), findsOneWidget);
      expect(find.textContaining('version 1.1.2'), findsOneWidget);
      // pronunciation (lane 15) is labelled under review
      expect(find.byKey(const Key('qv-pron-text')), findsOneWidget);
      expect(find.byKey(const Key('qv-under-review')), findsOneWidget);
      // QF blocks + credit
      expect(find.text('Bismi Allahi alrrahmani alrraheemi'), findsOneWidget);
      expect(find.text('আল্লাহর'), findsOneWidget);
      expect(find.text('(of) Allah'), findsOneWidget);
      expect(find.byKey(const Key('qv-play')), findsOneWidget);
      await _see(tester, find.byKey(const Key('qv-qf-credit')));
      expect(find.byKey(const Key('qv-qf-credit')), findsOneWidget);
      expect(find.byKey(const Key('qv-noai')), findsOneWidget);
    });

    testWidgets('Bangla mode: Bangla digits in the source line, English still shown',
        (tester) async {
      await _pump(tester,
          AyahViewScreen(data: realQuranData(), sura: 1, aya: 1, api: _api()),
          lang: 'bn', b: Brightness.dark);
      expect(find.textContaining('সংস্করণ ১.১.১'), findsOneWidget);
      expect(find.text(qvMeaning(1)['en']['items'][0]['text'] as String), findsOneWidget);
    });

    testWidgets('each line can be switched off and it stays off', (tester) async {
      await _pump(tester, AyahViewScreen(data: realQuranData(), sura: 1, aya: 1, api: _api()));
      expect(find.byKey(const Key('qv-meaning-en')), findsOneWidget);
      await tester.tap(find.byKey(const Key('qv-lines')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('qv-line-en')));
      await tester.pumpAndSettle();
      expect(await QvPrefs.hidden(), {QvLine.en});
      Navigator.of(tester.element(find.byKey(const Key('qv-line-en')))).pop();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('qv-meaning-en')), findsNothing);
      expect(find.byKey(const Key('qv-meaning-bn')), findsOneWidget);
    });

    testWidgets('QF not connected: its blocks are hidden (no showpiece, no dead button)',
        (tester) async {
      await _pump(tester,
          AyahViewScreen(data: realQuranData(), sura: 1, aya: 1, api: _api(qfOn: false)));
      expect(find.byKey(const Key('qv-translit')), findsNothing);
      expect(find.byKey(const Key('qv-words')), findsNothing);
      expect(find.byKey(const Key('qv-audio')), findsNothing);
      expect(find.byKey(const Key('qv-play')), findsNothing);
      // QuranEnc meaning still shows
      expect(find.byKey(const Key('qv-meaning-bn-text')), findsOneWidget);
    });

    testWidgets('pronunciation missing (engine not live) -> block hidden',
        (tester) async {
      final api = QuranBilingualApi((p) async {
        if (p.startsWith('/quran/pron')) throw Exception('404');
        return fakeQuranViewGet(p)!;
      });
      await _pump(tester, AyahViewScreen(data: realQuranData(), sura: 1, aya: 1, api: api));
      expect(find.byKey(const Key('qv-pron')), findsNothing);
      expect(find.byKey(const Key('qv-meaning-bn-text')), findsOneWidget);
    });

    testWidgets('pronunciation: rejected line hidden, only the fixed note shown',
        (tester) async {
      final api = QuranBilingualApi((p) async {
        if (p.startsWith('/quran/pron')) {
          return {
            'ok': true, 'surah': 1, 'label': 'under_review',
            'legend_bn': 'চিহ্ন: - = ২ মাত্রা',
            'items': [
              {'ayah': 1, 'bn': 'পরীক্ষা\u200cলাইন', 'review': 'rejected', 'note_bn': 'সংশোধন চলছে'},
            ],
          };
        }
        return fakeQuranViewGet(p)!;
      });
      await _pump(tester, AyahViewScreen(data: realQuranData(), sura: 1, aya: 1, api: api));
      expect(find.byKey(const Key('qv-pron-text')), findsNothing);
      expect(find.text('সংশোধন চলছে'), findsOneWidget);
      expect(find.byKey(const Key('qv-under-review')), findsOneWidget);
    });

    testWidgets('audio: repeat 3 plays the ayah three times, then stops', (tester) async {
      final pl = _FakePlayer();
      await _pump(tester,
          AyahViewScreen(data: realQuranData(), sura: 1, aya: 1, api: _api(), player: pl));
      await _see(tester, find.byKey(const Key('qv-play')));
      await tester.tap(find.byKey(const Key('qv-repeat-3')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('qv-play')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(pl.played.length, 1);
      expect(pl.played.first, startsWith('https://verses.quran.foundation/'));
      expect(find.byKey(const Key('qv-playing')), findsOneWidget);
      pl.finish();
      await tester.pump(const Duration(milliseconds: 50));
      pl.finish();
      await tester.pump(const Duration(milliseconds: 50));
      expect(pl.played.length, 3);
      pl.finish();
      await tester.pump(const Duration(milliseconds: 50));
      expect(pl.played.length, 3);
      expect(find.byKey(const Key('qv-playing')), findsNothing);
      expect(await QvPrefs.audio(), (null, 3));
    });

    testWidgets('next / previous ayah loads that ayah', (tester) async {
      final log = <String>[];
      await _pump(tester,
          AyahViewScreen(data: realQuranData(), sura: 1, aya: 1, api: _api(log: log)));
      await _see(tester, find.byKey(const Key('qv-next')));
      expect(tester.widget<OutlinedButton>(find.byKey(const Key('qv-prev'))).onPressed, isNull);
      await tester.tap(find.byKey(const Key('qv-next')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(log, contains('/quran/qf/1/2'));
      expect(find.text(realQuranData().ar(const AyaRef(1, 2))), findsOneWidget);
    });

    testWidgets('reader: ayah button opens the ayah view (real app API path)',
        (tester) async {
      await _pump(tester, QuranReaderScreen(data: realQuranData(), sura: 1));
      await tester.tap(find.byKey(const Key('quran-ayah-1')));
      await tester.pumpAndSettle();
      expect(find.byType(AyahViewScreen), findsOneWidget);
      expect(find.byKey(const Key('qv-meaning-bn-text')), findsOneWidget);
    });
  });

  group('tafsir & shane nuzul sheet', () {
    testWidgets('shane nuzul = the source unit itself, verbatim, under review',
        (tester) async {
      await _pump(tester, Scaffold(body: QuranTafsirBody(api: _api(), sura: 80, aya: 1)));
      expect(find.byKey(const Key('qv-src-zakaria_notes_bn')), findsOneWidget);
      expect(find.byKey(const Key('qv-src-mukhtasar_bn')), findsOneWidget);
      await _see(tester, find.byKey(const Key('qv-tafsir-source')));
      expect(find.byKey(const Key('qv-shan-text')), findsOneWidget);
      expect(find.byKey(const Key('qv-shan-none')), findsNothing);
      expect(find.textContaining('version 1.1.1'), findsOneWidget);
      // switching to the Mukhtasar chip: that source states no reason here
      // Flutter 3.50 (b327 toolchain pin): select the chip through its own
      // callback — the scroll-then-tap missed the chip on the new toolchain.
      final chip = find.byKey(const Key('qv-src-mukhtasar_bn'));
      // the lazy list disposed the chips after scrolling down: scroll back up
      await tester.scrollUntilVisible(chip, -250, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      tester.widget<ChoiceChip>(chip).onSelected!(true);
      await tester.pumpAndSettle();
      await _see(tester, find.byKey(const Key('qv-tafsir-source')));
      expect(find.byKey(const Key('qv-shan-none')), findsOneWidget);
      expect(find.textContaining('version 1.0.0'), findsOneWidget);
    });

    testWidgets('no shane nuzul in the source -> the clear "none" line', (tester) async {
      await _pump(tester, Scaffold(body: QuranTafsirBody(api: _api(), sura: 1, aya: 1)));
      await _see(tester, find.byKey(const Key('qv-tafsir-pending-note')));
      expect(find.byKey(const Key('qv-shan-none')), findsOneWidget);
      expect(find.byKey(const Key('qv-tafsir-pending-note')), findsOneWidget);
    });

    testWidgets('unlicensed QUL tafsirs are never offered as chips', (tester) async {
      await _pump(tester, Scaffold(body: QuranTafsirBody(api: _api(), sura: 80, aya: 1)));
      for (final id in ['ibn_kathir', 'ahsanul_bayaan', 'fathul_majid', 'qul']) {
        expect(find.byWidgetPredicate((w) => '${w.key}'.contains(id)), findsNothing);
      }
    });

    testWidgets('load failure -> retry, never invented text', (tester) async {
      final api = QuranBilingualApi((p) async => throw Exception('offline'));
      await _pump(tester, Scaffold(body: QuranTafsirBody(api: api, sura: 1, aya: 1)));
      expect(find.byKey(const Key('qv-tafsir-failed')), findsOneWidget);
    });
  });

  group('cache rules', () {
    test('Quran Foundation data is never kept past 6 days (QF terms: 7)', () async {
      var now = DateTime(2026, 11, 9);
      var calls = 0;
      var fail = false;
      final api = QuranBilingualApi((p) async {
        calls++;
        if (fail) throw Exception('offline');
        return fakeQuranViewGet(p)!;
      }, now: () => now);
      expect(await api.qf(1, 1), isNotNull);
      now = now.add(const Duration(days: 5));
      expect(await api.qf(1, 1), isNotNull);
      expect(calls, 1);
      now = now.add(const Duration(days: 2)); // 7 days old
      fail = true;
      expect(await api.qf(1, 1), isNull, reason: 'stale QF copy must not be shown');
      expect(calls, 2);
    });

    test('QuranEnc meaning: refreshed daily, last copy kept when offline', () async {
      var now = DateTime(2026, 11, 9);
      var fail = false;
      final api = QuranBilingualApi((p) async {
        if (fail) throw Exception('offline');
        return fakeQuranViewGet(p)!;
      }, now: () => now);
      expect(await api.meaning(1), isNotNull);
      now = now.add(const Duration(days: 3));
      fail = true;
      expect(await api.meaning(1), isNotNull);
    });

    test('banned audio hosts are refused', () {
      expect(qvBannedAudio('https://download.quranicaudio.com/x.mp3'), isTrue);
      expect(qvBannedAudio('https://everyayah.com/data/x.mp3'), isTrue);
      expect(qvBannedAudio('https://verses.quran.foundation/Alafasy/mp3/001001.mp3'), isFalse);
    });

    test('publisher <b> marks render bold; words unchanged', () {
      final r = qvRuns('<b> সূরা: </b>\n\nটেক্সট');
      expect(r, [(' সূরা: ', true), ('\n\nটেক্সট', false)]);
    });
  });
}
