import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../push/push_service.dart' show appNavigatorKey;
import '../state.dart';
import 'ad_rules.dart';
import 'ads_binding.dart';
import 'ads_bridge.dart';

/// Drives AdMob under [AdRules].
///
/// LAZY + CRASH-GUARDED: nothing runs at launch. [start] is called after the
/// first frame (main.dart, see proposal) and itself waits for the app to be
/// idle; the SDK is only initialised right before the first ad is shown. Every
/// step is try/caught.
///
/// HONEST: a reward is reported to the server ONLY after the SDK's
/// onUserEarnedReward fired. No SDK / no config -> no ad, no reward.
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
    await maybeShowAppOpen();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(maybeShowAppOpen());
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
      config = AdConfig.fromJson(await app.api.getJson('/ads/config'));
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
    if (_showing) return;
    final app = _app;
    if (app == null || app.loading) return;
    try {
      // Cheap gates first — no network, no SDK for paid / signed-out users.
      if (!app.loggedIn || currentScreen() != 'home') return;
      final cfg = await refreshConfig();
      final prefs = await SharedPreferences.getInstance();
      final lastMs = prefs.getInt(_kLast);
      final today = _day(DateTime.now());
      final count = prefs.getString(_kDay) == today
          ? (prefs.getInt(_kCount) ?? 0)
          : 0;
      final d = AdRules.decide(
        kind: AdKind.appOpen,
        screen: currentScreen(),
        config: cfg,
        now: DateTime.now(),
        loggedIn: app.loggedIn,
        lastAppOpenAt:
            lastMs == null ? null : DateTime.fromMillisecondsSinceEpoch(lastMs),
        appOpensToday: count,
      );
      if (!d.allowed) return;
      final unit = cfg.unitFor(AdKind.appOpen,
          builtAppId: builtAppId, testMode: testMode);
      if (unit == null) return;
      _showing = true;
      final shown = await bridge.showAppOpen(unit);
      if (shown) {
        await prefs.setInt(_kLast, DateTime.now().millisecondsSinceEpoch);
        await prefs.setString(_kDay, today);
        await prefs.setInt(_kCount, count + 1);
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
      return d.allowed &&
          cfg.unitFor(AdKind.rewarded,
                  builtAppId: builtAppId, testMode: testMode) !=
              null;
    } catch (_) {
      return false;
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
    config = AdConfig.none;
    _configAt = null;
    bridge = createAdsBridge();
  }
}
