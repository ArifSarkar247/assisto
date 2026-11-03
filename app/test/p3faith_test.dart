// p3faith (owner PART 3, 3 Nov 2026): Ramadan tracker + offline Quran.
//
// Quran: the bundled files are Tanzil's VERBATIM (sha256 pinned = no change,
// CC BY 3.0 term), 114 suras / 6236 ayas, notice kept, search (English +
// diacritic-free Arabic), sura finder, bookmarks + last read persist, Bangla
// shows "awaiting licence" (never a translation we do not have).
// Ramadan: district mode (no GPS) loads IFB times + district chip, no
// location -> district chooser (no dead end), offline fallback from the
// saved month table, worship log math.
import 'dart:convert';
import 'dart:io';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/quran/quran_store.dart';
import 'package:assisto/screens/quran_screen.dart';
import 'package:assisto/screens/ramadan_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/ramadan_daily_tracker.dart';
import 'package:assisto/widgets/ramadan_district.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api.dart' show FakeMode;
import 'quran_fixture.dart';
import 'screenshots_test.dart' as gallery;

Future<void> _pump(WidgetTester tester, Widget screen, {String lang = 'en'}) async {
  final app = gallery.galleryStub(lang: lang, mode: FakeMode.data);
  await tester.binding.setSurfaceSize(const Size(400, 900));
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
      home: screen,
    ),
  ));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

String _gunzip(String path) =>
    utf8.decode(gzip.decode(File(path).readAsBytesSync()));

void main() {
  group('Quran data (licensed, verbatim)', () {
    test('bundled files are the exact Tanzil downloads (no change)', () {
      expect(
          sha256.convert(utf8.encode(_gunzip('assets/quran/quran-simple.txt.gz'))).toString(),
          'b3638f5cf03e2b05e4000efc0e4b656aafb3cf6ed28f8770b6497c5b43c46089');
      expect(
          sha256.convert(utf8.encode(_gunzip('assets/quran/en.pickthall.txt.gz'))).toString(),
          '4aabbfa9d96796f5a6b0217d2c39dce1a3084f772bf6f2650e37082a774e3cc7');
      expect(
          sha256.convert(utf8.encode(_gunzip('assets/quran/quran-uthmani.txt.gz'))).toString(),
          '7f30c647331a61100ebf24a80507dc0fcdd9f2df97f1312b5b2dfcb982a7f326');
      expect(File('assets/quran/SOURCES.txt').readAsStringSync(),
          contains('Creative Commons Attribution 3.0'));
    });

    test('114 suras, 6236 ayas, notice kept, refs + juz', () {
      final d = realQuranData();
      expect(d.suras.length, 114);
      expect(d.arabic.length, 6236);
      expect(d.uthmani.length, 6236);
      expect(d.uthmani, isNot(same(d.arabic))); // reading text = Uthmani
      expect(d.arabicNotice, contains('Uthmani'));
      expect(d.english.length, 6236);
      expect(d.arabic.every((s) => s.isNotEmpty), isTrue);
      expect(d.english.every((s) => s.isNotEmpty), isTrue);
      expect(d.suras.fold<int>(0, (a, s) => a + s.ayas), 6236);
      expect(d.arabicNotice, contains('Tanzil'));
      expect(d.arabicNotice, contains('Creative Commons Attribution 3.0'));
      expect(d.en(const AyaRef(1, 1)),
          'In the name of Allah, the Beneficent, the Merciful.');
      expect(d.refAt(7), const AyaRef(2, 1));
      expect(d.refAt(6235), const AyaRef(114, 6));
      expect(d.juzOf(const AyaRef(2, 141)), 1);
      expect(d.juzOf(const AyaRef(2, 142)), 2);
      expect(d.juzOf(const AyaRef(114, 6)), 30);
      expect(d.suras[17].tname, 'Al-Kahf');
    });

    test('parseTanzil refuses a truncated file', () {
      expect(() => parseTanzil('1|1|x\n', 6236), throwsFormatException);
    });

    test('search: English words and Arabic without diacritics', () {
      final d = realQuranData();
      final en = d.search('whispereth');
      expect(en.map((h) => h.ref), contains(const AyaRef(114, 5)));
      expect(en.every((h) => h.text.toLowerCase().contains('whispereth')), isTrue);
      // the bare (no harakat) spelling finds the vocalised verse
      final ar = d.search(d.arSimple(const AyaRef(1, 2)).replaceAll(
          RegExp('[ً-ٰٟ]'), ''));
      expect(ar.map((h) => h.ref), contains(const AyaRef(1, 2)));
      expect(d.search('a'), isEmpty); // too short
      expect(d.search('zzqqxx'), isEmpty);
    });

    test('sura finder: number, transliteration, meaning', () {
      final d = realQuranData();
      expect(d.findSuras('18').single.index, 18);
      expect(d.findSuras('kahf').map((s) => s.index), contains(18));
      expect(d.findSuras('cave').map((s) => s.index), contains(18));
      expect(d.findSuras('999'), isEmpty);
      expect(d.findSuras('').length, 114);
    });

    test('bookmarks + last read persist', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await QuranPrefs.toggleBookmark(const AyaRef(2, 255)), isTrue);
      expect(await QuranPrefs.bookmarks(), [const AyaRef(2, 255)]);
      expect(await QuranPrefs.toggleBookmark(const AyaRef(2, 255)), isFalse);
      expect(await QuranPrefs.bookmarks(), isEmpty);
      await QuranPrefs.setLastRead(const AyaRef(18, 10));
      expect(await QuranPrefs.lastRead(), const AyaRef(18, 10));
      expect(AyaRef.parse('0:1'), isNull);
      expect(AyaRef.parse('junk'), isNull);
    });
  });

  group('Quran screens', () {
    testWidgets('list -> continue card -> reader; bookmark persists', (tester) async {
      SharedPreferences.setMockInitialValues({'quran_last_read_v1': '18:10'});
      preloadRealQuran();
      await _pump(tester, const QuranScreen());
      expect(find.byKey(const Key('quran-continue')), findsOneWidget);
      expect(find.byKey(const Key('quran-sura-1')), findsOneWidget);
      await tester.tap(find.byKey(const Key('quran-sura-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('quran-reader')), findsOneWidget);
      await tester.tap(find.byKey(const Key('quran-bm-2')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(await QuranPrefs.bookmarks(), [const AyaRef(1, 2)]);
    });

    testWidgets('Bangla: honest awaiting-licence banner, one tap to English', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final d = realQuranData();
      await _pump(tester, QuranReaderScreen(data: d, sura: 112), lang: 'bn');
      expect(find.byKey(const Key('quran-bn-pending')), findsOneWidget);
      expect(find.text(d.en(const AyaRef(112, 1))), findsNothing);
      await tester.tap(find.byKey(const Key('quran-show-english')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('quran-bn-pending')), findsNothing);
      expect(find.text(d.en(const AyaRef(112, 1))), findsOneWidget);
      expect(await QuranPrefs.translation(), QuranTrans.en);
    });

    testWidgets('jump to a verse + show earlier', (tester) async {
      SharedPreferences.setMockInitialValues({'quran_translation_v1': 'en'});
      final d = realQuranData();
      await _pump(tester, QuranReaderScreen(data: d, sura: 2, aya: 255));
      expect(find.text(d.en(const AyaRef(2, 255))), findsOneWidget);
      expect(find.byKey(const Key('quran-show-earlier')), findsOneWidget);
      await tester.tap(find.byKey(const Key('quran-show-earlier')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text(d.en(const AyaRef(2, 1))), findsOneWidget);
    });

    testWidgets('empty bookmarks: benefit + button + how-to', (tester) async {
      SharedPreferences.setMockInitialValues({});
      preloadRealQuran();
      await _pump(tester, const QuranScreen());
      await tester.tap(find.byType(Tab).last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('quran-bookmarks-empty')), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is FilledButton), findsOneWidget);
    });
  });

  group('Ramadan tracker', () {
    testWidgets('saved district: IFB times, district chip, approx card', (tester) async {
      SharedPreferences.setMockInitialValues({'ramadan_district_v1': 'dhaka'});
      await _pump(tester, const RamadanScreen());
      expect(find.byKey(const Key('ramadan-ifb-note')), findsOneWidget);
      expect(find.byKey(const Key('ramadan-district-chip')), findsOneWidget);
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.byKey(const Key('ramadan-approx')), 300,
          scrollable: list);
      expect(find.byKey(const Key('ramadan-approx')), findsOneWidget);
      await tester.scrollUntilVisible(
          find.byKey(const Key('ramadan-daily-tracker')), 300,
          scrollable: list);
      expect(find.byKey(const Key('ramadan-daily-tracker')), findsOneWidget);
      final p = await SharedPreferences.getInstance();
      expect(p.getString('ramadan_times_v1'), contains('"district":"dhaka"'));
      expect(p.getString('ramadan_month_v1'), contains('2027-02-08'));
    });

    testWidgets('no location, no district -> district chooser, not a dead end', (tester) async {
      SharedPreferences.setMockInitialValues({});
      // plugin channels never answer in the test VM: location services OFF
      final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const geo = MethodChannel('flutter.baseflow.com/geolocator');
      m.setMockMethodCallHandler(
          geo, (call) async => call.method == 'isLocationServiceEnabled' ? false : null);
      addTearDown(() => m.setMockMethodCallHandler(geo, null));
      await _pump(tester, const RamadanScreen());
      expect(find.byKey(const Key('ramadan-district-prompt')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ramadan-pick-district')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(const Key('ramadan-district-sylhet')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ramadan-district-sylhet')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final p = await SharedPreferences.getInstance();
      expect(p.getString('ramadan_district_v1'), 'sylhet');
    });

    test('offline: today from the saved month table, never guessed', () async {
      SharedPreferences.setMockInitialValues({});
      await RamadanCache.saveMonth({
        'district': 'dhaka', 'name_bn': 'x', 'name_en': 'Dhaka',
        'days': [
          {'date': '2027-02-10', 'sehri_end': '05:15', 'iftar': '17:53',
           'fajr': '05:18', 'maghrib': '17:50'},
        ],
      });
      final t = await RamadanCache.offlineTimes(DateTime(2027, 2, 10));
      expect(t!['sehri_end'], '05:15');
      expect(t['iftar'], '17:53');
      expect(t['isha'], isNull); // not in the table -> hidden, not invented
      expect(await RamadanCache.offlineTimes(DateTime(2027, 5, 1)), isNull);
    });

    test('worship log: json round trip, clamp, 7-day sums, pruning', () async {
      SharedPreferences.setMockInitialValues({});
      final today = DateTime(2027, 2, 20);
      final log = <String, FaithDay>{
        FaithLog.dayKey(today): FaithDay.empty.withPrayer(0, true).withPrayer(4, true).withPages(3),
        FaithLog.dayKey(today.subtract(const Duration(days: 6))): FaithDay.empty.withPrayer(1, true),
        FaithLog.dayKey(today.subtract(const Duration(days: 7))): FaithDay.empty.withPages(9),
        FaithLog.dayKey(today.subtract(const Duration(days: 90))): FaithDay.empty.withPages(1),
      };
      final w = FaithLog.week(log, today);
      expect(w.prayed, 3);
      expect(w.possible, 35);
      expect(w.pages, 3);
      expect(FaithDay.empty.withPages(-4).pages, 0);
      expect(FaithDay.empty.withPages(9999).pages, FaithLog.maxPages);
      await FaithLog.save(log, today);
      final back = await FaithLog.load();
      expect(back.length, 3); // the 90-day-old entry is pruned
      expect(back[FaithLog.dayKey(today)]!.prayed, 2);
    });
  });
}
