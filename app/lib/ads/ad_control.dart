/// adcontrol — the ONE ad PLACEMENT REGISTRY on the device (OWNER FINAL
/// ORDER ADS, 10 Nov 03:45, parts A–F). Pure Dart; unit-tested in
/// test/adcontrol_test.dart. A 1:1 mirror of backend
/// core/logic/ad_control.py PLACEMENTS (core.tests_adcontrol parses the
/// `AdSpot(...)` lines below — keep one per line).
///
/// Every place that may show an AdMob ad is one [AdSpot]: its key, feature
/// group, the ad types that FIT it, the default (owner order: part C OFF
/// list, part D ON list) and whether it is an emergency / safety / trust
/// screen. The owner switches each one on/off and picks its type in Owner
/// Admin -> Ad control; the app reads that from `/ads/config` -> `control`
/// on start and on every resume, so a change applies without a new build.
///
/// Rules:
///  * AdMob for FREE users only — Premium, Plus, Business ... never ([AdConfig.paid]).
///  * an unknown key never shows anything (default deny).
///  * a SAFETY spot shows an ad only when the server EXPLICITLY says on; no
///    config / a failed fetch = off.
///  * the owner's type must be one the spot allows, else nothing.
library;

import 'ad_rules.dart';

class AdSpot {
  const AdSpot(this.key, this.group, this.allowedCsv, this.defaultOn, this.defaultTypeId,
      {this.safety = false});

  final String key;
  final String group;
  final String allowedCsv;
  final bool defaultOn;
  final String defaultTypeId;
  final bool safety;

  Set<AdKind> get allowed =>
      allowedCsv.split(',').map(AdControl.kindOf).whereType<AdKind>().toSet();
  AdKind get defaultType => AdControl.kindOf(defaultTypeId)!;
}

/// One placement's live state from the server.
class AdSpotState {
  const AdSpotState(this.on, this.type);
  final bool on;
  final AdKind type;
}

/// `/ads/config` -> `control`, parsed defensively.
class AdControlState {
  const AdControlState({
    this.loaded = false,
    this.rows = const {},
    this.interstitialMinGapSec = 180,
    this.interstitialDailyCap = 6,
    this.listNativeEvery = 15,
    this.trainFreeMinutes = 15,
  });

  /// false: the server sent no `control` (an old server) — the device then
  /// keeps its earlier per-surface rules ([AdPlacements] legacy path).
  final bool loaded;
  final Map<String, AdSpotState> rows;
  final int interstitialMinGapSec;
  final int interstitialDailyCap;
  final int listNativeEvery;
  final int trainFreeMinutes;

  static const none = AdControlState();

  factory AdControlState.fromJson(dynamic j) {
    if (j is! Map) return none;
    final p = j['placements'];
    final rows = <String, AdSpotState>{};
    if (p is Map) {
      p.forEach((k, v) {
        if (v is! Map) return;
        final t = AdControl.kindOf('${v['type']}');
        if (t == null) return;
        rows['$k'.trim().toLowerCase()] = AdSpotState(v['on'] == true, t);
      });
    }
    final caps = j['caps'] is Map ? j['caps'] as Map : const {};
    int i(String k, int d, int lo, int hi) {
      final v = caps[k];
      final n = v is num ? v.toInt() : int.tryParse('$v') ?? d;
      return n.clamp(lo, hi);
    }

    return AdControlState(
      loaded: true,
      rows: rows,
      interstitialMinGapSec: i('interstitial_min_gap_sec', 180, 180, 86400),
      interstitialDailyCap: i('interstitial_daily_cap', 6, 0, AdRules.maxInterstitialsPerDay),
      listNativeEvery: i('list_native_every', 15, 15, 20),
      trainFreeMinutes: i('train_free_minutes', 15, 5, 120),
    );
  }
}

class AdControl {
  AdControl._();

  static const spots = <AdSpot>[
    AdSpot('home', 'home', 'native', true, 'native'),
    AdSpot('discover_native', 'home', 'native', true, 'native'),
    AdSpot('app_open', 'home', 'app_open', true, 'app_open'),
    AdSpot('all_services', 'home', 'banner,native', true, 'native'),
    AdSpot('circle_list', 'circle', 'banner,native', true, 'banner'),
    AdSpot('after_call_review', 'circle', 'banner,native', true, 'native'),
    AdSpot('ai_chat_unlock', 'ai', 'rewarded', true, 'rewarded'),
    // ai-reply-core: AI reply credits by rewarded ad (not a safety spot)
    AdSpot('ai_reply_unlock', 'ai', 'rewarded', true, 'rewarded'),
    AdSpot('photo_studio', 'photo', 'rewarded', true, 'rewarded'),
    AdSpot('photo_after_save', 'photo', 'interstitial', true, 'interstitial'),
    AdSpot('photo_gallery', 'photo', 'banner,native', true, 'banner'),
    AdSpot('lp_home', 'lp', 'banner,native', true, 'banner'),
    AdSpot('lp_hub', 'lp', 'banner,native', true, 'banner'),
    AdSpot('lp_life', 'lp', 'banner,native', true, 'banner'),
    AdSpot('lp_vocab', 'lp', 'banner,native', true, 'banner'),
    AdSpot('lesson_after_finish', 'lp', 'interstitial', true, 'interstitial'),
    AdSpot('lp_unlock', 'lp', 'rewarded', true, 'rewarded'),
    AdSpot('exam_after_submit', 'exam', 'interstitial', true, 'interstitial'),
    AdSpot('exam', 'exam', 'banner,native', true, 'banner'),
    AdSpot('student_after_practice', 'exam', 'interstitial', true, 'interstitial'),
    AdSpot('finance_home', 'finance', 'banner,native', true, 'native'),
    AdSpot('finance_list', 'finance', 'native', true, 'native'),
    AdSpot('finance_reports', 'finance', 'banner,native', true, 'native'),
    AdSpot('finance_after_export', 'finance', 'interstitial', true, 'interstitial'),
    AdSpot('finance_month_report', 'finance', 'interstitial', true, 'interstitial'),
    AdSpot('mess_home', 'mess', 'banner,native', true, 'banner'),
    AdSpot('mess_list', 'mess', 'native', true, 'native'),
    AdSpot('mess_month_report', 'mess', 'interstitial', true, 'interstitial'),
    AdSpot('notes_home', 'notes', 'banner,native', true, 'banner'),
    AdSpot('notes_list', 'notes', 'native', true, 'native'),
    AdSpot('reminders_list', 'notes', 'banner,native', true, 'banner'),
    AdSpot('city_search', 'city', 'banner,native', true, 'banner'),
    AdSpot('city_results', 'city', 'native', true, 'native'),
    AdSpot('city_more_routes', 'city', 'rewarded', true, 'rewarded'),
    AdSpot('nearby', 'city', 'banner,native', true, 'banner'),
    AdSpot('train_search', 'train', 'banner,native', true, 'banner'),
    AdSpot('train_detail', 'train', 'banner,native', true, 'banner'),
    AdSpot('train_live_unlock', 'train', 'rewarded', true, 'rewarded'),
    AdSpot('security_unlock', 'security', 'rewarded', true, 'rewarded'),
    AdSpot('security_scan', 'security', 'rewarded', true, 'rewarded'),
    AdSpot('offers_list', 'offers', 'native', true, 'native'),
    AdSpot('credits', 'offers', 'rewarded', true, 'rewarded'),
    AdSpot('saved_items', 'work', 'banner,native', true, 'banner'),
    AdSpot('dictionary', 'work', 'banner,native', true, 'banner'),
    AdSpot('birthdays', 'notes', 'banner,native', true, 'banner'),
    AdSpot('meetings', 'notes', 'banner,native', true, 'banner'),
    AdSpot('jobs', 'work', 'banner,native', true, 'banner'),
    AdSpot('cv_builder', 'work', 'banner,native', true, 'banner'),
    AdSpot('contract', 'work', 'banner,native', true, 'banner'),
    AdSpot('guide', 'work', 'banner,native', true, 'banner'),
    AdSpot('quick_tools', 'work', 'banner,native', true, 'banner'),
    AdSpot('settings', 'work', 'banner,native', true, 'banner'),
    AdSpot('scan_after_save', 'work', 'interstitial', true, 'interstitial'),
    AdSpot('cv_after_download', 'work', 'interstitial', true, 'interstitial'),
    AdSpot('interview_after_feedback', 'work', 'interstitial', true, 'interstitial'),
    AdSpot('article_after_read', 'home', 'interstitial', true, 'interstitial'),
    AdSpot('job_after_apply', 'work', 'interstitial', true, 'interstitial'),
    AdSpot('plan_after_save', 'work', 'interstitial', true, 'interstitial'),
    AdSpot('estimate_after_finish', 'work', 'interstitial', true, 'interstitial'),
    AdSpot('quick_tool_exit', 'work', 'interstitial', true, 'interstitial'),
    AdSpot('sos', 'safety', 'banner,native,interstitial', false, 'banner', safety: true),
    AdSpot('safe_journey_active', 'safety', 'banner,native,interstitial', false, 'banner', safety: true),
    AdSpot('family_care', 'safety', 'banner,native,interstitial', false, 'banner', safety: true),
    AdSpot('blood_donor', 'safety', 'banner,native,interstitial', false, 'banner', safety: true),
    AdSpot('care_call', 'safety', 'banner,native,interstitial', false, 'banner', safety: true),
    AdSpot('quran', 'safety', 'banner,native,interstitial', false, 'banner', safety: true),
    AdSpot('child_accounts', 'safety', 'banner,native,interstitial', false, 'banner', safety: true),
    AdSpot('chats_calls', 'safety', 'banner,native,interstitial', false, 'banner', safety: true),
    AdSpot('reminder_alarm', 'safety', 'banner,native,interstitial', false, 'banner', safety: true),
    AdSpot('lost_mode', 'safety', 'banner,native,interstitial', false, 'banner', safety: true),
    AdSpot('payment', 'safety', 'banner,native,interstitial', false, 'banner', safety: true),
    AdSpot('first_launch_login', 'safety', 'banner,native,interstitial,app_open', false, 'banner', safety: true),
    AdSpot('timed_test', 'safety', 'banner,native,interstitial', false, 'banner', safety: true),
    AdSpot('certificates', 'safety', 'banner,native,interstitial', false, 'banner', safety: true),
    AdSpot('finance_forms', 'safety', 'banner,native,interstitial', false, 'banner', safety: true),
    AdSpot('ai_chat_open', 'safety', 'banner,native', false, 'banner', safety: true),
    AdSpot('city_navigation', 'safety', 'banner,native,interstitial', false, 'banner', safety: true),
    AdSpot('train_family_watch', 'safety', 'banner,native,rewarded', false, 'banner', safety: true),
  ];

  static final Map<String, AdSpot> _byKey = {for (final s in spots) s.key: s};

  static AdSpot? spot(String key) => _byKey[key.trim().toLowerCase()];
  static bool isRegistered(String key) => spot(key) != null;

  static AdKind? kindOf(String id) => switch (id.trim().toLowerCase()) {
        'banner' => AdKind.banner,
        'native' => AdKind.native,
        'interstitial' => AdKind.interstitial,
        'rewarded' => AdKind.rewarded,
        'app_open' => AdKind.appOpen,
        _ => null,
      };

  /// The ad type to show at [key] right now, or null (no ad). Never throws.
  static AdKind? kindFor(String key, AdConfig cfg, {required bool loggedIn}) {
    if (!loggedIn || cfg.paid || !cfg.adsEnabled) return null;
    final s = spot(key);
    if (s == null) return null;
    final ctl = cfg.control;
    final row = ctl.rows[s.key];
    if (row == null) {
      // safety spots: only an explicit server "on" ever shows an ad
      if (s.safety || ctl.loaded) return null;
      return s.defaultOn ? s.defaultType : null;
    }
    if (!row.on) return null;
    return s.allowed.contains(row.type) ? row.type : null;
  }

  static AdDecision decide(String key, AdKind kind, AdConfig cfg,
      {required bool loggedIn}) {
    if (!loggedIn) return const AdDecision(false, 'logged_out');
    if (cfg.paid || !cfg.adsEnabled) return const AdDecision(false, 'paid_plan');
    if (spot(key) == null) return const AdDecision(false, 'not_registered');
    final k = kindFor(key, cfg, loggedIn: loggedIn);
    if (k == null) return const AdDecision(false, 'server_off');
    if (k != kind) return const AdDecision(false, 'other_type');
    return AdDecision.ok;
  }

  /// List native: which of [rowCount] rows get a native card AFTER them
  /// (indexes, 0-based) — one every [every] rows (15–20), never after the
  /// last row, never in a list shorter than [every].
  static List<int> listNativeAfter(int rowCount, int every) {
    final n = every.clamp(15, 20);
    final out = <int>[];
    for (var i = n - 1; i < rowCount - 1; i += n) {
      out.add(i);
    }
    return out;
  }

  /// Train live location: free for [minutes] after one rewarded ad.
  static bool trainWindowOpen(DateTime? lastAdAt, DateTime now, int minutes) =>
      lastAdAt != null && now.difference(lastAdAt) < Duration(minutes: minutes);
}
