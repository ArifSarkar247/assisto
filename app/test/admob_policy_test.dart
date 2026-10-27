// admob (owner 25 Oct): the ad POLICY — Free vs Premium/Business, the
// central screen allowlist, app-open suppression sources (first launch,
// after login, notification / SOS / safety alert / call / alarm / reminder /
// widget / deep link, short background, forbidden screen), caps and
// intervals, config parsing (Google TEST ids by default), the home native
// card ("Ad" / "বিজ্ঞাপন" label, below the shortcuts) and NO ad widget on
// forbidden screens.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/ads/ad_banner_slot.dart';
import 'package:assisto/ads/ad_placements.dart';
import 'package:assisto/ads/ad_rules.dart';
import 'package:assisto/ads/ad_telemetry.dart';
import 'package:assisto/ads/ads_bridge.dart';
import 'package:assisto/ads/ads_service.dart';
import 'package:assisto/ads/app_open_gate.dart';
import 'package:assisto/ads/consent.dart';
import 'package:assisto/ads/hero_ad.dart';
import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/home_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/updater.dart';
import 'package:assisto/widgets/home_hero.dart';
import 'package:assisto/widgets/home_quick_buttons.dart';

import 'fake_api.dart';
import 'h1_home_fakes.dart';
import 'p2_fakes.dart';

/// What the server sends a Free user by default (core/logic/ads.py).
Map<String, dynamic> serverCfg({
  String plan = 'free',
  bool real = false,
  // banners-everywhere (owner 26 Oct): the server default = the app list
  List<String>? banner,
  List<String> moments = const ['photo_saved', 'task_done'],
  int appOpenCap = 6,
  int interCap = 6,
}) {
  final paid = plan != 'free';
  return {
    'configured': real,
    'real_ids': real,
    'ads_enabled': !paid,
    'app_id': real ? AdIds.ownerAppId : '',
    'units': real
        ? {
            'app_open': 'ca-app-pub-2506398550427515/1193237050',
            'rewarded': 'ca-app-pub-2506398550427515/2426427676',
            'banner': 'ca-app-pub-2506398550427515/4940910375',
            'interstitial': 'ca-app-pub-2506398550427515/3547937658',
            'native': 'ca-app-pub-2506398550427515/7259951959',
          }
        : {
            'app_open': AdIds.testAppOpen,
            'rewarded': AdIds.testRewarded,
            'banner': AdIds.testBanner,
            'interstitial': AdIds.testInterstitial,
            'native': AdIds.testNative,
          },
    'plan': plan,
    'paid': paid,
    'placements': {
      'app_open': !paid,
      'native_home': !paid,
      'banner': !paid,
      'interstitial': !paid,
      'rewarded': !paid && real,
    },
    'app_open_enabled': !paid,
    'rewarded_enabled': !paid && real,
    'appopen_min_gap_sec': 10800,
    'appopen_daily_cap': appOpenCap,
    'appopen_min_bg_sec': 30,
    'interstitial_min_gap_sec': 300,
    'interstitial_daily_cap': interCap,
    'banner_screens': paid ? <String>[] : (banner ?? AdPlacements.bannerScreens.toList()),
    'interstitial_moments': paid ? <String>[] : moments,
    'hero_enabled': !paid,
    'hero_start_muted': true,
    'hero_refresh_sec': 90,
    'appopen_start_day': 2,
    'sponsors_enabled': !paid,
  };
}

AdConfig cfg({String plan = 'free', bool real = false}) =>
    AdConfig.fromJson(serverCfg(plan: plan, real: real));

void main() {
  group('app-open never during a call (owner 26 Oct)', () {
    test('an ongoing call (even minimised) blocks the app-open ad', () {
      final d = AppOpenGuard.check(
          firstLaunchEver: false,
          sessionAfterLogin: false,
          suppressed: false,
          screen: 'home',
          resumed: false,
          callActive: true);
      expect(d.allowed, isFalse);
      expect(d.reason, 'in_call');
    });
    test('first launch ever never shows one', () {
      expect(
          AppOpenGuard.check(
                  firstLaunchEver: true,
                  sessionAfterLogin: false,
                  suppressed: false,
                  screen: 'home',
                  resumed: false)
              .reason,
          'first_launch');
    });
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppEntry.reset();
    AdsService.instance.resetForTest();
    AdConsent.instance.resetForTest();
    HomeHero.debugReset();
    AdBannerSlot.debugBridge = null;
    AdBannerSlot.debugLoadConfig = null;
    BannerPacer.resetForTest();
  });

  // ------------------------------------------------------------- config
  group('config parsing', () {
    test('default = Google TEST unit ids for every format', () {
      final c = cfg();
      expect(c.configured, isFalse);
      expect(c.adsEnabled, isTrue);
      for (final k in AdKind.values) {
        expect(c.unitFor(k, builtAppId: AdsService.builtAppId), AdIds.testUnit(k), reason: '$k');
      }
      expect(c.appOpenMinGap, const Duration(hours: 3));
      expect(c.appOpenDailyCap, 6);
      expect(c.interstitialMinGap, const Duration(minutes: 5));
      expect(c.bannerScreens, AdPlacements.bannerScreens);
      expect(c.rewardedEnabled, isFalse, reason: 'SSV cannot verify test units');
      expect(c.personalized, isFalse);
    });

    test('the APK carries the owner AdMob app id; test units are public', () {
      expect(AdsService.builtAppId, 'ca-app-pub-2506398550427515~5116255919');
      expect(AdIds.testBanner, 'ca-app-pub-3940256099942544/6300978111');
      expect(AdIds.testInterstitial, 'ca-app-pub-3940256099942544/1033173712');
      expect(AdIds.testAppOpen, 'ca-app-pub-3940256099942544/9257395921');
      expect(AdIds.testRewarded, 'ca-app-pub-3940256099942544/5224354917');
      expect(AdIds.testNative, 'ca-app-pub-3940256099942544/2247696110');
    });

    test('real ids only when the server flag is on AND the app id matches', () {
      final c = cfg(real: true);
      expect(c.unitFor(AdKind.banner, builtAppId: AdIds.ownerAppId),
          'ca-app-pub-2506398550427515/4940910375');
      expect(c.unitFor(AdKind.native, builtAppId: AdIds.ownerAppId),
          'ca-app-pub-2506398550427515/7259951959');
      // another APK (different AdMob app) -> never the real unit
      expect(c.unitFor(AdKind.banner, builtAppId: AdIds.testAppId), AdIds.testBanner);
    });

    test('garbage / empty config -> no ads', () {
      expect(AdConfig.fromJson(null).adsEnabled, isFalse);
      final c = AdConfig.fromJson({'plan': 'free'});
      expect(c.bannerEnabled, isFalse);
      expect(c.interstitialEnabled, isFalse);
      expect(c.appOpenEnabled, isFalse);
    });
  });

  // ------------------------------------------------------------- plans
  group('Free only', () {
    for (final plan in ['premium', 'business']) {
      test('$plan sees zero ads', () {
        final c = cfg(plan: plan, real: true);
        expect(c.paid, isTrue);
        expect(c.adsEnabled, isFalse);
        expect(AdPlacements.banner('dictionary', c, loggedIn: true).allowed, isFalse);
        expect(
            AdPlacements.interstitial('task_done', c, loggedIn: true, now: DateTime(2026))
                .allowed,
            isFalse);
        for (final k in [AdKind.appOpen, AdKind.rewarded]) {
          final d = AdRules.decide(
              kind: k,
              screen: k == AdKind.appOpen ? 'home' : 'credits',
              config: c,
              now: DateTime(2026),
              loggedIn: true,
              userOptedIn: true);
          expect(d.reason, 'paid_plan', reason: '$k');
        }
        expect(HeroAdConfig.fromJson(serverCfg(plan: plan)).enabled, isFalse);
        expect(
            AppOpenGate.decide(
                    loggedIn: true,
                    paid: true,
                    enabled: true,
                    screen: 'home',
                    entry: '',
                    now: DateTime(2026))
                .reason,
            'paid_plan');
      });
    }

    test('a paid plan is never trusted to the server alone', () {
      final j = serverCfg()..['plan'] = 'business';
      expect(AdConfig.fromJson(j).adsEnabled, isFalse);
    });
  });

  // ------------------------------------------------------------- allowlist
  group('central allowlist (default-deny)', () {
    test('banner only on the listed normal feature screens', () {
      final c = cfg();
      // banners-everywhere (owner 26 Oct): every listed screen, nothing else
      for (final s in AdPlacements.bannerScreens) {
        expect(AdPlacements.banner(s, c, loggedIn: true).allowed, isTrue, reason: s);
      }
      for (final s in ['home', 'brand_new_screen', 'circle_chat', '', 'unknown']) {
        expect(AdPlacements.banner(s, c, loggedIn: true).allowed, isFalse, reason: s);
      }
      expect(AdPlacements.banner('dictionary', c, loggedIn: false).allowed, isFalse);
    });

    test('NEVER on SOS, safety, anti-theft, alerts, calls, chats, chat lock, '
        'payment, login, onboarding or permission screens', () {
      for (final s in AdPlacements.neverScreens) {
        for (final slot in AdSurface.values) {
          expect(AdPlacements.screenAllowed(slot, s), isFalse, reason: '$slot on $s');
        }
        expect(AdRules.isBlockedScreen(s), isTrue, reason: s);
      }
    });

    test('even a listed name with a forbidden token is refused', () {
      for (final s in ['sos_tips', 'chat_dictionary', 'payment_saved_items']) {
        expect(AdPlacements.screenAllowed(AdSurface.banner, s), isFalse, reason: s);
      }
    });

    test('the server can switch a page off but never add one', () {
      final c = AdConfig.fromJson(serverCfg(banner: ['dictionary', 'sos', 'circle_chat']));
      expect(AdPlacements.banner('dictionary', c, loggedIn: true).allowed, isTrue);
      expect(AdPlacements.banner('saved_items', c, loggedIn: true).reason, 'server_off');
      expect(AdPlacements.banner('sos', c, loggedIn: true).allowed, isFalse);
      expect(AdPlacements.banner('circle_chat', c, loggedIn: true).allowed, isFalse);
    });

    test('native card: home only; app-open: home only', () {
      expect(AdPlacements.screenAllowed(AdSurface.homeNative, 'home'), isTrue);
      expect(AdPlacements.screenAllowed(AdSurface.appOpen, 'home'), isTrue);
      expect(AdPlacements.screenAllowed(AdSurface.homeNative, 'dictionary'), isFalse);
      expect(AdPlacements.screenAllowed(AdSurface.appOpen, 'onboarding'), isFalse);
      // one persistent ad per screen: no banner page also hosts the native
      // card (banners-everywhere: interstitials are full-screen moments
      // after a finished action, see ad_banners_everywhere_test.dart)
      expect(AdPlacements.bannerScreens.intersection(AdPlacements.nativeScreens),
          isEmpty);
      expect(AdPlacements.bannerScreens.contains('home'), isFalse);
    });
  });

  // ------------------------------------------------------------- app-open
  group('app-open suppression', () {
    AdDecision g({
      bool first = false,
      bool afterLogin = false,
      bool suppressed = false,
      String screen = 'home',
      bool resumed = true,
      Duration? bg = const Duration(minutes: 10),
    }) =>
        AppOpenGuard.check(
            firstLaunchEver: first,
            sessionAfterLogin: afterLogin,
            suppressed: suppressed,
            screen: screen,
            resumed: resumed,
            backgroundFor: bg);

    test('allowed on a normal return to home', () {
      expect(g().allowed, isTrue);
      expect(g(resumed: false, bg: null).allowed, isTrue); // cold start, day 2+
    });

    test('never on the first launch ever / right after login', () {
      expect(g(first: true).reason, 'first_launch');
      expect(g(afterLogin: true).reason, 'after_login');
    });

    test('never after a quick app switch', () {
      expect(g(bg: const Duration(seconds: 3)).reason, 'short_background');
      expect(g(bg: null).reason, 'short_background');
    });

    test('never over a forbidden / pushed screen', () {
      for (final s in ['unknown', 'login', 'onboarding', 'circle_call', 'sos',
          'deletion_grace', 'language_picker', 'elderly_home']) {
        expect(g(screen: s).allowed, isFalse, reason: s);
      }
    });

    test('every external entry suppresses the NEXT app-open, once', () {
      for (final kind in ['notification', 'sos', 'safety_alert', 'call', 'alarm',
          'reminder', 'widget', 'deeplink', 'assist', 'native_launch']) {
        AppEntry.reset();
        AppEntry.mark(kind);
        expect(AppEntry.blocked(), isTrue, reason: kind);
        expect(AppEntry.consumeSuppression(), isTrue, reason: kind);
        expect(AppEntry.consumeSuppression(), isFalse, reason: '$kind cleared');
        // even long after the 20 s window, a pending suppression still holds
        AppEntry.mark(kind, now: DateTime.now().subtract(const Duration(minutes: 5)));
        expect(AppEntry.blocked(), isFalse);
        expect(AppEntry.consumeSuppression(), isTrue, reason: '$kind late');
      }
      AppEntry.mark('cold_start');
      expect(AppEntry.consumeSuppression(), isFalse);
    });

    test('caps: once every 3 hours, max 6 a day', () {
      final c = cfg();
      final now = DateTime(2026, 10, 25, 12);
      AdDecision d({DateTime? last, int today = 0}) => AdRules.decide(
          kind: AdKind.appOpen,
          screen: 'home',
          config: c,
          now: now,
          loggedIn: true,
          lastAppOpenAt: last,
          appOpensToday: today);
      expect(d().allowed, isTrue);
      expect(d(last: now.subtract(const Duration(minutes: 179))).reason, 'too_soon');
      expect(d(last: now.subtract(const Duration(minutes: 181))).allowed, isTrue);
      expect(d(today: 5).allowed, isTrue);
      expect(d(today: 6).reason, 'daily_cap');
      // a server gap below 3 h is never honoured
      final fast = AdConfig.fromJson(serverCfg()..['appopen_min_gap_sec'] = 60);
      expect(
          AdRules.decide(
                  kind: AdKind.appOpen,
                  screen: 'home',
                  config: fast,
                  now: now,
                  loggedIn: true,
                  lastAppOpenAt: now.subtract(const Duration(minutes: 30)))
              .reason,
          'too_soon');
    });

    testWidgets('service: first launch and after-login sessions show nothing',
        (tester) async {
      final api = _AdsApi(serverCfg());
      final app = _app(api);
      final ads = _FakeFullScreen();
      AdsService.instance.bridge = ads;
      AdsService.instance.debugNativeSuppressed = () async => false;
      AdsService.instance.attachForTest(app, firstLaunch: true);
      await AdsService.instance
          .maybeShowAppOpen(resumed: true, backgroundFor: const Duration(minutes: 5));
      AdsService.instance.attachForTest(app, afterLogin: true);
      await AdsService.instance
          .maybeShowAppOpen(resumed: true, backgroundFor: const Duration(minutes: 5));
      // the native launch-source flag (notification / call / widget / link)
      AdsService.instance.attachForTest(app);
      AdsService.instance.debugNativeSuppressed = () async => true;
      await AdsService.instance
          .maybeShowAppOpen(resumed: true, backgroundFor: const Duration(minutes: 5));
      expect(ads.appOpens, 0);
      expect(api.paths.where((p) => p.startsWith('/ads/slot')), isEmpty);
    });
  });

  // ------------------------------------------------------------- interstitial
  group('interstitial at natural breaks', () {
    test('moments, 5-minute gap, daily cap', () {
      final c = cfg();
      final now = DateTime(2026, 10, 25, 12);
      AdDecision d(String m, {DateTime? last, int today = 0}) =>
          AdPlacements.interstitial(m, c,
              loggedIn: true, now: now, lastFullScreenAt: last, shownToday: today);
      expect(d('photo_saved').allowed, isTrue);
      expect(d('task_done').allowed, isTrue);
      expect(d('screen_open').reason, 'moment_not_allowed');
      expect(d('sos_sent').reason, 'moment_not_allowed');
      expect(d('task_done', last: now.subtract(const Duration(minutes: 4))).reason,
          'too_soon');
      expect(d('task_done', last: now.subtract(const Duration(minutes: 6))).allowed, isTrue);
      expect(d('task_done', today: 6).reason, 'daily_cap');
    });

    testWidgets('service shows one, then respects the gap; reports to /ads/event',
        (tester) async {
      final api = _AdsApi(serverCfg());
      final inter = _FakeFullScreen();
      AdsService.instance.interstitials = inter;
      AdsService.instance.attachForTest(_app(api));
      expect(await AdsService.instance.maybeInterstitial('task_done'), isTrue);
      expect(await AdsService.instance.maybeInterstitial('photo_saved'), isFalse);
      expect(inter.interstitials, ['interstitial_task_done']);
      AdTelemetry.paid('interstitial_task_done', 'interstitial',
          valueMicros: 1234, currency: 'usd', precision: 'precise');
      await tester.pump();
      final paid = api.posts.firstWhere((b) => b['kind'] == 'paid');
      expect(paid['placement'], 'interstitial_task_done');
      expect(paid['value_micros'], 1234);
      expect(paid['currency'], 'USD');
    });

    testWidgets('premium: no interstitial, no config-based ad at all', (tester) async {
      final inter = _FakeFullScreen();
      AdsService.instance.interstitials = inter;
      AdsService.instance.attachForTest(_app(_AdsApi(serverCfg(plan: 'premium'))));
      expect(await AdsService.instance.maybeInterstitial('task_done'), isFalse);
      expect(inter.interstitials, isEmpty);
    });
  });

  // ------------------------------------------------------------- widgets
  group('banner slot', () {
    testWidgets('allowed page + Free: banner with the "Ad" label (en)', (tester) async {
      final b = _FakeBanner();
      await tester.pumpWidget(_wrap(
          AdBannerSlot(screen: 'dictionary', bridge: b, loadConfig: () async => cfg()),
          lang: 'en'));
      await _settle(tester);
      expect(find.byKey(const ValueKey('fake-banner')), findsOneWidget);
      expect(find.text('Ad'), findsOneWidget);
      expect(b.placements, ['banner_dictionary']);
    });

    testWidgets('Bangla label', (tester) async {
      await tester.pumpWidget(_wrap(
          AdBannerSlot(screen: 'saved_items', bridge: _FakeBanner(), loadConfig: () async => cfg()),
          lang: 'bn'));
      await _settle(tester);
      expect(find.text('বিজ্ঞাপন'), findsOneWidget);
    });

    testWidgets('forbidden screens / premium: nothing is even loaded', (tester) async {
      for (final s in ['sos', 'circle_call', 'circle_chat', 'login', 'payment',
          'onboarding', 'permission', 'antitheft']) {
        final b = _FakeBanner();
        await tester.pumpWidget(_wrap(
            AdBannerSlot(key: ValueKey(s), screen: s, bridge: b, loadConfig: () async => cfg()),
            lang: 'en'));
        await _settle(tester);
        expect(b.loads, 0, reason: s);
        expect(find.byKey(const ValueKey('ad-banner-slot')), findsNothing, reason: s);
      }
      final b = _FakeBanner();
      await tester.pumpWidget(_wrap(
          AdBannerSlot(
              screen: 'dictionary', bridge: b, loadConfig: () async => cfg(plan: 'business')),
          lang: 'en'));
      await _settle(tester);
      expect(b.loads, 0);
    });

    testWidgets('no fill -> takes no space', (tester) async {
      await tester.pumpWidget(_wrap(
          AdBannerSlot(
              screen: 'dictionary',
              bridge: _FakeBanner(fill: false),
              loadConfig: () async => cfg()),
          lang: 'en'));
      await _settle(tester);
      expect(tester.getSize(find.byType(AdBannerSlot)).height, 0);
    });
  });

  group('home native card', () {
    for (final lang in ['en', 'bn']) {
      testWidgets('Free: native card with the "Ad" label ($lang), BELOW the shortcuts',
          (tester) async {
        HomeHero.debugBridge = FakeHeroBridge();
        HomeHero.debugLoadConfig = () async => serverCfg();
        HomeHero.debugSponsor = FakeSponsorBackend(
            slotJson: {'show': true, 'source': 'admob', 'placement': 'hero'});
        await tester.binding.setSurfaceSize(const Size(412, 915));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(_home(lang));
        await _settle(tester);
        final label = find.text(lang == 'en' ? 'Ad' : 'বিজ্ঞাপন');
        expect(label, findsOneWidget);
        expect(find.byKey(const ValueKey('fake-native-ad')), findsOneWidget);
        final shortcuts = find.byType(HomeQuickBar);
        expect(shortcuts, findsWidgets);
        final shortcutsBottom = tester.getBottomLeft(shortcuts.first).dy;
        expect(tester.getTopLeft(label).dy, greaterThanOrEqualTo(shortcutsBottom),
            reason: 'the ad never sits between the app bar and the shortcuts');
      });
    }

    testWidgets('Premium: no native card', (tester) async {
      final b = FakeHeroBridge();
      HomeHero.debugBridge = b;
      HomeHero.debugLoadConfig = () async => serverCfg(plan: 'premium');
      HomeHero.debugSponsor = FakeSponsorBackend(slotJson: {'show': false});
      await tester.binding.setSurfaceSize(const Size(412, 915));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_home('en'));
      await _settle(tester);
      expect(b.loads, 0);
      expect(find.byKey(const ValueKey('fake-native-ad')), findsNothing);
    });
  });
}

// =========================================================================
// fakes + harness
// =========================================================================
class _AdsApi extends ApiClient {
  _AdsApi(this.cfg) {
    token = 't';
  }
  final Map<String, dynamic> cfg;
  final paths = <String>[];
  final posts = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    paths.add(path);
    if (path == '/ads/config') return cfg;
    if (path.startsWith('/ads/slot')) {
      return {'placement': 'app_open', 'show': true, 'source': 'admob', 'reason': 'ok'};
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts.add(Map<String, dynamic>.from(body));
    return {'ok': true};
  }
}

class _FakeFullScreen implements AdsBridge, InterstitialBridge {
  int appOpens = 0;
  final interstitials = <String>[];
  @override
  bool get linked => true;
  @override
  Future<bool> init() async => true;
  @override
  Future<bool> showAppOpen(String unitId) async {
    appOpens++;
    return true;
  }

  @override
  Future<bool> showInterstitial(String unitId, {required String placement}) async {
    interstitials.add(placement);
    return true;
  }

  @override
  Future<RewardOutcome> showRewarded(String unitId) async => RewardOutcome.unavailable;
  @override
  Future<RewardOutcome> showRewardedSsv(String unitId,
          {required String userId, required String customData}) async =>
      RewardOutcome.unavailable;
}

class _FakeBannerHandle implements BannerAdHandle {
  @override
  double get height => 50;
  @override
  Widget view() => const SizedBox(key: ValueKey('fake-banner'), height: 50);
  @override
  void dispose() {}
}

class _FakeBanner implements BannerBridge {
  _FakeBanner({this.fill = true});
  final bool fill;
  int loads = 0;
  final placements = <String>[];
  @override
  bool get linked => true;
  @override
  Future<BannerAdHandle?> load(String unitId,
      {required double width, required String placement}) async {
    loads++;
    placements.add(placement);
    return fill ? _FakeBannerHandle() : null;
  }
}

AppState _app(ApiClient api, {String lang = 'en'}) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(
      id: 1, name: 'Arif', phone: '01700000000', email: '',
      autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return s;
}

Widget _wrap(Widget child, {required String lang}) {
  final app = _app(FakeApi(mode: FakeMode.empty, lang: lang), lang: lang);
  return ChangeNotifierProvider<AppState>.value(
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
      home: Scaffold(body: const SizedBox.expand(), bottomNavigationBar: child),
    ),
  );
}

Widget _home(String lang) {
  final app = _app(FakeApi(mode: FakeMode.empty, lang: lang), lang: lang);
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider<Updater>(create: (_) => Updater()),
    ],
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
      home: const HomeScreen(),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }

}
