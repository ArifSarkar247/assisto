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
/// Max ONE ad per screen: the native card lives only on home, banners only
/// on the three list pages below, and the interstitial moments belong to
/// screens that carry no banner.
library;

import 'ad_rules.dart';

enum AdSurface { appOpen, homeNative, banner, interstitial, rewarded }

class AdPlacements {
  AdPlacements._();

  /// App-open: only over the home screen (the navigator root).
  static const appOpenScreens = {'home'};

  /// The native card: home only, BELOW the quick shortcuts (h1 hero slot).
  static const nativeScreens = {'home'};

  /// Banner: safe, calm list pages only (no safety, money, chat or
  /// account screens). Each carries `AdBannerSlot(screen: ...)`.
  static const bannerScreens = {'saved_items', 'dictionary', 'health_tips'};

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
    'circle_call', 'incoming_call', 'call_history', 'chat', 'circle_chat',
    'group_chat', 'messenger', 'chat_lock', 'vault', 'payment', 'checkout',
    'plans', 'topup', 'login', 'otp', 'signup', 'password_reset',
    'onboarding', 'language_picker', 'permission', 'ring_check',
    'remittance', 'budget_remittance', // budget-remittance: money screens
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
