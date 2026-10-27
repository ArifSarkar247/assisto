// TRUTH — owner FINAL ORDER 27 Oct (top rule): "no demo or fake data
// anywhere, real licensed data sources, honest empty states, never promise
// what is not built."
//
// 1) GUARD: fails if known fake-data patterns come back into app/lib (curated
//    sample datasets, seeded demo rows, fixed mock ETAs, fake tracking ids /
//    payment links, the retired "AI-generated" labels on rule-based output,
//    "connect a key" dead ends shown to users). A hit is allowed only through
//    the explicit, shrinking allow-list below — prefer a real source or an
//    honest empty state.
// 2) Widget tests for the new honest states: Nearby (no location / real rows
//    with the source licence / source down / nothing nearby), onboarding
//    first win (business -> ledger, no OCR promise), Safe Journey with an
//    empty circle (add a family member, not a dead end), credit packs (never
//    expire). bn + en, Bangla digits, dark theme, TalkBack (labelled 48 dp
//    tap targets).
import 'dart:io';

import 'package:assisto/feature_flags.dart';
import 'package:assisto/feature_gates.dart';
import 'package:assisto/feature_registry.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/credits_screen.dart';
import 'package:assisto/screens/journey_start_screen.dart';
import 'package:assisto/screens/nearby_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/onb_first_win.dart';
import 'package:assisto/widgets/onb_role.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api.dart';

// --------------------------------------------------------------------------
// 1) static guard
// --------------------------------------------------------------------------

/// Pattern -> why it is fake. Matched against code lines (comments removed).
final _banned = <RegExp, String>{
  RegExp(r'\bkNearbyMock\b'): 'curated sample places (made-up phones/hours)',
  RegExp(r'\bseedIfFirstRun\b'): 'seeded demo "AI wants to remember" row',
  RegExp(r'\bkMockEtaMin\b'): 'fixed 25-minute "ETA" for every destination',
  RegExp(r'-MOCK-|MOCK-PAY-LINK|licensed-partner\.example'):
      'fake courier tracking id / payment link',
  RegExp(r'\bRideInAppComingNote\b|\brideFoodInAppComing\b'):
      '"in-app booking when a partner is connected" promise',
  // retired labels: rule-based / template output called "AI-generated"
  RegExp(r'\.(caMarker|ceMarker|paAiReviewMarker|socialAiMarker)\b'):
      'rule/template output labelled AI-generated',
  RegExp(r'\.(spendTitle|memConsentSample|mEtaMockNote|courierMockNote|'
      r'bAiPreview|nearbyMockBanner|onbWinBillSub|onbWinJourneySub|'
      r'creditsPackValidity)\b'): 'retired untrue copy',
  RegExp(r"'sample'\s*:\s*true|isSample\s*:\s*true"): 'a row flagged sample',
  RegExp(r'\+8801[0-9]00000+\b'): 'made-up phone number in data',
  RegExp(r'\bkSampleJobs\b|\bkSampleSource\b|\b_sampleWarnings\b'):
      'curated sample job openings / example disaster warnings',
  RegExp(r'\bRandom\(\s*\d*\s*\)\.next(Int|Double)\(.*(score|rating|price|eta)',
      caseSensitive: false): 'Random() used to fake a result',
};

/// file -> patterns it may still contain (with the reason). Shrink only.
const _allow = <String, Set<String>>{
  // kSampleJobs is behind kJobsFeedConnected=false (never rendered; the
  // gate is pinned below and in f6_showpieces_test). Delete with the source.
  'lib/screens/jobs_screen.dart': {'kSampleJobs', 'kSampleSource'},
  'lib/widgets/jobs_store.dart': {'kSampleJobs', 'kSampleSource'},
  // the example disaster cards are behind kShowSampleDisasterWarnings=false.
  'lib/screens/disaster_alerts_screen.dart': {'_sampleWarnings'},
};

Iterable<String> _code(File f) => f
    .readAsLinesSync()
    .map((l) => l.trimLeft().startsWith('//') || l.trimLeft().startsWith('///')
        ? ''
        : l.split(' //').first);

List<File> _dart() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart') && !f.path.contains('/l10n/'))
    .toList();

// --------------------------------------------------------------------------
// 2) widget helpers
// --------------------------------------------------------------------------

Widget _app(Widget child, {String lang = 'en', bool dark = false}) =>
    MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AssistoTheme.light,
      darkTheme: AssistoTheme.dark,
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      home: child,
    );

Future<AppLocalizations> _pump(WidgetTester tester, Widget screen,
    {String lang = 'en', bool dark = false, FakeMode mode = FakeMode.data}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
  final s = AppState()
    ..api = FakeApi(lang: lang, mode: mode)
    ..user = AppUser(
        id: 1,
        name: 'Me',
        phone: '01712345678',
        email: '',
        autonomyLevel: 2,
        language: lang)
    ..locale = Locale(lang)
    ..loading = false;
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: s, child: _app(screen, lang: lang, dark: dark)));
  await tester.pumpAndSettle();
  return AppLocalizations.of(tester.element(find.byWidget(screen)));
}

Future<void> _talkBack(WidgetTester tester) async {
  final h = tester.ensureSemantics();
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
  h.dispose();
}

const _here = (lat: 23.7380, lon: 90.3950);

void main() {
  group('guard: no fake-data patterns in app/lib', () {
    test('banned patterns only where allow-listed', () {
      final hits = <String>[];
      for (final f in _dart()) {
        final p = f.path.replaceAll(r'\', '/');
        var n = 0;
        for (final line in _code(f)) {
          n++;
          for (final e in _banned.entries) {
            if (!e.key.hasMatch(line)) continue;
            final ok = (_allow[p] ?? const {}).any(line.contains);
            if (!ok) hits.add('$p:$n  ${e.value}\n    ${line.trim()}');
          }
        }
      }
      expect(hits, isEmpty,
          reason: 'Fake / sample / untrue content is back (owner TRUTH rule). '
              'Use a real licensed source or an honest empty state:\n'
              '${hits.join('\n')}');
    });

    test('allow-list entries are still needed (it may only shrink)', () {
      for (final p in _allow.keys) {
        expect(File(p).existsSync(), isTrue, reason: '$p is gone — drop it');
      }
    });

    test('"connect a key in Integrations" dead ends stay hidden for users', () {
      expect(kShowKeySeams, isFalse);
    });

    test('features without their data source are hidden on a first run', () {
      expect(kFeatureNeedsSource, containsAll(['dictionary', 'ai_inbox']));
      final ff = FeatureFlags.instance..resetForTest();
      expect(ff.isOn('dictionary'), isFalse);
      expect(ff.isOn('ai_inbox'), isFalse);
      // a server answer that has the source turns it back on
      ff.applyForTest({
        'features': {'dictionary': true},
        'preview': const []
      });
      expect(ff.isOn('dictionary'), isTrue);
      ff.resetForTest();
    });

    test('the sample job feed and example disaster cards stay gated', () {
      expect(kJobsFeedConnected, isFalse);
      expect(kShowSampleDisasterWarnings, isFalse);
    });
  });

  group('Nearby: real places only', () {
    for (final lang in ['en', 'bn']) {
      for (final dark in [false, true]) {
        testWidgets('no location -> honest state, no rows ($lang, dark=$dark)',
            (tester) async {
          final t = await _pump(
              tester, const NearbyScreen(debugLocationDenied: true),
              lang: lang, dark: dark);
          expect(find.byKey(const ValueKey('truth_nearby_no_location')),
              findsOneWidget);
          expect(find.text(t.truthNearbyNeedLocation), findsOneWidget);
          expect(find.text('Dhaka Medical College Hospital'), findsNothing);
          await _talkBack(tester);
        });

        testWidgets('live rows + licence line ($lang, dark=$dark)',
            (tester) async {
          final t = await _pump(
              tester, const NearbyScreen(debugLocation: _here),
              lang: lang, dark: dark);
          expect(find.text('Dhaka Medical College Hospital'), findsOneWidget);
          expect(find.byKey(const ValueKey('truth_nearby_attribution')),
              findsOneWidget);
          expect(find.textContaining('OpenStreetMap'), findsOneWidget);
          expect(find.text(t.nearbyMockBanner), findsNothing);
          if (lang == 'bn') {
            // distance in Bangla digits, no ASCII digits in the chip
            expect(find.textContaining(RegExp('[০-৯]')), findsWidgets);
          }
          await _talkBack(tester);
        });
      }
    }

    testWidgets('source down -> honest error with retry', (tester) async {
      final t = await _pump(tester, const NearbyScreen(debugLocation: _here),
          mode: FakeMode.fail);
      expect(find.byKey(const ValueKey('truth_nearby_error')), findsOneWidget);
      expect(find.text(t.truthNearbyLoadFailed), findsOneWidget);
      expect(find.text(t.retry), findsOneWidget);
    });

    testWidgets('nothing nearby -> honest empty, no sample', (tester) async {
      final t = await _pump(tester, const NearbyScreen(debugLocation: _here),
          mode: FakeMode.empty);
      expect(find.text(t.truthNearbyNoneNearby), findsOneWidget);
      expect(find.byKey(const ValueKey('truth_nearby_attribution')),
          findsNothing);
    });
  });

  group('onboarding first win matches what is built', () {
    for (final lang in ['en', 'bn']) {
      testWidgets('business -> ledger first, recommended ($lang)',
          (tester) async {
        OnbWin? picked;
        final w = OnbFirstWin(
            role: OnbRole.business, onPick: (x) => picked = x);
        final t = await _pump(tester, Scaffold(body: w), lang: lang);
        expect(find.text(t.truthOnbWinLedgerTitle), findsOneWidget);
        expect(find.text(t.onbRecommendedForYou), findsOneWidget);
        // the ledger tile is the first tile
        final ledgerY = tester.getTopLeft(find.text(t.truthOnbWinLedgerTitle)).dy;
        final billY = tester.getTopLeft(find.text(t.truthOnbWinBillTitle)).dy;
        expect(ledgerY, lessThan(billY));
        // no OCR promise anywhere
        expect(find.text(t.onbWinBillSub), findsNothing);
        await tester.tap(find.text(t.truthOnbWinLedgerTitle));
        expect(picked, OnbWin.ledger);
        await _talkBack(tester);
      });
    }

    testWidgets('self -> journey with honest watcher text, no ledger tile',
        (tester) async {
      final t = await _pump(tester,
          Scaffold(body: OnbFirstWin(role: OnbRole.self, onPick: (_) {})));
      expect(find.text(t.truthOnbWinJourneySub), findsOneWidget);
      expect(find.text(t.onbWinJourneySub), findsNothing);
      expect(find.text(t.truthOnbWinLedgerTitle), findsNothing);
    });
  });

  group('Safe Journey: empty circle is not a dead end', () {
    for (final lang in ['en', 'bn']) {
      testWidgets('add-a-family-member button ($lang, dark)', (tester) async {
        final t = await _pump(tester, const JourneyStartScreen(),
            lang: lang, dark: true, mode: FakeMode.empty);
        expect(find.text(t.journeyNoWatchers), findsOneWidget);
        expect(find.byKey(const ValueKey('truth_journey_add_watcher')),
            findsOneWidget);
        expect(find.text(t.truthJourneyAddFamily), findsOneWidget);
      });
    }

    testWidgets('with a circle member the button is not shown', (tester) async {
      await _pump(tester, const JourneyStartScreen());
      expect(find.byKey(const ValueKey('truth_journey_add_watcher')),
          findsNothing);
    });
  });

  group('credits wording follows the code (packs never expire)', () {
    tearDown(() => FakeApi.payLive = false);
    for (final lang in ['en', 'bn']) {
      testWidgets('pack rows say never expires ($lang)', (tester) async {
        FakeApi.payLive = true;
        final t = await _pump(tester, const CreditsScreen(), lang: lang);
        expect(find.text(t.truthPackNeverExpires), findsWidgets);
        expect(find.textContaining(lang == 'bn' ? 'মাস মেয়াদ' : 'Valid 12'),
            findsNothing);
      });
    }
  });
}
