// lpapp — owner 10 Nov 00:35 PART B: Language Partner ads for FREE users.
// Banner on home + lists; rewarded ad offer; interstitial only on LEAVING a
// result / lesson; NEVER during a timed mock, listening audio, speaking
// recording, the book-companion timer sheet or a certificate; Premium none;
// Quran stays fenced.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:assisto/ads/ad_banner_slot.dart';
import 'package:assisto/ads/ad_placements.dart';
import 'package:assisto/ads/ad_rules.dart';
import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/language_partner_screen.dart';
import 'package:assisto/screens/lp2/lp_companion.dart';
import 'package:assisto/screens/lp2/lp_data.dart';
import 'package:assisto/screens/lp2/lp_life.dart';
import 'package:assisto/screens/lp2/lp_mock.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';
import 'fake_lp2.dart';

Widget _app(Widget child, ApiClient api) {
  final s = AppState();
  s.api = api;
  s.locale = const Locale('en');
  s.loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: s,
    child: MaterialApp(
      locale: const Locale('en'),
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

final _adApi = RegExp(r'AdBannerSlot\(|AdExit\.|RewardedAdSheet|SponsoredPostSlot\(|maybeInterstitial|'
    r'showInterstitial|AdsService\.instance|LpAdExit\(');

/// Source of one class (from `class Name` to the next top-level `class `).
String _classSrc(String file, String name) {
  final s = File(file).readAsStringSync();
  final i = s.indexOf(RegExp('class $name\\b'));
  expect(i, greaterThanOrEqualTo(0), reason: '$name in $file');
  final j = s.indexOf(RegExp(r'\nclass |\n[A-Za-z].*\{\n'), i + 10);
  return s.substring(i, j < 0 ? s.length : j);
}

AdConfig _cfg({bool paid = false}) => AdConfig.fromJson({
      'plan': paid ? 'premium' : 'free',
      'paid': paid,
      'ads_enabled': !paid,
      'placements': {'banner': !paid},
      'banner_screens': paid ? <String>[] : AdPlacements.bannerScreens.toList(),
    });

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugLpAsset = (a) async => File(a).readAsString();
    debugLpPlay = (_) async {};
    LpContent.debugReset();
    lp2Posts.clear();
  });

  group('allowlist', () {
    test('Language Partner home + lists may carry a banner for Free users only', () {
      for (final s in ['lp_home', 'lp_hub', 'lp_life', 'lp_vocab']) {
        expect(AdPlacements.screenAllowed(AdSurface.banner, s), isTrue, reason: s);
        expect(AdPlacements.banner(s, _cfg(), loggedIn: true).allowed, isTrue, reason: s);
        expect(AdPlacements.banner(s, _cfg(paid: true), loggedIn: true).allowed, isFalse,
            reason: 'Premium never sees ads: $s');
      }
    });

    test('Quran / Quran Shikhi stay 100% ad-free', () {
      for (final s in ['quran', 'quran_learn', 'quran_shikhi']) {
        expect(AdRules.isBlockedScreen(s), isTrue, reason: s);
        for (final slot in AdSurface.values) {
          expect(AdPlacements.screenAllowed(slot, s), isFalse, reason: '$slot $s');
        }
      }
    });
  });

  group('never: timed mock, listening audio, speaking recording, book timer, certificate', () {
    test('no ad API inside the exam / audio / recording / timer code', () {
      const mock = 'lib/screens/lp2/lp_mock.dart';
      for (final c in ['_LpMockRunnerState', '_LrSectionState', '_LpAudioState', '_WritingSectionState',
        '_SpeakingSectionState', 'LpQuestion']) {
        expect(_adApi.hasMatch(_classSrc(mock, c)), isFalse, reason: c);
      }
      for (final c in ['LpTimer', '_LpTimerState', 'LpHoldToSpeak', '_LpHoldToSpeakState']) {
        expect(_adApi.hasMatch(_classSrc('lib/screens/lp2/lp_ui.dart', c)), isFalse, reason: c);
      }
      // the book companion runs the exam timer on the whole sheet: no ad at all
      expect(_adApi.hasMatch(File('lib/screens/lp2/lp_companion.dart').readAsStringSync()), isFalse);
      // the AI score screen records speaking answers: no ad there either
      expect(_adApi.hasMatch(_classSrc('lib/screens/lp2/lp_score.dart', '_LpAiScoreScreenState')), isFalse);
      // no app-side certificate screen exists; nothing in lp2 renders one with an ad
      for (final f in Directory('lib/screens/lp2').listSync().whereType<File>()) {
        final src = f.readAsStringSync();
        if (src.contains('certificate')) {
          expect(src.contains('AdBannerSlot('), isFalse, reason: f.path);
        }
      }
    });

    testWidgets('the running full mock shows no banner', (t) async {
      const mock = {'id': 'ac-001', 'kind': 'academic', 'title_en': 'Academic mock 1'};
      await t.pumpWidget(_app(const LpMockRunner(mock: mock, sections: kLpSections, full: true),
          FakeApi(mode: FakeMode.data, lang: 'en')));
      await t.pumpAndSettle();
      expect(find.byType(AdBannerSlot), findsNothing);
      expect(find.byType(LpAdExit), findsNothing);
    });

    testWidgets('role-play (speaking) and book companion show no banner', (t) async {
      await t.pumpWidget(_app(LpRolePlayScreen(scenario: lp2Scenario('bank')), FakeApi(mode: FakeMode.data, lang: 'en')));
      await t.pumpAndSettle();
      expect(find.byType(AdBannerSlot), findsNothing);
      await t.pumpWidget(_app(const LpCompanionScreen(key: ValueKey(2)), FakeApi(mode: FakeMode.data, lang: 'en')));
      await t.pumpAndSettle();
      expect(find.byType(AdBannerSlot), findsNothing);
    });
  });

  group('where ads may appear', () {
    testWidgets('home and lists carry exactly one banner slot', (t) async {
      for (final (w, key) in [
        (const LanguagePartnerScreen(), 'lp_home'),
        (const LpIeltsHub(), 'lp_hub'),
        (const LpLifeListScreen(), 'lp_life'),
      ]) {
        await t.pumpWidget(_app(KeyedSubtree(key: ValueKey(key), child: w), FakeApi(mode: FakeMode.data, lang: 'en')));
        await t.pumpAndSettle();
        expect(find.byType(AdBannerSlot), findsOneWidget, reason: key);
        expect(t.widget<AdBannerSlot>(find.byType(AdBannerSlot)).screen, key);
      }
    });

    testWidgets('a result screen only marks the task done; the ad can come on LEAVING it', (t) async {
      await t.pumpWidget(_app(
          const LpMockResultScreen(
              title: 'Academic mock 1', sections: ['reading'], bands: {'reading': 6.5}, overall: null),
          FakeApi(mode: FakeMode.data, lang: 'en')));
      await t.pumpAndSettle();
      expect(find.byType(LpAdExit), findsOneWidget);
      expect(find.byType(AdBannerSlot), findsNothing);
    });

    testWidgets('weekly slot used: rewarded ad offer + open with credits', (t) async {
      await t.pumpWidget(_app(Builder(builder: (c) => Scaffold(
          body: TextButton(
              onPressed: () => lpGateSheet(c, 'week_used', nextFreeAt: '2026-11-16', unlockCredits: 3),
              child: const Text('go')))), FakeApi(mode: FakeMode.data, lang: 'en')));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('lp2-rewarded')), findsOneWidget);
      expect(find.text('Open this section with 3 credits'), findsOneWidget);
    });
  });
}
