import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../push/push_service.dart' show appNavigatorKey;
import '../state.dart';
import '../screens/offers_screens.dart' show syncPendingOfferPrefs;
import 'ad_rules.dart';
import 'ads_binding.dart';
import 'ads_bridge.dart';
import 'app_open_gate.dart';
import 'consent.dart';
import 'sponsor_api.dart';
import 'sponsor_widgets.dart' show SponsorAppOpenScreen;

/// Drives AdMob under [AdRules].
///
/// LAZY + CRASH-GUARDED: nothing runs at launch. [start] is called after the
/// first frame (main.dart, see proposal) and itself waits for the app to be
/// idle; the SDK is only initialised right before the first ad is shown. Every
/// step is try/caught.
///
/// CONSENT (L3): every ad request first passes [AdConsent.allowsAds] (Google
/// UMP). Without a real AdMob app id in this APK that gate is a no-op.
///
/// HONEST: rewarded ads earn credits ONLY through Google's signed SSV
/// callback (p2-money); no SDK / no config -> no ad, no reward.
///
/// APP-OPEN (p2-money): Free users, from day 2, max N a day, never after a
/// notification / deep-link / call / SOS entry and never over a safety,
/// payment, login or call screen. A DIRECT sponsor card is shown first
/// (works without AdMob); AdMob's app-open only fills an empty slot once
/// AdMob is linked. The server decides (`/ads/slot`); the client mirror
/// ([AppOpenGate]) only saves a network call.
class AdsService with WidgetsBindingObserver {
  AdsService._();
  static final AdsService instance = AdsService._();

  /// The AdMob app id this APK was built with (manifest APPLICATION_ID is the
  /// same CI value). Real unit ids are used only when the server's app id
  /// matches it.
  static const builtAppId =
      String.fromEnvironment('ADMOB_APP_ID', defaultValue: AdIds.testAppId);

  /// QA switch: serve Google TEST ads in a release build
  /// (--dart-define=ADS_TEST_MODE=true). Debug builds always may.
  static const _testModeDefine =
      bool.fromEnvironment('ADS_TEST_MODE', defaultValue: false);
  static bool get testMode => _testModeDefine || kDebugMode;

  AdsBridge bridge = createAdsBridge();
  AdConfig config = AdConfig.none;
  AppState? _app;
  bool _started = false;
  bool _showing = false;
  DateTime? _configAt;

  /// Elderly simple mode: no app-open ads (accidental-tap risk).
  bool suppressAppOpen = false;

  /// Injectable for tests.
  SponsorBackend? sponsorBackend;
  SponsorBackend? get _sb {
    final a = _app;
    return sponsorBackend ?? (a == null ? null : ApiSponsorBackend(a.api));
  }

  static const _kLast = 'ads_app_open_last_ms';
  static const _kDay = 'ads_app_open_day';
  static const _kCount = 'ads_app_open_count';

  Future<void> start(AppState app) async {
    if (_started) return;
    _started = true;
    _app = app;
    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (_) {}
    // let the launch settle before any ads work
    await Future<void>.delayed(const Duration(seconds: 8));
    final b = _sb;
    if (b != null && app.loggedIn) unawaited(syncPendingOfferPrefs(b));
    await maybeShowAppOpen();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // a notification tap / deep link reports itself just AFTER the resume
      // event; wait for it so that entry never gets an app-open ad
      unawaited(Future<void>.delayed(const Duration(milliseconds: 1500),
          () => maybeShowAppOpen()));
    }
  }

  Future<AdConfig> refreshConfig({bool force = false}) async {
    final app = _app;
    if (app == null || !app.loggedIn) return config;
    if (!force &&
        _configAt != null &&
        DateTime.now().difference(_configAt!) < const Duration(minutes: 30)) {
      return config;
    }
    try {
      final j = await app.api.getJson('/ads/config');
      config = AdConfig.fromJson(j);
      AdConsent.instance.applyServerConfig(j);
      _configAt = DateTime.now();
    } catch (_) {}
    return config;
  }

  /// 'login' when signed out, 'home' at the navigator root, else 'unknown'
  /// (blocked — we never guess that a pushed screen is safe for an ad).
  String currentScreen() {
    final app = _app;
    if (app == null || !app.loggedIn) return 'login';
    try {
      final nav = appNavigatorKey.currentState;
      if (nav != null && !nav.canPop()) return 'home';
    } catch (_) {}
    return 'unknown';
  }

  Future<void> maybeShowAppOpen() async {
    if (_showing || suppressAppOpen) return;
    final app = _app;
    if (app == null || app.loading) return;
    try {
      // Cheap gates first — no network for paid / signed-out / external entry.
      if (!app.loggedIn || currentScreen() != 'home') return;
      final entry = AppEntry.current();
      if (AppEntry.blocked()) return;
      final cfg = await refreshConfig();
      final prefs = await SharedPreferences.getInstance();
      final lastMs = prefs.getInt(_kLast);
      final today = _day(DateTime.now());
      final count = prefs.getString(_kDay) == today
          ? (prefs.getInt(_kCount) ?? 0)
          : 0;
      final pre = AppOpenGate.decide(
        loggedIn: app.loggedIn,
        paid: cfg.paid,
        enabled: cfg.appOpenEnabled || cfg.sponsorsEnabled,
        screen: currentScreen(),
        entry: entry,
        now: DateTime.now(),
        startDay: cfg.appOpenStartDay,
        dailyCap: cfg.appOpenDailyCap,
        shownToday: count,
        gap: cfg.appOpenMinGap,
        lastShownAt:
            lastMs == null ? null : DateTime.fromMillisecondsSinceEpoch(lastMs),
      );
      if (!pre.allowed) return;
      final sb = _sb;
      if (sb == null) return;
      _showing = true;
      // the server is the authority: day-N, caps, gap, free-only, direct first
      final slot = await sb.slot('app_open', screen: 'home', entry: entry);
      if (!slot.show || currentScreen() != 'home' || AppEntry.blocked()) return;
      var shown = false;
      if (slot.isDirect) {
        final nav = appNavigatorKey.currentState;
        if (nav == null || !nav.mounted) return;
        await _markShown(prefs, today, count);
        await SponsorAppOpenScreen.push(nav, slot.creative!,
            skipAfterS: slot.skipAfterS, backend: sb);
        return;
      }
      if (slot.isAdmob) {
        final d = AdRules.decide(
          kind: AdKind.appOpen,
          screen: currentScreen(),
          config: cfg,
          now: DateTime.now(),
          loggedIn: app.loggedIn,
          lastAppOpenAt: lastMs == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(lastMs),
          appOpensToday: count,
        );
        if (!d.allowed) return;
        final unit = cfg.unitFor(AdKind.appOpen,
            builtAppId: builtAppId, testMode: testMode);
        if (unit == null) return;
        // UMP consent BEFORE any ad request (no-op without a real app id).
        if (!await AdConsent.instance.allowsAds()) return;
        shown = await bridge.showAppOpen(unit);
      }
      if (shown) {
        await _markShown(prefs, today, count);
        try {
          await app.api.postJson('/ads/event', {'kind': 'app_open'});
        } catch (_) {}
      }
    } catch (e) {
      if (kDebugMode) debugPrint('app-open ad skipped: $e');
    } finally {
      _showing = false;
    }
  }

  Future<void> _markShown(SharedPreferences prefs, String today, int count) async {
    await prefs.setInt(_kLast, DateTime.now().millisecondsSinceEpoch);
    await prefs.setString(_kDay, today);
    await prefs.setInt(_kCount, count + 1);
  }

  /// p2-money: one rewarded ad tied to a server SSV ticket. Same rules +
  /// consent gate as [showRewarded]; the credit comes ONLY from Google's
  /// signed callback to the server, never from this return value.
  Future<RewardOutcome> showRewardedSsv(AppState app,
      {required String screen,
      required String userId,
      required String customData,
      String unit = ''}) async {
    _app ??= app;
    if (_showing) return RewardOutcome.unavailable;
    try {
      final cfg = await refreshConfig(force: true);
      final d = AdRules.decide(
        kind: AdKind.rewarded,
        screen: screen,
        config: cfg,
        now: DateTime.now(),
        loggedIn: app.loggedIn,
        userOptedIn: true,
      );
      if (!d.allowed) return RewardOutcome.unavailable;
      final u = cfg.unitFor(AdKind.rewarded,
          builtAppId: builtAppId, testMode: testMode);
      if (u == null) return RewardOutcome.unavailable;
      _showing = true;
      if (!await AdConsent.instance.allowsAds()) {
        return RewardOutcome.unavailable;
      }
      // the APK-matched unit (real only when this build carries the same
      // AdMob app id as the server's units; Google TEST unit in test mode)
      return await bridge.showRewardedSsv(u,
          userId: userId, customData: customData);
    } catch (_) {
      return RewardOutcome.unavailable;
    } finally {
      _showing = false;
    }
  }

  /// User-initiated rewarded ad from [screen]. Returns why nothing was shown
  /// via [RewardOutcome.unavailable]; the caller reports `ads/event` only on
  /// [RewardOutcome.earned].
  Future<RewardOutcome> showRewarded(AppState app, {required String screen}) async {
    _app ??= app;
    if (_showing) return RewardOutcome.unavailable;
    try {
      final cfg = await refreshConfig(force: true);
      final d = AdRules.decide(
        kind: AdKind.rewarded,
        screen: screen,
        config: cfg,
        now: DateTime.now(),
        loggedIn: app.loggedIn,
        userOptedIn: true,
      );
      if (!d.allowed) return RewardOutcome.unavailable;
      final unit = cfg.unitFor(AdKind.rewarded,
          builtAppId: builtAppId, testMode: testMode);
      if (unit == null) return RewardOutcome.unavailable;
      _showing = true;
      // UMP consent BEFORE any ad request (no-op without a real app id).
      if (!await AdConsent.instance.allowsAds()) {
        return RewardOutcome.unavailable;
      }
      return await bridge.showRewarded(unit);
    } catch (_) {
      return RewardOutcome.unavailable;
    } finally {
      _showing = false;
    }
  }

  /// NO SHOWPIECES: whether a rewarded ad could really play on [screen] right
  /// now (server config on + a usable unit). Callers hide their "watch an ad"
  /// entry point while this is false instead of opening an "ads aren't set up"
  /// sheet. Never throws; no SDK work.
  Future<bool> rewardedAvailable(AppState app,
      {String screen = 'credits'}) async {
    _app ??= app;
    try {
      final cfg = await refreshConfig();
      final d = AdRules.decide(
        kind: AdKind.rewarded,
        screen: screen,
        config: cfg,
        now: DateTime.now(),
        loggedIn: app.loggedIn,
        userOptedIn: true,
      );
      // a real app id without the UMP SDK can never pass the consent gate
      final c = AdConsent.instance;
      if (c.active && !c.bridge.linked) return false;
      return d.allowed &&
          cfg.unitFor(AdKind.rewarded,
                  builtAppId: builtAppId, testMode: testMode) !=
              null;
    } catch (_) {
      return false;
    }
  }

  /// Settings (L3): for a Free user, ask UMP whether the "Ad privacy
  /// choices" entry is required. No-op (no network, no SDK) without a real
  /// AdMob app id in this APK. Never throws.
  Future<void> refreshConsentStatus(AppState app) async {
    final c = AdConsent.instance;
    if (!c.active || !c.bridge.linked) return;
    _app ??= app;
    try {
      final cfg = await refreshConfig();
      if (cfg.paid) return;
      await c.refreshPrivacyStatus();
    } catch (e) {
      if (kDebugMode) debugPrint('consent status skipped: $e');
    }
  }

  static String _day(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  @visibleForTesting
  void resetForTest() {
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    _started = false;
    _app = null;
    suppressAppOpen = false;
    sponsorBackend = null;
    config = AdConfig.none;
    _configAt = null;
    bridge = createAdsBridge();
  }
}
