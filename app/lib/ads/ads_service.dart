import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../calls/call_runtime.dart' show CallRuntime;
import '../push/push_service.dart' show appNavigatorKey;
import '../state.dart';
import '../screens/offers_screens.dart' show syncPendingOfferPrefs;
import 'ad_placements.dart';
import 'ad_rules.dart';
import 'ad_telemetry.dart';
import 'admob_sdk.dart';
import 'ads_binding.dart';
import 'ads_bridge.dart';
import 'app_open_gate.dart';
import 'consent.dart';
import 'sponsor_api.dart';
import 'sponsor_widgets.dart' show SponsorAppOpenScreen;

/// Drives AdMob under [AdRules] + [AdPlacements] (admob, owner 25 Oct).
///
/// LAZY + CRASH-GUARDED: nothing runs at launch. [start] is called after the
/// first frame (main.dart) and itself waits for the app to be idle; Google
/// UMP consent and MobileAds.initialize happen only after that, only for a
/// Free user ([AdmobSdk.ensureReady]). Every step is try/caught; a failure
/// is "no ad", never an error.
///
/// FREE ONLY: the server's `/ads/config` says ads_enabled=false for Premium
/// / Business and the client re-checks the plan before every ad.
///
/// HONEST: rewarded ads grant something ONLY through Google's signed SSV
/// callback to our API; test unit ids (the default until the owner flips
/// `admob_real_ids`) never offer a rewarded ad.
///
/// APP-OPEN: Free users, from day 2, max N a day (default 6), >= 1 h apart,
/// never on the very first launch, never in the session right after a
/// sign-in, never after a notification / SOS / safety alert / call / alarm /
/// reminder / widget / deep-link entry ([AppEntry] + the native
/// "adLaunchSuppressed" flag), only on a resume after >= N s in the
/// background, and only over the home root. A DIRECT sponsor card is shown
/// first (works without AdMob); AdMob fills an empty slot. The server
/// decides (`/ads/slot`); the client mirror only saves a network call.
///
/// INTERSTITIAL: natural breaks only ([AdMoments]: 'photo_saved',
/// 'task_done'), >= 5 min after ANY full-screen ad, within the daily cap.
class AdsService with WidgetsBindingObserver {
  AdsService._();
  static final AdsService instance = AdsService._();

  /// The AdMob app id in this APK's manifest (android.yml). Real unit ids
  /// are used only when the server's app id matches it.
  static const builtAppId =
      String.fromEnvironment('ADMOB_APP_ID', defaultValue: AdIds.ownerAppId);

  /// Kept for old callers: test units are now served in every build until
  /// the server sends real ids.
  static bool get testMode => true;

  AdsBridge bridge = createAdsBridge();
  InterstitialBridge interstitials = createInterstitialBridge();
  AdConfig config = AdConfig.none;
  AppState? _app;
  bool _started = false;
  bool _showing = false;
  DateTime? _configAt;
  Future<AdConfig>? _configInFlight;

  /// Elderly simple mode: no app-open ads (accidental-tap risk).
  bool suppressAppOpen = false;

  /// What the navigator ROOT shows (main.dart): 'home', 'login',
  /// 'onboarding', 'deletion_grace', 'elderly_home', 'language_picker'.
  String rootScreen = 'home';

  /// This process saw a signed-out state -> the session right after the
  /// sign-in never gets an app-open ad.
  bool _sawSignedOut = false;

  /// The very first launch of the app ever (no app-open that session).
  bool _firstLaunchSession = false;

  DateTime? _pausedAt;

  /// Injectable for tests.
  SponsorBackend? sponsorBackend;
  SponsorBackend? get _sb {
    final a = _app;
    return sponsorBackend ?? (a == null ? null : ApiSponsorBackend(a.api));
  }

  /// Test seam for the native launch-source flag.
  @visibleForTesting
  Future<bool> Function()? debugNativeSuppressed;

  static const _kLast = 'ads_app_open_last_ms';
  static const _kDay = 'ads_app_open_day';
  static const _kCount = 'ads_app_open_count';
  static const _kSeen = 'ads_first_launch_done';
  static const _kFsLast = 'ads_fullscreen_last_ms';
  static const _kIDay = 'ads_inter_day';
  static const _kICount = 'ads_inter_count';

  /// main.dart: the login screen is showing (logout, first sign-in...).
  void noteSignedOut() => _sawSignedOut = true;

  Future<void> start(AppState app) async {
    if (_started) return;
    _started = true;
    _app = app;
    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (_) {}
    AdTelemetry.sink = _report;
    AdMoments.sink = (m) => unawaited(maybeInterstitial(m));
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_kSeen) != true) {
        _firstLaunchSession = true;
        await prefs.setBool(_kSeen, true);
      }
    } catch (_) {}
    // let the launch settle before any ads work (no UMP, no SDK before this)
    await Future<void>.delayed(const Duration(seconds: 8));
    AdmobSdk.markLaunchSettled();
    final b = _sb;
    if (b != null && app.loggedIn) unawaited(syncPendingOfferPrefs(b));
    try {
      final cfg = await refreshConfig();
      // Google UMP: request the consent info (and show Google's form where
      // the law requires it) once per session, lazily, Free users only.
      if (cfg.adsEnabled && !cfg.paid) await AdConsent.instance.allowsAds();
    } catch (_) {}
    await maybeShowAppOpen();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _pausedAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final at = _pausedAt;
      _pausedAt = null;
      final bg = at == null ? null : DateTime.now().difference(at);
      // a notification tap / deep link reports itself just AFTER the resume
      // event; wait for it so that entry never gets an app-open ad
      unawaited(Future<void>.delayed(const Duration(milliseconds: 1500),
          () => maybeShowAppOpen(resumed: true, backgroundFor: bg)));
    }
  }

  /// The config for [app] (cached 30 min). Never throws.
  Future<AdConfig> configFor(AppState app) {
    _app ??= app;
    return refreshConfig();
  }

  Future<AdConfig> refreshConfig({bool force = false}) {
    final app = _app;
    if (app == null || !app.loggedIn) return Future.value(config);
    if (!force &&
        _configAt != null &&
        DateTime.now().difference(_configAt!) < const Duration(minutes: 30)) {
      return Future.value(config);
    }
    return _configInFlight ??= _fetch(app).whenComplete(() => _configInFlight = null);
  }

  Future<AdConfig> _fetch(AppState app) async {
    try {
      final j = await app.api.getJson('/ads/config');
      config = AdConfig.fromJson(j);
      AdConsent.instance.applyServerConfig(j);
      AdmobSdk.personalized = config.personalized;
      _configAt = DateTime.now();
    } catch (_) {}
    return config;
  }

  /// 'login' when signed out, [rootScreen] at the navigator root, else
  /// 'unknown' (blocked — we never guess that a pushed screen is safe).
  String currentScreen() {
    final app = _app;
    if (app == null || !app.loggedIn) return 'login';
    try {
      final nav = appNavigatorKey.currentState;
      if (nav != null && !nav.canPop()) return rootScreen;
    } catch (_) {}
    return 'unknown';
  }

  Future<bool> _nativeSuppressed() async {
    final f = debugNativeSuppressed;
    if (f != null) return f();
    try {
      const ch = MethodChannel('com.assisto/device_admin');
      return await ch.invokeMethod<bool>('adLaunchSuppressed') ?? false;
    } catch (_) {
      return false; // channel missing (tests / non-Android)
    }
  }

  /// A call is going on (full screen or minimised to the mini bar).
  static bool _callActive() {
    try {
      return CallRuntime.instance.ongoing.value != null;
    } catch (_) {
      return true; // unsure -> no ad (never risk an ad over a call)
    }
  }

  Future<void> maybeShowAppOpen({bool resumed = false, Duration? backgroundFor}) async {
    if (_showing || suppressAppOpen) return;
    final app = _app;
    if (app == null || app.loading) return;
    try {
      // Cheap gates first — no network for signed-out / external entry.
      if (!app.loggedIn) return;
      final entry = AppEntry.current();
      // read BOTH flags every time so a stale one never leaks into later
      final dartSuppressed = AppEntry.consumeSuppression() || AppEntry.blocked();
      final nativeSuppressed = await _nativeSuppressed();
      final cfg0 = config;
      final guard = AppOpenGuard.check(
        firstLaunchEver: _firstLaunchSession,
        sessionAfterLogin: _sawSignedOut,
        suppressed: dartSuppressed || nativeSuppressed,
        screen: currentScreen(),
        resumed: resumed,
        backgroundFor: backgroundFor,
        minBackground: cfg0.appOpenMinBackground,
        callActive: _callActive(),
      );
      if (!guard.allowed) return;
      final cfg = await refreshConfig();
      if (cfg.paid || !cfg.adsEnabled) return;
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
        final unit = cfg.unitFor(AdKind.appOpen, builtAppId: builtAppId);
        if (unit == null) return;
        // UMP consent + lazy SDK init happen inside the bridge
        shown = await bridge.showAppOpen(unit);
      }
      if (shown) await _markShown(prefs, today, count);
      // the impression itself is reported by the SDK callback (AdTelemetry)
    } catch (e) {
      if (kDebugMode) debugPrint('app-open ad skipped: $e');
    } finally {
      _showing = false;
    }
  }

  Future<void> _markShown(SharedPreferences prefs, String today, int count) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await prefs.setInt(_kLast, now);
    await prefs.setInt(_kFsLast, now);
    await prefs.setString(_kDay, today);
    await prefs.setInt(_kCount, count + 1);
  }

  /// A natural break ([AdPlacements.interstitialMoments]) happened. Shows at
  /// most one interstitial, >= the gap after ANY full-screen ad, within the
  /// daily cap, Free users only, never over a forbidden screen. Never throws.
  Future<bool> maybeInterstitial(String moment) async {
    if (_showing) return false;
    final app = _app;
    if (app == null || app.loading || !app.loggedIn) return false;
    try {
      if (!interstitials.linked) return false;
      final cfg = await refreshConfig();
      final prefs = await SharedPreferences.getInstance();
      final lastMs = prefs.getInt(_kFsLast);
      final today = _day(DateTime.now());
      final count =
          prefs.getString(_kIDay) == today ? (prefs.getInt(_kICount) ?? 0) : 0;
      final d = AdPlacements.interstitial(moment, cfg,
          loggedIn: app.loggedIn,
          now: DateTime.now(),
          lastFullScreenAt:
              lastMs == null ? null : DateTime.fromMillisecondsSinceEpoch(lastMs),
          shownToday: count);
      if (!d.allowed) return false;
      final unit = cfg.unitFor(AdKind.interstitial, builtAppId: builtAppId);
      if (unit == null) return false;
      _showing = true;
      final shown = await interstitials.showInterstitial(unit,
          placement: 'interstitial_$moment');
      if (shown) {
        await prefs.setInt(_kFsLast, DateTime.now().millisecondsSinceEpoch);
        await prefs.setString(_kIDay, today);
        await prefs.setInt(_kICount, count + 1);
      }
      return shown;
    } catch (e) {
      if (kDebugMode) debugPrint('interstitial skipped: $e');
      return false;
    } finally {
      _showing = false;
    }
  }

  /// Fire-and-forget POST /ads/event for the tuning log.
  void _report(AdEventRecord e) {
    final app = _app;
    if (app == null || !app.loggedIn) return;
    unawaited(() async {
      try {
        await app.api.postJson('/ads/event', e.toJson());
      } catch (_) {}
    }());
  }

  Future<void> _markFullScreen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kFsLast, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
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
      final u = cfg.unitFor(AdKind.rewarded, builtAppId: builtAppId);
      if (u == null) return RewardOutcome.unavailable;
      _showing = true;
      if (!await AdConsent.instance.allowsAds()) {
        return RewardOutcome.unavailable;
      }
      final out = await bridge.showRewardedSsv(u,
          userId: userId, customData: customData);
      if (out != RewardOutcome.unavailable) unawaited(_markFullScreen());
      return out;
    } catch (_) {
      return RewardOutcome.unavailable;
    } finally {
      _showing = false;
    }
  }

  /// User-initiated rewarded ad from [screen]. Returns why nothing was shown
  /// via [RewardOutcome.unavailable].
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
      final unit = cfg.unitFor(AdKind.rewarded, builtAppId: builtAppId);
      if (unit == null) return RewardOutcome.unavailable;
      _showing = true;
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

  /// NO SHOWPIECES: whether a rewarded ad could really play (and be
  /// verified) on [screen] right now. Callers hide their "watch an ad" entry
  /// point while this is false. Never throws; no SDK work.
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
      if (!bridge.linked) return false;
      return d.allowed &&
          cfg.unitFor(AdKind.rewarded, builtAppId: builtAppId) != null;
    } catch (_) {
      return false;
    }
  }

  /// Settings (L3): for a Free user, ask UMP whether the "Ad privacy
  /// choices" entry is required. No-op (no network, no SDK) where AdMob does
  /// not run. Never throws.
  Future<void> refreshConsentStatus(AppState app) async {
    final c = AdConsent.instance;
    if (!c.active || !c.bridge.linked) return;
    _app ??= app;
    try {
      final cfg = await refreshConfig();
      if (cfg.paid || !cfg.adsEnabled) return;
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
    _configInFlight = null;
    _sawSignedOut = false;
    _firstLaunchSession = false;
    _pausedAt = null;
    rootScreen = 'home';
    debugNativeSuppressed = null;
    AdTelemetry.sink = null;
    AdMoments.sink = null;
    bridge = createAdsBridge();
    interstitials = createInterstitialBridge();
  }

  /// Test seam: act as if [start] ran for [app] (no delays, no observer).
  @visibleForTesting
  void attachForTest(AppState app, {bool firstLaunch = false, bool afterLogin = false}) {
    _app = app;
    _firstLaunchSession = firstLaunch;
    _sawSignedOut = afterLogin;
    AdTelemetry.sink = _report;
  }
}
