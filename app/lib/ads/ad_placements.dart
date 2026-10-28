/// AdMob PLACEMENTS — the ONE central allowlist (owner 25 Oct). Pure Dart,
/// unit-tested in test/admob_policy_test.dart.
///
/// Default-deny: a screen shows an ad ONLY if it is listed here. A new screen
/// therefore gets no ad until someone adds it on purpose. The server can
/// switch a listed screen / moment off (`banner_screens`,
/// `interstitial_moments`, per-placement switches); it can never add one.
/// Behind the allowlist, [AdRules.isBlockedScreen] is a second fence: a name
/// containing sos / safety / theft / alert / call / chat / lock / pay / login /
/// onboarding / permission ... is refused even if someone lists it.
///
/// Max ONE persistent ad per screen: the native card lives only on home,
/// one anchored banner on each normal feature screen below (never home),
/// never two banners on one route ([BannerPacer.claim]). Interstitials are
/// full-screen moments, never shown while a banner page is being used
/// mid-task (they follow a finished action).
library;

import 'ad_rules.dart';

enum AdSurface { appOpen, homeNative, banner, interstitial, rewarded }

class AdPlacements {
  AdPlacements._();

  /// App-open: only over the home screen (the navigator root).
  static const appOpenScreens = {'home'};

  /// The native card: home only, BELOW the quick shortcuts (h1 hero slot).
  static const nativeScreens = {'home'};

  /// Banner — owner decision 26 Oct ("banners-everywhere"): one adaptive
  /// anchored banner at the bottom of every NORMAL Free-user feature
  /// screen. Each key below is used by exactly one screen through
  /// `AdBannerSlot(screen: '<key>')`. Never a safety, anti-theft, family,
  /// call, chat-conversation, lock/vault-PIN, payment/plans, login/OTP,
  /// onboarding, language or permission screen (see [neverScreens] and the
  /// token fence). The server's `banner_screens` can only NARROW this.
  /// Mirrored in backend core/logic/ads.py + pricing.py BANNER_SCREENS.
  static const bannerScreens = {
    // the three original calm list pages (owner 25 Oct)
    'saved_items', 'dictionary', 'health_tips',
    // money / expense tracking (NOT payment, checkout, top-up, remittance)
    'money', 'budget', 'money_report', 'money_trends', 'money_networth',
    'money_tax',
    // personal organiser
    'reminders', 'notes_todos', 'birthdays', 'meetings',
    // NOT documents: it is the PIN vault (owner: never on chat lock / vault)
    // work / business
    'jobs', 'cv_builder', 'business', 'crm', 'contract', 'prepaid_meter',
    // discovery / info
    'all_services', 'guide', 'nearby', 'quick_tools', 'medicine_db',
    'ramadan', 'exam',
    // Photo Studio landing / picker (never while editing or exporting)
    'photo_gallery',
    // My Circle chat LIST only (Chats tab). The conversation screen, calls
    // tab, chat lock and vault keep NO ad (their keys hit the fence).
    'circle_list',
    // the plain Settings list (never account security / password /
    // delete-account / permission sub-pages)
    'settings',
  };

  /// Interstitial: natural breaks only -> the screen it appears over.
  static const interstitialMoments = {
    'photo_saved': 'photo_studio', // after a photo was saved
    'task_done': 'notes_todos', // after a to-do was ticked done
  };

  /// Rewarded: user-initiated only, verified by the server (SSV).
  static const rewardedScreens = {'credits', 'photo_studio'};

  /// Screens that must NEVER carry an ad (documentation + tests; the
  /// allowlist above is what actually decides).
  static const neverScreens = [
    'sos', 'voice_sos', 'journey_sos', 'safety', 'safe_arrival', 'fall_detect',
    'emergency', 'antitheft', 'lost_stolen', 'my_lost_phone', 'family_alerts',
    'watched_phones', // at100
    'circle_call', 'incoming_call', 'call_history', 'chat', 'circle_chat',
    'group_chat', 'messenger', 'chat_lock', 'vault', 'payment', 'checkout',
    'plans', 'topup', 'login', 'otp', 'signup', 'password_reset',
    'onboarding', 'language_picker', 'permission', 'ring_check',
    'remittance', 'budget_remittance', // budget-remittance: money screens
    // banners-everywhere (owner 26 Oct): spelled out so the tests prove
    // each is refused even if someone lists it.
    'safe_journey', 'journey', 'journey_live', 'journey_settings',
    'journey_history', 'fall_detection', 'anti_theft', 'antitheft_alarm',
    'phone_safety', 'vehicle_tracking', 'family', 'family_alert',
    'in_call', 'call_log', 'circle_calls', 'chat_conversation',
    'circle_conversation', 'messenger_chat', 'chat_vault', 'vault_pin',
    'documents_pin', 'payment_ladder', 'business_plans', 'top_up',
    'credits_topup', 'sign_up', 'otp_verify', 'language_pick',
    'ring_checklist', 'battery_permission', 'settings_account',
    'account_security', 'security', 'security_checkup', 'password',
    'delete_account', 'privacy', 'circle_privacy',
  ];

  static Set<String> _allow(AdSurface slot) => switch (slot) {
        AdSurface.appOpen => appOpenScreens,
        AdSurface.homeNative => nativeScreens,
        AdSurface.banner => bannerScreens,
        AdSurface.interstitial => interstitialMoments.values.toSet(),
        AdSurface.rewarded => rewardedScreens,
      };

  /// May [slot] appear on [screen] at all (code allowlist + hard fence)?
  static bool screenAllowed(AdSurface slot, String screen) {
    final s = screen.trim().toLowerCase();
    if (AdRules.isBlockedScreen(s)) return false;
    return _allow(slot).contains(s);
  }

  /// Banner on [screen] right now: Free user, server switch on, the screen
  /// in BOTH the app allowlist and the server's `banner_screens`.
  static AdDecision banner(String screen, AdConfig cfg, {required bool loggedIn}) {
    if (!loggedIn) return const AdDecision(false, 'logged_out');
    if (cfg.paid || !cfg.adsEnabled) return const AdDecision(false, 'paid_plan');
    final s = screen.trim().toLowerCase();
    if (!screenAllowed(AdSurface.banner, s)) {
      return const AdDecision(false, 'screen_not_allowed');
    }
    if (!cfg.bannerEnabled) return const AdDecision(false, 'disabled');
    if (!cfg.bannerScreens.contains(s)) {
      return const AdDecision(false, 'server_off');
    }
    return AdDecision.ok;
  }

  /// Interstitial at [moment]: Free user, server switch + moment on, >= the
  /// gap since ANY full-screen ad, within the daily cap.
  static AdDecision interstitial(
    String moment,
    AdConfig cfg, {
    required bool loggedIn,
    required DateTime now,
    DateTime? lastFullScreenAt,
    int shownToday = 0,
  }) {
    if (!loggedIn) return const AdDecision(false, 'logged_out');
    if (cfg.paid || !cfg.adsEnabled) return const AdDecision(false, 'paid_plan');
    final m = moment.trim().toLowerCase();
    final screen = interstitialMoments[m];
    if (screen == null || !screenAllowed(AdSurface.interstitial, screen)) {
      return const AdDecision(false, 'moment_not_allowed');
    }
    if (!cfg.interstitialEnabled) return const AdDecision(false, 'disabled');
    if (!cfg.interstitialMoments.contains(m)) {
      return const AdDecision(false, 'server_off');
    }
    final gap = cfg.interstitialMinGap < AdRules.minInterstitialGap
        ? AdRules.minInterstitialGap
        : cfg.interstitialMinGap;
    if (lastFullScreenAt != null && now.difference(lastFullScreenAt) < gap) {
      return const AdDecision(false, 'too_soon');
    }
    if (cfg.interstitialDailyCap <= 0 || shownToday >= cfg.interstitialDailyCap) {
      return const AdDecision(false, 'daily_cap');
    }
    return AdDecision.ok;
  }
}

/// banners-everywhere (owner 26 Oct) caps, pure Dart so they are unit-tested:
///  * ONE banner per route: the first slot on a route claims it, any other
///    slot on the same route stays empty.
///  * a screen's banner is (re)loaded no faster than [AdConfig.bannerRefresh]
///    (floor [AdRules.minBannerRefresh] = 60 s) — also across leaving and
///    re-opening the screen.
class BannerPacer {
  BannerPacer._();

  static final Map<Object, Object> _claims = {};
  static final Map<String, DateTime> _lastLoad = {};

  /// [owner] wants to show a banner on [route]. true = it may (first one).
  static bool claim(Object route, Object owner) {
    final cur = _claims[route];
    if (cur != null && !identical(cur, owner)) return false;
    _claims[route] = owner;
    return true;
  }

  static void release(Object route, Object owner) {
    if (identical(_claims[route], owner)) _claims.remove(route);
  }

  /// How long [screen] must wait before its next banner request.
  static Duration wait(String screen, DateTime now, Duration refresh) {
    final r = refresh < AdRules.minBannerRefresh ? AdRules.minBannerRefresh : refresh;
    final last = _lastLoad[screen];
    if (last == null) return Duration.zero;
    final left = r - now.difference(last);
    return left.isNegative ? Duration.zero : left;
  }

  static void markLoaded(String screen, DateTime now) => _lastLoad[screen] = now;

  static void resetForTest() {
    _claims.clear();
    _lastLoad.clear();
  }
}

/// Natural-break hook: screens / controllers report a moment ('photo_saved',
/// 'task_done') here without importing the ads service (keeps them testable).
/// AdsService installs [sink]; nothing happens until it does.
class AdMoments {
  AdMoments._();
  static void Function(String moment)? sink;

  static void report(String moment) {
    try {
      sink?.call(moment);
    } catch (_) {
      // an ad problem never reaches the caller
    }
  }
}

/// ACCIDENTAL-CLICK GUARD (ads check 28 Oct, AdMob "don't surprise users
/// with interstitials"): an interstitial never pops up under a finger that
/// is still tapping. AdsService feeds every pointer-down here; the
/// interstitial bridge shows a loaded ad only once the screen has been
/// untouched for [quiet] (waiting at most [maxWait], else no ad). Ticking
/// several to-dos in a row therefore never lands a tap on an ad.
class AdTouchGuard {
  AdTouchGuard._();

  static const quiet = Duration(milliseconds: 1500);
  static const maxWait = Duration(seconds: 4);
  static DateTime? _lastDown;

  static void notePointerDown([DateTime? at]) => _lastDown = at ?? DateTime.now();

  /// No touch for [quiet] before [now].
  static bool idle(DateTime now) {
    final d = _lastDown;
    return d == null || now.difference(d) >= quiet;
  }

  /// How long to wait from [now] before the screen counts as idle (zero when
  /// it already is), or null when that is beyond [maxWait] from [since].
  static Duration? waitFor(DateTime now, DateTime since) {
    final d = _lastDown;
    if (d == null || now.difference(d) >= quiet) return Duration.zero;
    final ready = d.add(quiet);
    if (ready.difference(since) > maxWait) return null;
    return ready.difference(now);
  }

  static void resetForTest() => _lastDown = null;
}
