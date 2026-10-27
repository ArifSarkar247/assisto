/// AdMob RULE ENGINE — pure Dart (no Flutter, no plugins), unit-tested in
/// test/ad_rules_test.dart + test/admob_policy_test.dart. Mirrors backend
/// core/logic/ads.py.
///
/// Owner rules (25 Oct):
///  * Free plan only. Premium / Business / annual / founder / probashi /
///    trial see ZERO ads (not even an opt-in rewarded ad).
///  * Only on an ALLOWLIST of screens ([AdPlacements] in ad_placements.dart):
///    a new screen gets no ad until it is added there. NEVER on SOS, safety,
///    anti-theft, family alerts, calls, chats, chat lock, payment, login,
///    onboarding or permission screens (hard tokens below, a second fence).
///  * App-open at most once per the server gap (owner 26 Oct: default and
///    floor 3 h) and within the server's daily cap (default 6).
///  * The app ships with Google's TEST unit ids. REAL unit ids come from the
///    server only after the owner turns `admob_real_ids` on — no app update.
library;

enum AdKind { appOpen, rewarded, banner, interstitial, native }

class AdIds {
  AdIds._();
  // Google's official public sample ids.
  static const testAppId = 'ca-app-pub-3940256099942544~3347511713';
  static const testAppOpen = 'ca-app-pub-3940256099942544/9257395921';
  static const testRewarded = 'ca-app-pub-3940256099942544/5224354917';
  static const testBanner = 'ca-app-pub-3940256099942544/6300978111';
  static const testInterstitial = 'ca-app-pub-3940256099942544/1033173712';
  static const testNative = 'ca-app-pub-3940256099942544/2247696110';

  /// Assisto's own AdMob app id — the value in the APK manifest
  /// (com.google.android.gms.ads.APPLICATION_ID, android.yml) and the
  /// publisher in lifeassisto.com/app-ads.txt. Test UNIT ids load fine under
  /// it; real units are only used once the server sends them.
  static const ownerAppId = 'ca-app-pub-2506398550427515~5116255919';

  static String testUnit(AdKind k) => switch (k) {
        AdKind.appOpen => testAppOpen,
        AdKind.rewarded => testRewarded,
        AdKind.banner => testBanner,
        AdKind.interstitial => testInterstitial,
        AdKind.native => testNative,
      };
}

/// Server `/ads/config`, parsed defensively.
class AdConfig {
  const AdConfig({
    this.configured = false,
    this.appId = '',
    this.appOpenUnit = '',
    this.rewardedUnit = '',
    this.bannerUnit = '',
    this.interstitialUnit = '',
    this.nativeUnit = '',
    this.plan = 'free',
    this.paid = false,
    this.adsEnabled = false,
    this.appOpenEnabled = false,
    this.rewardedEnabled = false,
    this.bannerEnabled = false,
    this.interstitialEnabled = false,
    this.appOpenMinGap = AdRules.minAppOpenGap,
    this.appOpenDailyCap = 0,
    this.appOpenMinBackground = const Duration(seconds: 30),
    this.interstitialMinGap = AdRules.minInterstitialGap,
    this.interstitialDailyCap = 0,
    this.bannerScreens = const {},
    this.interstitialMoments = const {},
    this.personalized = false,
    this.blockedScreens = const {},
    this.appOpenStartDay = 2,
    this.appOpenSkipAfterS = 5,
    this.sponsorsEnabled = true,
    this.bannerRefresh = AdRules.minBannerRefresh,
  });

  /// REAL unit ids are being served (owner switch `admob_real_ids`).
  final bool configured;
  final String appId;
  final String appOpenUnit;
  final String rewardedUnit;
  final String bannerUnit;
  final String interstitialUnit;
  final String nativeUnit;
  final String plan;
  final bool paid;

  /// false for Premium/Business (and before the config ever loaded).
  final bool adsEnabled;
  final bool appOpenEnabled;
  final bool rewardedEnabled;
  final bool bannerEnabled;
  final bool interstitialEnabled;
  final Duration appOpenMinGap;
  final int appOpenDailyCap;

  /// App-open only on a return from the background after at least this.
  final Duration appOpenMinBackground;
  final Duration interstitialMinGap;
  final int interstitialDailyCap;

  /// Which of the app's banner pages / interstitial moments the server
  /// switched on (it can only narrow [AdPlacements]).
  final Set<String> bannerScreens;
  final Set<String> interstitialMoments;

  /// Owner allows personalised ads (UMP consent still decides per user).
  final bool personalized;
  final Set<String> blockedScreens;

  /// p2-money: app-open from day N after sign-up; Skip after N seconds.
  final int appOpenStartDay;
  final int appOpenSkipAfterS;

  /// p2-money: direct sponsor slots on (server; Free users only).
  final bool sponsorsEnabled;

  /// banners-everywhere (owner 26 Oct): how often one screen's banner may
  /// be replaced. Never below [AdRules.minBannerRefresh] (60 s), whatever
  /// the server sends.
  final Duration bannerRefresh;

  static const none = AdConfig();

  factory AdConfig.fromJson(Map<String, dynamic>? j) {
    if (j == null) return none;
    String s(dynamic v) => v == null ? '' : '$v'.trim();
    int i(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
    Set<String> set(dynamic v) => ((v is List) ? v : const [])
        .map((e) => '$e'.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toSet();
    final units = (j['units'] is Map) ? (j['units'] as Map) : const {};
    final place =
        (j['placements'] is Map) ? (j['placements'] as Map) : const {};
    final plan = s(j['plan']).isEmpty ? 'free' : s(j['plan']);
    final paid = j['paid'] == true || plan != 'free';
    // never trust only the server for "paid = no ads"
    final ads = j['ads_enabled'] != false && !paid;
    bool on(String k) => ads && place[k] == true;
    return AdConfig(
      configured: j['real_ids'] == true || j['configured'] == true,
      appId: s(j['app_id']),
      appOpenUnit: s(units['app_open']),
      rewardedUnit: s(units['rewarded']),
      bannerUnit: s(units['banner']),
      interstitialUnit: s(units['interstitial']),
      nativeUnit: s(units['native']),
      plan: plan,
      paid: paid,
      adsEnabled: ads,
      appOpenEnabled: ads && j['app_open_enabled'] == true,
      rewardedEnabled: ads && j['rewarded_enabled'] == true,
      bannerEnabled: on('banner'),
      interstitialEnabled: on('interstitial'),
      appOpenMinGap: Duration(
          seconds: i(j['appopen_min_gap_sec']) > 10800
              ? i(j['appopen_min_gap_sec'])
              : 10800),
      appOpenDailyCap: i(j['appopen_daily_cap']),
      appOpenMinBackground: Duration(
          seconds: i(j['appopen_min_bg_sec']) < 5 ? 30 : i(j['appopen_min_bg_sec'])),
      interstitialMinGap: Duration(
          seconds: i(j['interstitial_min_gap_sec']) > 0
              ? i(j['interstitial_min_gap_sec'])
              : 300),
      interstitialDailyCap: i(j['interstitial_daily_cap']),
      bannerScreens: set(j['banner_screens']),
      interstitialMoments: set(j['interstitial_moments']),
      personalized: ads && j['personalized'] == true,
      blockedScreens: set(j['blocked_screens']),
      appOpenStartDay:
          i(j['appopen_start_day']) < 1 ? 2 : i(j['appopen_start_day']),
      appOpenSkipAfterS: i(j['appopen_skip_after_s']).clamp(5, 15),
      sponsorsEnabled: j['sponsors_enabled'] != false,
      // banners-everywhere: floor 60 s, ceiling 1 h, default 60 s
      bannerRefresh: Duration(
          seconds: i(j['banner_refresh_sec'])
              .clamp(AdRules.minBannerRefresh.inSeconds, 3600)),
    );
  }

  String _real(AdKind k) => switch (k) {
        AdKind.appOpen => appOpenUnit,
        AdKind.rewarded => rewardedUnit,
        AdKind.banner => bannerUnit,
        AdKind.interstitial => interstitialUnit,
        AdKind.native => nativeUnit,
      };

  /// The unit to load for [kind]: the REAL unit only when the server serves
  /// real ids (owner switch) AND they belong to the AdMob app this APK was
  /// built with; otherwise Google's TEST unit (owner order: ship with test
  /// ids). [testMode] is kept for old callers and no longer matters.
  String? unitFor(AdKind kind,
      {required String builtAppId, bool testMode = false}) {
    final real = _real(kind);
    if (configured && real.isNotEmpty && appId == builtAppId) return real;
    return AdIds.testUnit(kind);
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
  static const minAppOpenGap = Duration(hours: 3); // owner 26 Oct

  /// The floor for the interstitial gap (owner: max 1 per 5 minutes).
  static const minInterstitialGap = Duration(minutes: 5);

  /// banners-everywhere (owner 26 Oct): a banner is refreshed no faster
  /// than once a minute (Google's own floor is 30 s). The AdMob console
  /// refresh for the banner unit must be OFF — the app refreshes itself.
  static const minBannerRefresh = Duration(seconds: 60);

  /// Hard block — substrings, so 'circle_call', 'payment_ladder',
  /// 'otp_verify', 'voice_sos', 'chat_lock', 'antitheft_alarm' etc. are all
  /// caught. A second fence behind the allowlist in [AdPlacements].
  static const blockedTokens = [
    'sos', 'safety', 'safe', 'emergency', 'fall_detect', 'journey', 'lost',
    'security',
    'theft', 'alert', 'alarm', 'guard',
    'pay', 'topup', 'top_up', 'checkout', 'billing', 'plans', 'purchase',
    'login', 'otp', 'signup', 'register', 'password', 'onboarding', 'welcome',
    'permission', 'language_picker', 'ring_check',
    'call', 'chat', 'messenger', 'conversation', 'lock', 'vault',
    'remit', // budget-remittance: family money screens never carry ads
    // banners-everywhere (owner 26 Oct): banners now reach many normal
    // screens, so the fence also catches account / privacy / family /
    // location / tracking pages and PIN gates. The My Circle chat LIST
    // uses the key 'circle_list' (no token); every conversation screen key
    // still contains 'chat' / 'messenger' / 'conversation'.
    'account', 'delete', 'privacy', 'pin', 'family', 'location', 'track',
    'kid', 'live', 'sign_up', 'language_pick',
  ];

  /// Allowlists (default-deny: anything else is blocked).
  static const appOpenScreens = {'home'};
  static const rewardedScreens = {'credits', 'photo_studio'};

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
    // owner 25 Oct: Premium / Business see zero ads of any kind
    if (config.paid) return const AdDecision(false, 'paid_plan');
    final s = screen.trim().toLowerCase();
    switch (kind) {
      case AdKind.appOpen:
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
        // Rewarded is ALWAYS user-initiated.
        if (!userOptedIn) return const AdDecision(false, 'not_opted_in');
        return AdDecision.ok;
      case AdKind.banner:
      case AdKind.interstitial:
      case AdKind.native:
        // these go through AdPlacements (allowlist + caps) instead
        return const AdDecision(false, 'use_placements');
    }
  }
}
