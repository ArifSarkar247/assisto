/// HOME AD HERO (h1-home) — pure rules + the native-ad seam.
///
/// Owner order (HOME_AD_IMAGE_ORDER.md §2-3):
///  * Free users only: the home welcome block (logo + "Hi, I'm Assisto") is
///    REPLACED in the same slot by one large AdMob NATIVE ad (image or video)
///    with a clear "Ad" label. It never overlaps text, buttons or the input.
///  * Premium / Business: never. Never on safety screens (home only, and only
///    while home is the visible route).
///  * Collapses when the input gains focus or a chat starts.
///  * Refresh no faster than AdMob allows (>= 60 s; server `hero_refresh_sec`).
///  * No fill / offline / AdMob not linked -> the normal logo block.
///  * Only ONE AdMob ad on home at a time: while the hero shows an ad,
///    [HomeAdGuard.heroShowing] is true -> Discover drops its AdMob slot (and
///    asks the server with `hero_ad=1`, which also drops it).
///  * Sound: the hero video starts MUTED (admin flag `ad_rewards.hero_start_muted`,
///    default ON) and AdMob's own video controls show the speaker toggle.
///    Rewarded / interstitial / app-open play WITH sound (normal AdMob).
///
/// No google_mobile_ads import here (pure + testable): the real bridge is
/// `admob_hero_bridge.dart`, bound in `hero_binding.dart` on Android.
/// admob (owner 25 Oct): the slot sits BELOW the quick shortcuts (and far
/// from anything safety related) — home is otherwise unchanged.
///
/// Owner feedback 27 Oct (home v2, build 249): the home ad is now a COMPACT
/// native card (AdMob's SMALL template, ~90-110 dp: square icon left,
/// headline, Ad badge, one line, CTA, AdChoices; no large MediaView), with a
/// separate "Remove ads" link OUTSIDE the ad (opens Premium plans). It reloads
/// at most once per 60 s, only while home is visible and the app is in
/// front, and at most `native_daily_cap` (default 20) native impressions a
/// day on this device.
library;

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ad_rules.dart' show AdRules;

/// Google's public sample native-advanced units.
class HeroAdIds {
  HeroAdIds._();
  static const testNative = 'ca-app-pub-3940256099942544/2247696110';
  static const testNativeVideo = 'ca-app-pub-3940256099942544/1044960115';
}

/// AdMob's minimum refresh for one native slot.
const int kHeroMinRefreshSec = 60;

/// The home native card template (owner 27 Oct, server `home_native_size`).
enum HeroAdSize {
  /// AdMob SMALL template, 90-110 dp (default).
  compact,

  /// AdMob MEDIUM template with the media view (the earlier big card).
  large;

  /// Unknown / missing -> compact.
  static HeroAdSize parse(dynamic v) =>
      '${v ?? ''}'.trim().toLowerCase() == 'large' ? large : compact;
}

/// The owner's default native cap per day (pricing `native_daily_cap`).
const int kHeroDefaultDailyCap = 20;

/// Colours + text scale for the compact native template, taken from the app
/// theme by the widget (no colour literals in the ad bridge).
@immutable
class HeroAdLook {
  const HeroAdLook({
    required this.background,
    required this.headline,
    required this.body,
    required this.ctaBackground,
    required this.ctaText,
    this.textScale = 1.0,
  });
  final Color background;
  final Color headline;
  final Color body;
  final Color ctaBackground;
  final Color ctaText;

  /// The user's font scale. The native template's text is Android `sp`
  /// (already scaled by the system); see [templateTextSize].
  final double textScale;

  /// The SMALL template's rows are a fixed share of a 4:1 box, so its text
  /// may grow at most 1.3x (larger would be clipped inside the SDK view);
  /// our own label + Remove-ads row follow the full 200 %.
  double templateTextSize(double base) {
    final s = textScale <= 0 ? 1.0 : textScale;
    return base * (s < 1.3 ? s : 1.3) / s;
  }
}

/// The hero part of `GET /ads/config`, parsed defensively.
@immutable
class HeroAdConfig {
  const HeroAdConfig({
    this.enabled = false,
    this.startMuted = true,
    this.refreshSec = 90,
    this.nativeUnit = '',
    this.configured = false,
    this.appId = '',
    this.paid = false,
    this.dailyCap = kHeroDefaultDailyCap,
    this.size = HeroAdSize.compact,
  });

  final bool enabled;
  final bool startMuted;
  final int refreshSec;
  final String nativeUnit;
  final bool configured;
  final String appId;
  final bool paid;

  /// Max native impressions per local day on this device (server
  /// `native_daily_cap`, owner admin; default 20, 0 = no native ad).
  final int dailyCap;

  /// Server `home_native_size` (Owner Admin -> Ads): compact (default; also
  /// for an unknown value or no config yet) or large.
  final HeroAdSize size;

  static const none = HeroAdConfig();

  factory HeroAdConfig.fromJson(Map<String, dynamic>? j) {
    if (j == null) return none;
    String s(dynamic v) => v == null ? '' : '$v'.trim();
    final units = (j['units'] is Map) ? (j['units'] as Map) : const {};
    final plan = s(j['plan']).isEmpty ? 'free' : s(j['plan']);
    final paid = j['paid'] == true || plan != 'free';
    final r = j['hero_refresh_sec'];
    final refresh = r is num ? r.toInt() : int.tryParse('$r') ?? 90;
    final c = j['native_daily_cap'];
    final cap = c == null
        ? kHeroDefaultDailyCap
        : (c is num ? c.toInt() : int.tryParse('$c') ?? kHeroDefaultDailyCap);
    return HeroAdConfig(
      // the server already says false for paid plans; never trust only that
      enabled: j['hero_enabled'] == true && !paid,
      // default MUTED unless the owner explicitly switched it off
      startMuted: j['hero_start_muted'] != false,
      refreshSec: refresh < kHeroMinRefreshSec ? kHeroMinRefreshSec : refresh,
      nativeUnit: s(units['native']),
      configured: j['configured'] == true,
      appId: s(j['app_id']),
      paid: paid,
      dailyCap: cap.clamp(0, 50),
      size: HeroAdSize.parse(j['home_native_size']),
    );
  }

  /// REAL unit only when the server serves real ids (owner switch
  /// `admob_real_ids`) AND they belong to this APK's AdMob app; otherwise
  /// Google's TEST native unit (owner 25 Oct: ship with test ids).
  /// [testMode] is kept for old callers and no longer matters.
  String? unit({required String builtAppId, bool testMode = false}) {
    if (configured && nativeUnit.isNotEmpty && appId == builtAppId) {
      return nativeUnit;
    }
    return HeroAdIds.testNative;
  }
}

class HeroDecision {
  const HeroDecision(this.allowed, this.reason);
  final bool allowed;
  final String reason;
  static const ok = HeroDecision(true, 'ok');
  @override
  String toString() => 'HeroDecision($allowed, $reason)';
}

class HeroAdRules {
  HeroAdRules._();

  /// Below this height the ad would have to shrink or crowd the input; the
  /// normal logo block is shown instead (honest, policy-safe).
  static const double minSlotHeight = 240;

  /// The compact card: its ad box is [compactAdHeight] (90-110 dp) and the
  /// label / Remove-ads row sits above it; less room -> nothing.
  static const double compactMinRoom = 146;
  static const double compactAdMin = 90;
  static const double compactAdMax = 110;

  /// AdMob's SMALL template is a 4:1 box: width / 4, kept in 90-110 dp.
  static double compactAdHeight(double width) =>
      (width / 4).clamp(compactAdMin, compactAdMax).toDouble();

  static HeroDecision decide({
    required HeroAdConfig config,
    required String screen,
    required bool loggedIn,
    required bool collapsed,
    required bool chatStarted,
    required bool linked,
    required double slotHeight,
    double minHeight = minSlotHeight,
    bool capReached = false,
  }) {
    if (!loggedIn) return const HeroDecision(false, 'logged_out');
    if (config.paid) return const HeroDecision(false, 'paid_plan');
    if (!config.enabled) return const HeroDecision(false, 'disabled');
    // home only: safety / payment / call / any pushed screen -> never
    if (screen != 'home' || AdRules.isBlockedScreen(screen)) {
      return const HeroDecision(false, 'blocked_screen');
    }
    if (chatStarted) return const HeroDecision(false, 'chat_started');
    if (collapsed) return const HeroDecision(false, 'collapsed');
    if (!linked) return const HeroDecision(false, 'not_linked');
    if (slotHeight < minHeight) return const HeroDecision(false, 'no_room');
    if (capReached || config.dailyCap <= 0) {
      return const HeroDecision(false, 'daily_cap');
    }
    return HeroDecision.ok;
  }

  /// Seconds until the next reload: never below AdMob's 60 s.
  static Duration refreshEvery(HeroAdConfig c) => Duration(
      seconds: c.refreshSec < kHeroMinRefreshSec ? kHeroMinRefreshSec : c.refreshSec);
}

/// Sound rules for every ad format (owner order §3), applied by the bridges.
enum AdFormat { appOpen, rewarded, interstitial, heroNative }

class AdSound {
  AdSound._();

  /// Should this format START muted? Full-screen formats play with sound
  /// (normal AdMob behaviour, the app is never globally muted); the home hero
  /// native video starts muted unless the owner turned the flag off.
  static bool startMuted(AdFormat f, {bool heroStartMuted = true}) =>
      f == AdFormat.heroNative ? heroStartMuted : false;

  /// The app-level AdMob mute (MobileAds.setAppMuted) — always false, so
  /// full-screen ads keep their sound; the hero uses VideoOptions instead.
  static const bool appMuted = false;
}

/// One loaded native ad. [view] renders AdMob's own native template (it
/// carries the AdChoices icon, media view and — for video — the speaker
/// toggle). [dispose] must be called when the slot goes away.
abstract class HeroAdHandle {
  bool get hasVideo;
  Widget view();
  void dispose();
}

abstract class HeroAdBridge {
  bool get linked;

  /// Load one native ad. null on no fill / error / timeout — the caller shows
  /// the normal logo block. Never throws. [look] styles the compact template
  /// (null = the plugin's defaults).
  /// [size] picks the AdMob template (SMALL for compact, MEDIUM for large).
  Future<HeroAdHandle?> load(String unitId,
      {required bool startMuted,
      HeroAdLook? look,
      HeroAdSize size = HeroAdSize.compact});
}

class NoopHeroAdBridge implements HeroAdBridge {
  const NoopHeroAdBridge();
  @override
  bool get linked => false;
  @override
  Future<HeroAdHandle?> load(String unitId,
          {required bool startMuted,
          HeroAdLook? look,
          HeroAdSize size = HeroAdSize.compact}) async =>
      null;
}

/// The device-side half of the native daily cap: real SDK impressions of the
/// home native ad per local day (counted by the bridge's onAdImpression —
/// never on load, never twice). The server also counts every impression
/// (POST /ads/event) under the same `native_daily_cap`.
class HeroDailyCap {
  HeroDailyCap._();
  static const kDay = 'hero_native_day';
  static const kCount = 'hero_native_count';

  static String _day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static Future<int> today({DateTime? now}) async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getString(kDay) == _day(now ?? DateTime.now())
          ? (p.getInt(kCount) ?? 0)
          : 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<bool> reached(int cap, {DateTime? now}) async =>
      cap <= 0 || await today(now: now) >= cap;

  static Future<void> recordImpression({DateTime? now}) async {
    try {
      final p = await SharedPreferences.getInstance();
      final d = _day(now ?? DateTime.now());
      final n = p.getString(kDay) == d ? (p.getInt(kCount) ?? 0) : 0;
      await p.setString(kDay, d);
      await p.setInt(kCount, n + 1);
    } catch (_) {}
  }
}

/// Client half of "only one AdMob ad on home at a time".
class HomeAdGuard {
  HomeAdGuard._();
  static final ValueNotifier<bool> heroShowing = ValueNotifier<bool>(false);
}
