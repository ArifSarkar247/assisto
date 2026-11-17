// gap-quranblood (owner order 17 Nov 10:10, feature gap sweep): Quran gaps
// Q1-Q6 and Blood donor gaps B2-B5, B8. Gap lists (Bangla):
// owner_actions/gaps/quran_BN.md, owner_actions/gaps/blood_BN.md.
// Quran texts come from the REAL bundled Tanzil files and the verbatim
// QuranEnc fixture — nothing invented.
import 'dart:async';
import 'dart:io' show Directory, File;

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/l10n/quran_learn_content.dart';
import 'package:assisto/l10n/quran_sura_names_bn.dart';
import 'package:assisto/quran/ayah_view_screen.dart';
import 'package:assisto/quran/quran_ayah_audio.dart';
import 'package:assisto/quran/quran_bilingual_api.dart';
import 'package:assisto/quran/quran_store.dart';
import 'package:assisto/quran_learn/learn_progress.dart';
import 'package:assisto/quran_learn/quran_learn_screen.dart';
import 'package:assisto/screens/blood/blood_donor_setup_screen.dart';
import 'package:assisto/screens/blood/blood_hub_screen.dart';
import 'package:assisto/screens/blood/blood_request_detail_screen.dart';
import 'package:assisto/screens/blood/bp_common.dart';
import 'package:assisto/screens/quran_screen.dart';
import 'package:assisto/services/review_prompt.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_blood.dart';
import 'quran_fixture.dart';
import 'quran_learn_fixture.dart';
import 'quranview_fixture.dart';

class _Blood extends ApiClient {
  _Blood() {
    token = 't';
  }
  final List<String> gets = [];
  final List<(String, Map<String, dynamic>)> posts = [];
  Map<String, dynamic>? meOverride;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    gets.add(path);
    final r = fakeBloodGet(path, bn: false, empty: false) ?? <String, dynamic>{};
    if (meOverride != null && path.startsWith('/blood-panel/config')) {
      return {...r, 'me': {...(r['me'] as Map<String, dynamic>), ...meOverride!}};
    }
    return r;
  }

  @override
  Future<Map<String, dynamic>> postJsonRaw(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts.add((path, Map.of(body)));
    return fakeBloodPost(path, bn: false) ?? {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> deleteJson(String path) async => {'ok': true};
}

class _BloodDown extends _Blood {
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path.startsWith('/blood-panel/donors')) {
      gets.add(path);
      throw ApiException('offline');
    }
    return super.getJson(path);
  }
}

/// Serves the quranview fixture to every screen that uses the app API.
class _QuranApi extends ApiClient {
  _QuranApi() {
    token = 't';
  }
  @override
  Future<Map<String, dynamic>> getJson(String path) async =>
      fakeQuranViewGet(path) ?? <String, dynamic>{};
}

Widget _app(Widget child, ApiClient api, {String lang = 'en'}) {
  final s = AppState();
  s.api = api;
  s.locale = Locale(lang);
  s.loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: s,
    child: MaterialApp(
      locale: Locale(lang),
      theme: AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: child,
    ),
  );
}

void _tall(WidgetTester t) {
  t.view.physicalSize = const Size(1080, 7000);
  t.view.devicePixelRatio = 2.5;
  addTearDown(t.view.reset);
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _tap(WidgetTester t, String key) async {
  final f = find.byKey(ValueKey(key));
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
}

QuranBilingualApi _qv({bool down = false}) => QuranBilingualApi((p) async =>
    down ? {'ok': false, 'reason': 'quranenc_unreachable'} : fakeQuranViewGet(p)!);

class _Player implements QvPlayer {
  final played = <String>[];
  final _done = StreamController<void>.broadcast();
  @override
  Future<void> playUrl(String url) async => played.add(url);
  @override
  Future<void> stop() async {}
  @override
  Stream<void> get completed => _done.stream;
  @override
  Future<void> dispose() async {}
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    ReviewPrompt.debugRequest = null;
    QuranBilingualApi.clearForTest();
  });

  // P0 found by reality qb1 (run 44194087656): Android's asset packager
  // strips ".gz" files, so "assets/quran/*.txt.gz" did not exist in the APK
  // and the Quran screen showed "could not open" on every phone.
  // aapt's default ignore list also skips names starting with "." and
  // directories starting with "_" (and "*~" backups).
  test('no bundled asset the Android build would drop', () {
    final bad = <String>[];
    for (final e in Directory('assets').listSync(recursive: true)) {
      final parts = e.path.split('/').skip(1).toList();
      final name = parts.last;
      final dirs = e is File ? parts.sublist(0, parts.length - 1) : parts;
      if ((e is File && (name.endsWith('.gz') || name.startsWith('.') || name.endsWith('~'))) ||
          dirs.any((d) => d.startsWith('_') || d.startsWith('.'))) {
        bad.add(e.path);
      }
    }
    expect(bad, isEmpty);
  });

  group('Quran Q3 names, digits, jump', () {
    test('114 Bangla names; Bangla name + Bangla digit search; sura:verse jump', () {
      final d = realQuranData();
      expect(kSuraNamesBn.length, 114);
      expect(kSuraNamesBn.toSet().length, 114);
      expect(quranSuraTitle(true, d.suras[17]), kSuraNamesBn[17]);
      expect(quranSuraTitle(false, d.suras[17]), d.suras[17].tname);
      // "কাহফ" (Kahf) without the article, and Bangla digits "১৮"
      expect(d.findSuras('কাহফ').map((s) => s.index), [18]);
      expect(d.findSuras('১৮').map((s) => s.index), [18]);
      expect(d.parseJump('2:255'), const AyaRef(2, 255));
      expect(d.parseJump('২:২৫৫'), const AyaRef(2, 255));
      expect(d.parseJump('18 10'), const AyaRef(18, 10));
      expect(d.parseJump('1:8'), isNull);    // Al-Fatiha has 7 verses
      expect(d.parseJump('115:1'), isNull);
      expect(d.parseJump('kahf'), isNull);
    });

    testWidgets('search "2:255" offers the jump; Bangla list shows Bangla names', (t) async {
      _tall(t);
      preloadRealQuran();
      await t.pumpWidget(_app(const QuranScreen(), _QuranApi(), lang: 'bn'));
      await _settle(t);
      expect(find.text(kSuraNamesBn[0]), findsOneWidget);
      await t.enterText(find.byKey(const Key('quran-search')), '২:২৫৫');
      await t.pump();
      await t.tap(find.byKey(const Key('quran-jump')));
      await _settle(t);
      final r = t.widget<QuranReaderScreen>(find.byType(QuranReaderScreen));
      expect((r.sura, r.aya), (2, 255));
    });
  });

  group('Quran Q4 paras', () {
    testWidgets('30 paras; para 30 opens An-Naba 1', (t) async {
      _tall(t);
      preloadRealQuran();
      await t.pumpWidget(_app(const QuranScreen(), _QuranApi()));
      await _settle(t);
      await t.tap(find.byKey(const Key('quran-tab-juz')));
      await _settle(t);
      expect(find.byKey(const Key('quran-juz-1')), findsOneWidget);
      await _tap(t, 'quran-juz-30');
      await _settle(t);
      final r = t.widget<QuranReaderScreen>(find.byType(QuranReaderScreen));
      expect((r.sura, r.aya), (78, 1));
    });
  });

  group('Quran Q1/Q2 reader', () {
    testWidgets('English app: Bangla AND English meaning inline, verbatim, with sources; Amiri font',
        (t) async {
      _tall(t);
      final d = realQuranData();
      await t.pumpWidget(_app(QuranReaderScreen(data: d, sura: 1, api: _qv()), _QuranApi()));
      await _settle(t);
      final m = qvMeaning(1);
      final bnText = (m['bn']['items'] as List).first['text'] as String;
      final enText = (m['en']['items'] as List).first['text'] as String;
      expect(t.widget<Text>(find.byKey(const Key('quran-bn-1'))).data, bnText);
      expect(t.widget<Text>(find.byKey(const Key('quran-en-1'))).data, enText);
      expect(find.byKey(const Key('quran-src-bn')), findsOneWidget);
      expect(find.byKey(const Key('quran-pron-1')), findsOneWidget);
      expect(find.byKey(const Key('qv-under-review')), findsOneWidget);
      final ar = t.widget<Text>(find.text(d.ar(const AyaRef(1, 1))).first);
      expect(ar.style?.fontFamily, kQvArabicFont);
    });

    testWidgets('a line switched off stays off (shared with the ayah view)', (t) async {
      _tall(t);
      final d = realQuranData();
      await t.pumpWidget(_app(QuranReaderScreen(data: d, sura: 1, api: _qv()), _QuranApi()));
      await _settle(t);
      await t.tap(find.byKey(const Key('quran-settings')));
      await _settle(t);
      await t.tap(find.byKey(const Key('quran-line-bn')));
      await _settle(t);
      expect(await QvPrefs.hidden(), contains(QvLine.bn));
      await t.tapAt(const Offset(10, 10));
      await _settle(t);
      expect(find.byKey(const Key('quran-bn-1')), findsNothing);
      expect(find.byKey(const Key('quran-en-1')), findsOneWidget);
    });

    testWidgets('source down: offline English (Pickthall) + retry, never invented text', (t) async {
      _tall(t);
      final d = realQuranData();
      await t.pumpWidget(
          _app(QuranReaderScreen(data: d, sura: 112, api: _qv(down: true)), _QuranApi()));
      await _settle(t);
      expect(find.byKey(const Key('quran-meaning-retry')), findsOneWidget);
      expect(find.byKey(const Key('quran-bn-1')), findsNothing);
      expect(t.widget<Text>(find.byKey(const Key('quran-en-1'))).data, d.en(const AyaRef(112, 1)));
    });
  });

  group('Quran Q5 next sura', () {
    testWidgets('reader end -> next sura; the last sura has none', (t) async {
      _tall(t);
      final d = realQuranData();
      await t.pumpWidget(_app(QuranReaderScreen(data: d, sura: 113, api: _qv()), _QuranApi()));
      await _settle(t);
      await _tap(t, 'quran-next-sura');
      await _settle(t);
      expect(t.widget<QuranReaderScreen>(find.byType(QuranReaderScreen)).sura, 114);
      expect(find.byKey(const Key('quran-next-sura')), findsNothing);
    });

    testWidgets('ayah view: last verse -> next sura verse 1', (t) async {
      _tall(t);
      final d = realQuranData();
      await t.pumpWidget(_app(
          AyahViewScreen(data: d, sura: 1, aya: 7, api: _qv(), player: QvSilentPlayer()),
          _QuranApi()));
      await _settle(t);
      await _tap(t, 'qv-next');
      await _settle(t);
      final v = t.widget<AyahViewScreen>(find.byType(AyahViewScreen));
      expect((v.sura, v.aya), (2, 1));
    });
  });

  group('Quran Shikhi Q6 listen', () {
    testWidgets('whole ayah plays the licensed QF recitation; a letter stays honest', (t) async {
      _tall(t);
      preloadRealUthmani();
      final player = _Player();
      final fatiha = kQlStages[7].lessons.firstWhere((l) => l.id == 'fatiha');
      await t.pumpWidget(_app(
          QuranLessonScreen(
              stage: kQlStages[7], lesson: fatiha, progress: QlProgress(), api: _qv(), player: player),
          _QuranApi()));
      await _settle(t);
      await _tap(t, 'ql-listen-a1_1');
      await _settle(t);
      expect(player.played.single, startsWith('https://verses.quran.foundation/'));
      expect(player.played.single.contains('quranicaudio'), isFalse);
    });

    testWidgets('QF not connected: honest no-audio sheet, nothing played', (t) async {
      _tall(t);
      preloadRealUthmani();
      final player = _Player();
      final fatiha = kQlStages[7].lessons.firstWhere((l) => l.id == 'fatiha');
      final off = QuranBilingualApi((p) async => fakeQuranViewGet(p, qfOn: false)!);
      await t.pumpWidget(_app(
          QuranLessonScreen(
              stage: kQlStages[7], lesson: fatiha, progress: QlProgress(), api: off, player: player),
          _QuranApi()));
      await _settle(t);
      await _tap(t, 'ql-listen-a1_1');
      await _settle(t);
      expect(player.played, isEmpty);
      expect(find.byType(BottomSheet), findsOneWidget);
    });
  });

  group('Blood', () {
    testWidgets('B2 share text: group, bags, hospital, area, time, link — never a number or note',
        (t) async {
      _tall(t);
      String? shared;
      bpShareOut = (s) async => shared = s;
      addTearDown(() => bpShareOut = (s) async {});
      await t.pumpWidget(_app(const BloodRequestDetailScreen(requestId: 31), _Blood()));
      await t.pumpAndSettle();
      await _tap(t, 'bp-req-share');
      await t.pump();
      expect(shared, isNotNull);
      expect(shared, contains(kBpSiteLink));
      expect(RegExp(r'01[3-9]\d{8}').hasMatch(shared!), isFalse);
      final r = fakeBloodGet('/blood-panel/requests/31', bn: false, empty: false)!;
      expect(shared, contains('${r['hospital']}'));
      if ('${r['note'] ?? ''}'.isNotEmpty) expect(shared!.contains('${r['note']}'), isFalse);
    });

    testWidgets('B3 compatible chip sends compatible=1 with the group', (t) async {
      _tall(t);
      final api = _Blood();
      await t.pumpWidget(_app(const BloodHubScreen(), api));
      await t.pumpAndSettle();
      await _tap(t, 'bp-g-A+');
      await t.pumpAndSettle();
      await _tap(t, 'bp-compatible');
      await t.pumpAndSettle();
      final q = Uri.parse(api.gets.lastWhere((p) => p.startsWith('/blood-panel/donors'))).queryParameters;
      expect(q['group'], 'A+');
      expect(q['compatible'], '1');
    });

    testWidgets('B5 search failure: reason + one-tap retry (no dead end)', (t) async {
      _tall(t);
      final api = _BloodDown();
      await t.pumpWidget(_app(const BloodHubScreen(), api));
      await t.pumpAndSettle();
      final before = api.gets.where((p) => p.startsWith('/blood-panel/donors')).length;
      await _tap(t, 'bp-search-retry');
      await t.pumpAndSettle();
      expect(api.gets.where((p) => p.startsWith('/blood-panel/donors')).length, before + 1);
    });

    testWidgets('B4 Me tab shows number visibility; turning it ON asks first', (t) async {
      _tall(t);
      final api = _Blood()..meOverride = {'phone_public': false};
      await t.pumpWidget(_app(const BloodHubScreen(initialTab: 2), api));
      await t.pumpAndSettle();
      await _tap(t, 'bp-me-phone');
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('bp-phone-confirm-body')), findsOneWidget);
      await _tap(t, 'bp-phone-keep-private');
      await t.pumpAndSettle();
      expect(api.posts.where((p) => p.$2.containsKey('phone_public')), isEmpty);
      await _tap(t, 'bp-me-phone');
      await t.pumpAndSettle();
      await _tap(t, 'bp-phone-confirm');
      await t.pumpAndSettle();
      expect(api.posts.last.$2, {'phone_public': true});
    });

    testWidgets('B4 setup: the phone switch needs the who-sees-it yes', (t) async {
      _tall(t);
      final cfg = fakeBloodGet('/blood-panel/config', bn: false, empty: false)!;
      await t.pumpWidget(_app(
          BloodDonorSetupScreen(initial: const {}, config: cfg), _Blood()));
      await t.pumpAndSettle();
      await _tap(t, 'bp-phone-public');
      await t.pumpAndSettle();
      await _tap(t, 'bp-phone-keep-private');
      await t.pumpAndSettle();
      expect(t.widget<SwitchListTile>(find.byKey(const ValueKey('bp-phone-public'))).value, isFalse);
    });

    testWidgets('B8 donated on another day sends that date', (t) async {
      _tall(t);
      final api = _Blood();
      await t.pumpWidget(_app(
          BloodHubScreen(initialTab: 2, pickDate: (_) async => DateTime(2026, 11, 14)), api));
      await t.pumpAndSettle();
      await _tap(t, 'bp-donated');
      await t.pumpAndSettle();
      await _tap(t, 'bp-donated-other');
      await t.pumpAndSettle();
      final p = api.posts.lastWhere((p) => p.$1 == '/blood-panel/me/donated');
      expect(p.$2, {'date': '2026-11-14'});
    });
  });
}
