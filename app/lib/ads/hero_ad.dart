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
/// No google_mobile_ads import here: the real bridge lives in
/// `.phaseB/pending_native/h1/admob_hero_bridge.dart.pending` until the
/// pubspec/manifest part of the AdMob proposal is applied.
library;

import 'package:flutter/widgets.dart';

import 'ad_rules.dart' show AdRules;

/// Google's public sample native-advanced units.
class HeroAdIds {
  HeroAdIds._();
  static const testNative = 'ca-app-pub-3940256099942544/2247696110';
  static const testNativeVideo = 'ca-app-pub-3940256099942544/1044960115';
}

/// AdMob's minimum refresh for one native slot.
const int kHeroMinRefreshSec = 60;

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
  });

  final bool enabled;
  final bool startMuted;
  final int refreshSec;
  final String nativeUnit;
  final bool configured;
  final String appId;
  final bool paid;

  static const none = HeroAdConfig();

  factory HeroAdConfig.fromJson(Map<String, dynamic>? j) {
    if (j == null) return none;
    String s(dynamic v) => v == null ? '' : '$v'.trim();
    final units = (j['units'] is Map) ? (j['units'] as Map) : const {};
    final plan = s(j['plan']).isEmpty ? 'free' : s(j['plan']);
    final paid = j['paid'] == true || plan != 'free';
    final r = j['hero_refresh_sec'];
    final refresh = r is num ? r.toInt() : int.tryParse('$r') ?? 90;
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
    );
  }

  /// REAL unit only when the owner configured real ids AND this APK carries
  /// the same AdMob app id; otherwise Google's TEST unit in test mode; else
  /// null (nothing may be served).
  String? unit({required String builtAppId, required bool testMode}) {
    if (configured && nativeUnit.isNotEmpty && appId == builtAppId) {
      return nativeUnit;
    }
    return testMode ? HeroAdIds.testNative : null;
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

  static HeroDecision decide({
    required HeroAdConfig config,
    required String screen,
    required bool loggedIn,
    required bool collapsed,
    required bool chatStarted,
    required bool linked,
    required double slotHeight,
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
    if (slotHeight < minSlotHeight) return const HeroDecision(false, 'no_room');
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
  /// the normal logo block. Never throws.
  Future<HeroAdHandle?> load(String unitId, {required bool startMuted});
}

class NoopHeroAdBridge implements HeroAdBridge {
  const NoopHeroAdBridge();
  @override
  bool get linked => false;
  @override
  Future<HeroAdHandle?> load(String unitId, {required bool startMuted}) async =>
      null;
}

/// Client half of "only one AdMob ad on home at a time".
class HomeAdGuard {
  HomeAdGuard._();
  static final ValueNotifier<bool> heroShowing = ValueNotifier<bool>(false);
}
