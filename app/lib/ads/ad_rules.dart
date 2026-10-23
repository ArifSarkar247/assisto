/// AdMob RULE ENGINE — pure Dart (no Flutter, no plugins), unit-tested in
/// test/ad_rules_test.dart. Mirrors backend core/logic/ads.py.
///
/// Owner rules:
///  * Free plan only. Premium / Business / annual / founder / probashi see NO
///    ads — except a rewarded ad the user explicitly opts into for credits.
///  * NEVER on safety/SOS, payment/top-up/checkout, login/OTP or call screens.
///    Unknown screens are treated as blocked (default-deny allowlist).
///  * App-open at most once per the server gap (default 3 h; the owner may
///    set 1 h .. 24 h — never below 1 h) and within the server's daily cap
///    (default 3), from day 2 after sign-up, skippable after 5 s (p2-money).
///  * Until the owner saves REAL ids the app only uses Google's TEST ids, and
///    in a release build shows nothing unless QA test-mode is on.
library;

enum AdKind { appOpen, rewarded }

class AdIds {
  AdIds._();
  // Google's official public sample ids.
  static const testAppId = 'ca-app-pub-3940256099942544~3347511713';
  static const testAppOpen = 'ca-app-pub-3940256099942544/9257395921';
  static const testRewarded = 'ca-app-pub-3940256099942544/5224354917';
}

/// Server `/ads/config`, parsed defensively.
class AdConfig {
  const AdConfig({
    this.configured = false,
    this.appId = '',
    this.appOpenUnit = '',
    this.rewardedUnit = '',
    this.plan = 'free',
    this.paid = false,
    this.appOpenEnabled = false,
    this.rewardedEnabled = false,
    this.appOpenMinGap = AdRules.minAppOpenGap,
    this.appOpenDailyCap = 0,
    this.blockedScreens = const {},
    this.appOpenStartDay = 2,
    this.appOpenSkipAfterS = 5,
    this.sponsorsEnabled = true,
  });

  final bool configured;
  final String appId;
  final String appOpenUnit;
  final String rewardedUnit;
  final String plan;
  final bool paid;
  final bool appOpenEnabled;
  final bool rewardedEnabled;
  final Duration appOpenMinGap;
  final int appOpenDailyCap;
  final Set<String> blockedScreens;

  /// p2-money: app-open from day N after sign-up; Skip after N seconds.
  final int appOpenStartDay;
  final int appOpenSkipAfterS;

  /// p2-money: direct sponsor slots on (server; Free users only).
  final bool sponsorsEnabled;

  static const none = AdConfig();

  factory AdConfig.fromJson(Map<String, dynamic>? j) {
    if (j == null) return none;
    String s(dynamic v) => v == null ? '' : '$v'.trim();
    int i(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
    final units = (j['units'] is Map) ? (j['units'] as Map) : const {};
    final plan = s(j['plan']).isEmpty ? 'free' : s(j['plan']);
    return AdConfig(
      configured: j['configured'] == true,
      appId: s(j['app_id']),
      appOpenUnit: s(units['app_open']),
      rewardedUnit: s(units['rewarded']),
      plan: plan,
      paid: j['paid'] == true || plan != 'free',
      appOpenEnabled: j['app_open_enabled'] == true,
      rewardedEnabled: j['rewarded_enabled'] == true,
      appOpenMinGap: Duration(
          seconds: i(j['appopen_min_gap_sec']) > 0
              ? i(j['appopen_min_gap_sec'])
              : 3 * 3600),
      appOpenDailyCap: i(j['appopen_daily_cap']),
      blockedScreens: ((j['blocked_screens'] as List?) ?? const [])
          .map((e) => '$e'.toLowerCase())
          .toSet(),
      appOpenStartDay:
          i(j['appopen_start_day']) < 1 ? 2 : i(j['appopen_start_day']),
      appOpenSkipAfterS: i(j['appopen_skip_after_s']).clamp(5, 15),
      sponsorsEnabled: j['sponsors_enabled'] != false,
    );
  }

  /// The unit to load for [kind]. REAL only when the owner configured real
  /// ids AND this APK was built with the same AdMob app id (the manifest
  /// APPLICATION_ID must match the units' account); otherwise Google's TEST
  /// unit. Returns null when nothing may be served.
  String? unitFor(AdKind kind,
      {required String builtAppId, required bool testMode}) {
    final real = kind == AdKind.appOpen ? appOpenUnit : rewardedUnit;
    if (configured && real.isNotEmpty && appId == builtAppId) return real;
    if (testMode) {
      return kind == AdKind.appOpen ? AdIds.testAppOpen : AdIds.testRewarded;
    }
    return null;
  }
}

class AdDecision {
  const AdDecision(this.allowed, this.reason);
  final bool allowed;
  final String reason;

  static const ok = AdDecision(true, 'ok');

  @override
  String toString() => 'AdDecision($allowed, $reason)';
}

class AdRules {
  AdRules._();

  /// The floor for the app-open gap (owner-editable 1 h .. 24 h).
  static const minAppOpenGap = Duration(hours: 1);

  /// Hard block — substrings, so 'circle_call', 'payment_ladder',
  /// 'otp_verify', 'voice_sos' etc. are all caught.
  static const blockedTokens = [
    'sos', 'safety', 'emergency', 'fall_detect', 'journey', 'lost', 'security',
    'pay', 'topup', 'top_up', 'checkout', 'billing', 'plans',
    'login', 'otp', 'signup', 'register', 'password',
    'call',
  ];

  /// Allowlists (default-deny: anything else is blocked).
  static const appOpenScreens = {'home'};
  static const rewardedScreens = {'credits'};

  static bool isBlockedScreen(String screen, [Set<String> extra = const {}]) {
    final s = screen.trim().toLowerCase();
    if (s.isEmpty || s == 'unknown') return true;
    if (extra.contains(s)) return true;
    return blockedTokens.any(s.contains);
  }

  static AdDecision decide({
    required AdKind kind,
    required String screen,
    required AdConfig config,
    required DateTime now,
    required bool loggedIn,
    DateTime? lastAppOpenAt,
    int appOpensToday = 0,
    bool userOptedIn = false,
    bool checkoutInProgress = false,
  }) {
    if (!loggedIn) return const AdDecision(false, 'logged_out');
    if (checkoutInProgress) return const AdDecision(false, 'checkout');
    if (isBlockedScreen(screen, config.blockedScreens)) {
      return const AdDecision(false, 'blocked_screen');
    }
    final s = screen.trim().toLowerCase();
    switch (kind) {
      case AdKind.appOpen:
        if (config.paid) return const AdDecision(false, 'paid_plan');
        if (!config.appOpenEnabled) return const AdDecision(false, 'disabled');
        if (!appOpenScreens.contains(s)) {
          return const AdDecision(false, 'screen_not_allowed');
        }
        final gap = config.appOpenMinGap > minAppOpenGap
            ? config.appOpenMinGap
            : minAppOpenGap;
        if (lastAppOpenAt != null && now.difference(lastAppOpenAt) < gap) {
          return const AdDecision(false, 'too_soon');
        }
        if (config.appOpenDailyCap <= 0 ||
            appOpensToday >= config.appOpenDailyCap) {
          return const AdDecision(false, 'daily_cap');
        }
        return AdDecision.ok;
      case AdKind.rewarded:
        if (!config.rewardedEnabled) return const AdDecision(false, 'disabled');
        if (!rewardedScreens.contains(s)) {
          return const AdDecision(false, 'screen_not_allowed');
        }
        // Rewarded is ALWAYS user-initiated; for paid plans it is the only ad.
        if (!userOptedIn) return const AdDecision(false, 'not_opted_in');
        return AdDecision.ok;
    }
  }
}
