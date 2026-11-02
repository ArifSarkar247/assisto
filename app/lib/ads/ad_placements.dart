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
///
/// OWNER ADS FINAL (2 Nov, admobump): interstitials ONLY on the EXIT
/// transition after a finished task ([AdExit] + [AdExitPlacement]); max 4 a
/// day, >= 800 s apart, none on the user's first day, never on a paid plan;
/// and a NEVER list (SOS, Safe Journey, family alerts, anti-theft, CCTV,
/// vehicle, missing person, blood donor, train tracker, destination alarm,
/// My Circle chats + calls, AI chat, payment, credits, budget / money,
/// remittance, prepaid meter, vault, business khata / sales / invoice, CRM,
/// Quran, Ramadan, food calories + health, reminders, notes, task manager,
/// child accounts) where no ad API may be reachable at all
/// (test/ads_never_list_guard_test.dart).
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
    // the original calm list pages (owner 25 Oct). OWNER ADS FINAL (2 Nov):
    // NO ad on money / budget, reminders, notes / tasks, health, CRM,
    // business khata, prepaid meter or Ramadan pages any more.
    'saved_items', 'dictionary',
    // personal organiser (birthdays / meetings are not on the never list)
    'birthdays', 'meetings',
    // NOT documents: it is the PIN vault (owner: never on chat lock / vault)
    // work
    'jobs', 'cv_builder', 'contract',
    // discovery / info
    'all_services', 'guide', 'nearby', 'quick_tools', 'exam',
    // Photo Studio landing / picker (never while editing or exporting)
    'photo_gallery',
    // My Circle chat LIST only (Chats tab). The conversation screen, calls
    // tab, chat lock and vault keep NO ad (their keys hit the fence).
    'circle_list',
    // the plain Settings list (never account security / password /
    // delete-account / permission sub-pages)
    'settings',
  };

  /// Interstitial: the registered EXIT placements -> the screen they leave.
  static final Map<String, String> interstitialMoments = {
    for (final p in AdExitPlacement.values) p.id: p.screen,
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
    // OWNER ADS FINAL (2 Nov): no ad API reachable from any of these
    'cctv', 'vehicle', 'missing_person', 'blood_donor', 'train_tracker',
    'destination_alarm', 'ai_chat', 'assistant_chat', 'budget',
    'money', 'prepaid_meter', 'business_khata', 'khata', 'sales', 'invoice',
    'crm', 'quran', 'ramadan', 'food_calories', 'health', 'health_tips',
    'medicine_db', 'reminders', 'notes_todos', 'task_manager', 'tasks',
    'school_mode', 'kids_watch', 'child',
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

  /// Interstitial at the EXIT [moment] (an [AdExitPlacement.id]): Free user,
  /// server switch + placement on, not on the user's first day of use
  /// ([firstUseDay], local date), >= the gap (floor 800 s) since ANY
  /// full-screen ad, within the daily cap (max 4) and the placement's own
  /// daily cap (quick tools: once a day).
  static AdDecision interstitial(
    String moment,
    AdConfig cfg, {
    required bool loggedIn,
    required DateTime now,
    DateTime? lastFullScreenAt,
    int shownToday = 0,
    int shownTodayHere = 0,
    DateTime? firstUseDay,
  }) {
    if (!loggedIn) return const AdDecision(false, 'logged_out');
    if (cfg.paid || !cfg.adsEnabled) return const AdDecision(false, 'paid_plan');
    final m = moment.trim().toLowerCase();
    final placement = AdExitPlacement.byId(m);
    final screen = interstitialMoments[m];
    if (screen == null || !screenAllowed(AdSurface.interstitial, screen)) {
      return const AdDecision(false, 'moment_not_allowed');
    }
    if (!cfg.interstitialEnabled) return const AdDecision(false, 'disabled');
    if (!cfg.interstitialMoments.contains(m)) {
      return const AdDecision(false, 'server_off');
    }
    // never on the user's first day of use (local calendar day)
    final first = firstUseDay;
    if (first == null ||
        (first.year == now.year &&
            first.month == now.month &&
            first.day == now.day)) {
      return const AdDecision(false, 'first_day');
    }
    final gap = cfg.interstitialMinGap < AdRules.minInterstitialGap
        ? AdRules.minInterstitialGap
        : cfg.interstitialMinGap;
    if (lastFullScreenAt != null && now.difference(lastFullScreenAt) < gap) {
      return const AdDecision(false, 'too_soon');
    }
    final cap = cfg.interstitialDailyCap > AdRules.maxInterstitialsPerDay
        ? AdRules.maxInterstitialsPerDay
        : cfg.interstitialDailyCap;
    if (cap <= 0 || shownToday >= cap) {
      return const AdDecision(false, 'daily_cap');
    }
    final here = placement?.dailyMax ?? 0;
    if (here > 0 && shownTodayHere >= here) {
      return const AdDecision(false, 'placement_daily_cap');
    }
    return AdDecision.ok;
  }
}

/// OWNER ADS FINAL (2 Nov) — the ONE registry of interstitial placements.
///
/// An interstitial appears ONLY on the EXIT transition after a FINISHED task
/// (the user leaves the result), NEVER when the result appears:
///   1. the screen calls `AdExit.taskDone(AdExitPlacement.x)` when the task
///      finishes (saved / shared / downloaded / feedback shown ...) — this
///      NEVER shows anything;
///   2. it calls `AdExit.maybeShow(AdExitPlacement.x)` when the user LEAVES
///      that result (route pop / screen dispose / back to the list). Only a
///      leave that follows a finished task (within 30 min) can show an ad.
/// Global rules are in [AdPlacements.interstitial] (Free plan, consent gate,
/// max 4 a day, >= 800 s, none on the first day, accidental-tap guard).
/// A feature that is not built yet just calls these two lines when it is —
/// never add a placement for a never-list screen (the guard test fails).
enum AdExitPlacement {
  /// 1. Photo Studio — leaving the result after a save or share.
  photoAfterSave('photo_after_save', 'photo_studio'),

  /// 2. Document scanner + contract scanner — leaving after a save.
  scanAfterSave('scan_after_save', 'doc_scanner'),

  /// 3. CV Builder — leaving after the PDF download / print / share.
  cvAfterDownload('cv_after_download', 'cv_builder'),

  /// 4. Language Partner — leaving after a lesson, quiz or test.
  lessonAfterFinish('lesson_after_finish', 'language_partner'),

  /// 5. Mock interview — leaving after the feedback.
  interviewAfterFeedback('interview_after_feedback', 'mock_interview'),

  /// 6. Student corner — leaving after a practice / quiz / saved result.
  studentAfterPractice('student_after_practice', 'student_corner'),

  /// 7. Feed, Unseen World, Daily info — going back after reading an item.
  articleAfterRead('article_after_read', 'reading'),

  /// 8. Job Hunter — leaving after the apply confirmation.
  jobAfterApply('job_after_apply', 'jobs'),

  /// 9. Travel planner + Wedding & events — leaving after a save / export.
  planAfterSave('plan_after_save', 'planner'),

  /// 10. Cost & time estimator + Service guide — leaving after save / finish.
  estimateAfterFinish('estimate_after_finish', 'estimator'),

  /// 11. Quick tools — leaving a tool after using it; max ONCE a day.
  quickToolExit('quick_tool_exit', 'quick_tools', dailyMax: 1);

  const AdExitPlacement(this.id, this.screen, {this.dailyMax = 0});

  /// The id the server switches (`interstitial_moments`) and reports use.
  final String id;

  /// The screen key the placement leaves (checked against the fence).
  final String screen;

  /// Extra per-placement daily cap (0 = only the global cap).
  final int dailyMax;

  static AdExitPlacement? byId(String id) {
    for (final p in values) {
      if (p.id == id) return p;
    }
    return null;
  }
}

/// The exit-only interstitial hook (pure Dart; AdsService installs [sink]).
class AdExit {
  AdExit._();

  /// AdsService: decides and shows (consent gate, caps, Free plan ...).
  static void Function(AdExitPlacement p)? sink;

  /// A finished task waits at most this long for its exit.
  static const pendingFor = Duration(minutes: 30);

  static final Map<AdExitPlacement, DateTime> _done = {};

  /// The task of [p] FINISHED (result on screen). Never shows an ad.
  static void taskDone(AdExitPlacement p, [DateTime? at]) =>
      _done[p] = at ?? DateTime.now();

  /// The user is LEAVING the result of [p]. Hands the placement to [sink]
  /// only when a task finished before (and not too long ago); consumed, so
  /// one finished task = at most one ad. true = handed over. Never throws.
  static bool maybeShow(AdExitPlacement p, [DateTime? now]) {
    final at = _done.remove(p);
    if (at == null) return false;
    if ((now ?? DateTime.now()).difference(at) > pendingFor) return false;
    try {
      sink?.call(p);
    } catch (_) {
      // an ad problem never reaches the screen
    }
    return true;
  }

  static bool pending(AdExitPlacement p) => _done.containsKey(p);

  static void resetForTest() => _done.clear();
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
