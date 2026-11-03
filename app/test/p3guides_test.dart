// p3guides (owner PART 3): Service guide official facts + ticked documents,
// Probashi Help (helplines, real remittance cost, SOS abroad, offline cache),
// Student study timer + official dates (save a deadline into the Tracker).
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/feature_flags.dart' show FeatureFlags;
import 'package:assisto/feature_registry.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/probashi/probashi_help_tab.dart';
import 'package:assisto/screens/student/student_official_tab.dart';
import 'package:assisto/screens/student/study_timer_tab.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/guide_data.dart';
import 'package:assisto/widgets/guide_service_card.dart';
import 'package:assisto/widgets/official_info_cache.dart';

import 'fake_api.dart';
import 'p3guides_fake.dart';

AppState _app(String lang, FakeMode mode) {
  final s = AppState();
  s.api = FakeApi(mode: mode, lang: lang);
  s.user = AppUser(
      id: 1, name: 'R', phone: '01700000000', email: '',
      autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return s;
}

Widget _wrap(Widget home, {String lang = 'en', FakeMode mode = FakeMode.data, double scale = 1.0}) =>
    ChangeNotifierProvider<AppState>.value(
      value: _app(lang, mode),
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
            child: child!),
        home: Scaffold(body: home),
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

final _ascii = RegExp(r'[0-9]');

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Settings.resetForTest();
    FeatureFlags.instance.resetForTest();
  });

  group('pure', () {
    test('real remittance cost = fee + FX margin (World Bank method)', () {
      final r = p3gRemitCost(500, 15, 32.10, 32.50)!;
      expect(r.costPct, closeTo(4.23, 0.01));
      expect(r.homeAmount, 16050);
      expect(r.incentive, closeTo(401.25, 0.001));
      expect(r.aboveSdg, isTrue);
      expect(p3gRemitCost(1000, 0, 32.45, 32.50)!.aboveSdg, isFalse);
      expect(p3gRemitCost(0, 1, 1, 1), isNull);
      expect(p3gRemitCost(100, -1, 1, 1), isNull);
      expect(p3gRemitCost(null, 1, 1, 1), isNull);
    });

    test('numbers typed with Bangla digits parse', () {
      expect(p3gParse('৩২.৫০'), 32.5);
      expect(p3gParse('1,000'), 1000);
      expect(p3gParse('abc'), isNull);
    });

    test('study totals: today + last 7 days', () {
      final now = DateTime(2026, 11, 3, 10);
      final t = studyTotals({'2026-11-03': 25, '2026-10-30': 50, '2026-10-20': 99}, now);
      expect(t.today, 25);
      expect(t.week, 75);
      expect(studyClock(25 * 60), '25:00');
      expect(studyClock(-3), '00:00');
    });

    test('date shown day first', () => expect(p3gDate('2026-11-03'), '03/11/2026'));

    test('official facts survive the offline cache round-trip', () {
      final s = GuideService.fromJson(p3gFakeEmutation(true));
      expect(s.official.published, isTrue);
      expect(s.official.fees.last.amount, '৳১,১৭০');
      final back = GuideService.fromJson(s.toJson());
      expect(back.official.checked, '2026-11-03');
      expect(back.official.sources.single.url, 'https://mutation.land.gov.bd');
      // an old cached payload without the block stays honest (no facts)
      expect(GuideService.fromJson({'name': 'x'}).official.isEmpty, isTrue);
    });

    test('flag official_corners is registered OFF', () {
      expect(kFeatureDefaults['official_corners'], isFalse);
      expect(FeatureFlags.instance.isOn('official_corners'), isFalse);
    });
  });

  group('service guide card', () {
    testWidgets('published fee table, sources, last checked; ticks call back', (tester) async {
      final ticked = <int>[];
      final opened = <String>[];
      await tester.pumpWidget(_wrap(
        ListView(children: [
          GuideServiceCard(
            service: GuideService.fromJson(p3gFakeEmutation(false)),
            bookmarked: false,
            onToggleBookmark: () {},
            onOpenLink: opened.add,
            onWhatDoINeed: () {},
            initiallyExpanded: true,
            checkedDocs: const {1},
            onToggleDoc: ticked.add,
          ),
        ]),
      ));
      await _settle(tester);
      expect(find.byKey(const ValueKey('p3g-official')), findsOneWidget);
      expect(find.text('Tk 1,170'), findsOneWidget);
      expect(find.text('1 of 3 ready — tick what you have (saved on this phone)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('p3g-doc-emutation-0')));
      expect(ticked, [0]);
      await tester.ensureVisible(find.byKey(const ValueKey('p3g-fee-page')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('p3g-fee-page')));
      expect(opened, ['https://mutation.land.gov.bd']);
      expect(find.text('Last checked by Assisto: 03/11/2026'), findsOneWidget);
    });

    testWidgets('no number when only the official page is known', (tester) async {
      final j = p3gFakeEmutation(false);
      j['official'] = {'checked': '2026-11-03', 'fee_status': 'official_page',
        'fee_page': 'https://www.epassport.gov.bd/instructions/passport-fees', 'fees': [], 'sources': []};
      await tester.pumpWidget(_wrap(ListView(children: [
        GuideServiceCard(
          service: GuideService.fromJson(j),
          bookmarked: false, onToggleBookmark: () {}, onOpenLink: (_) {},
          onWhatDoINeed: () {}, initiallyExpanded: true),
      ])));
      await _settle(tester);
      expect(find.text('Tk 20'), findsNothing);
      expect(find.byKey(const ValueKey('p3g-fee-page')), findsOneWidget);
    });
  });

  group('probashi help', () {
    testWidgets('helplines, real cost check, Bangla digits in bn', (tester) async {
      await tester.pumpWidget(_wrap(const ProbashiHelpTab(), lang: 'bn'));
      await _settle(tester);
      expect(find.text('১৬১৩৫'), findsOneWidget);
      expect(find.byKey(const ValueKey('p3g-sos')), findsOneWidget);
      for (final e in const {
        'p3g-amount': '৫০০',
        'p3g-fee': '15',
        'p3g-rate-got': '32.10',
        'p3g-rate-ref': '32.50',
      }.entries) {
        final f = find.descendant(
            of: find.byKey(ValueKey(e.key)), matching: find.byType(TextField));
        await tester.ensureVisible(f);
        await tester.pump();
        await tester.enterText(f, e.value);
        await tester.pump();
      }
      final check = find.byKey(const ValueKey('p3g-check'));
      await tester.ensureVisible(check);
      await tester.pump();
      tester.widget<FilledButton>(check).onPressed!();
      await _settle(tester);
      expect(find.byKey(const ValueKey('p3g-result'), skipOffstage: false), findsOneWidget);
      final res = tester.widget<Text>(find.byKey(const ValueKey('p3g-result'), skipOffstage: false)).data!;
      expect(res.contains('৪.২৩'), isTrue, reason: res);
      expect(_ascii.hasMatch(res), isFalse);
    });

    test('offline after one load: served from the phone', () async {
      final api = FakeApi(mode: FakeMode.data, lang: 'en');
      await loadOfficialInfo(api, 'probashi', 'en');
      final off = await loadOfficialInfo(FakeApi(mode: FakeMode.fail, lang: 'en'), 'probashi', 'en');
      expect(off.fromCache, isTrue);
      expect((off.data!['helplines'] as List).first['dial'], '16135');
    });

    testWidgets('first run offline: honest state + SOS still there', (tester) async {
      await tester.pumpWidget(_wrap(const ProbashiHelpTab(), mode: FakeMode.fail));
      await _settle(tester);
      expect(find.byKey(const ValueKey('p3g-sos')), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('200% font at 360dp: no overflow', (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_wrap(const ProbashiHelpTab(), lang: 'bn', scale: 2.0));
      await _settle(tester);
      expect(tester.takeException(), isNull);
    });
  });

  group('student', () {
    testWidgets('timer starts, stop banks the minutes', (tester) async {
      var now = DateTime(2026, 11, 3, 9);
      await tester.pumpWidget(_wrap(StudyTimerTab(now: () => now)));
      await _settle(tester);
      expect(find.text('25:00'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('p3g-start')));
      await tester.pump();
      now = now.add(const Duration(minutes: 7, seconds: 5));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('17:55'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('p3g-stop')));
      await tester.pump();
      expect(find.text('Today: 7 min studied'), findsOneWidget);
      await tester.pumpWidget(const SizedBox()); // dispose: timer cancelled
    });

    testWidgets('official dates list + save a deadline into the Tracker', (tester) async {
      var saved = 0;
      await tester.pumpWidget(_wrap(StudentOfficialTab(onSaved: () => saved++)));
      await _settle(tester);
      expect(find.text('GST cluster admission'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('p3g-save-deadline')));
      await _settle(tester);
      // empty -> honest message, nothing saved
      await tester.tap(find.byKey(const ValueKey('p3g-deadline-save')));
      await _settle(tester);
      expect(saved, 0);
      expect(find.text('Please enter a name'), findsOneWidget);
    });
  });
}
