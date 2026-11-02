import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'ad_rules.dart' show AdIds;
import 'consent.dart';

/// The ONE lazy Mobile Ads SDK init shared by every AdMob bridge (app-open,
/// rewarded, interstitial, banner, home native, Photo Studio).
///
/// STARTUP SAFETY (Realme/ColorOS launch crashes): the SDK's own
/// MobileAdsInitProvider is REMOVED from the manifest (android.yml), so
/// nothing of the SDK runs at process start. [ensureReady] is the first SDK
/// call and only happens right before an ad request — after the first
/// frame, for a Free user, and after Google UMP consent
/// ([AdConsent.allowsAds]). Every call is try/caught: a failure means "no
/// ad", never an error or a crash.
///
/// THE ONE CONSENT GATE (admobump, owner 2 Nov). Every file that loads an
/// AdMob ad must, in this order:
///   1. `AdmobSdk.unitAllowed(unitId)` — no real unit in a debug build;
///   2. `await AdmobSdk.ensureReady()` — UMP update + form + canRequestAds;
///   3. build its request ONLY with `AdmobSdk.request()` — which throws (=
///      no ad) unless the gate passed in this session, and asks for
///      non-personalised ads unless UMP says consent is not required.
/// test/ads_consent_gate_guard_test.dart fails CI if any file under lib/
/// creates an AdRequest, loads an ad, initialises the SDK or touches the
/// UMP APIs outside this path.
class AdmobSdk {
  AdmobSdk._();

  static bool _ready = false;
  static Future<bool>? _inFlight;

  /// Owner allows personalised ads (server `personalized`); UMP consent
  /// still decides per user. false = non-personalised requests only.
  static bool personalized = false;

  /// Completed by AdsService once the launch has settled (~8 s after the
  /// first frame). No consent call, no SDK init and no ad request before.
  static final Completer<void> _settled = Completer<void>();
  static void markLaunchSettled() {
    if (!_settled.isCompleted) _settled.complete();
  }

  static Future<bool> ensureReady() async {
    if (!_settled.isCompleted) {
      try {
        await _settled.future.timeout(const Duration(seconds: 30));
      } catch (_) {
        return false; // AdsService never started (e.g. signed out): no ad
      }
    }
    // Google UMP consent BEFORE MobileAds.initialize and any ad request.
    if (!await AdConsent.instance.allowsAds()) return false;
    if (_ready) return true;
    return _inFlight ??= _init().whenComplete(() => _inFlight = null);
  }

  static Future<bool> _init() async {
    try {
      await MobileAds.instance.initialize().timeout(const Duration(seconds: 15));
      try {
        // family app: no mature ad content; full-screen ads keep their sound
        await MobileAds.instance.updateRequestConfiguration(
            RequestConfiguration(maxAdContentRating: MaxAdContentRating.t));
        await MobileAds.instance.setAppMuted(false);
      } catch (_) {}
      _ready = true;
    } catch (e) {
      if (kDebugMode) debugPrint('MobileAds init failed: $e');
      _ready = false;
    }
    return _ready;
  }

  /// false = do not load [unitId] (a REAL unit in a debug/profile build, or
  /// empty). Google's public TEST units are always allowed.
  static bool unitAllowed(String unitId) {
    final u = unitId.trim();
    if (u.isEmpty) return false;
    return AdIds.realUnitsAllowed || AdIds.isTestId(u);
  }

  /// true when the next request would be personalised: the owner allows it
  /// (Owner Admin -> Ads) AND UMP says no consent is needed in this region.
  static bool get personalisedNow =>
      personalized && AdConsent.instance.mayPersonalise;

  /// The ONLY way to build an ad request. Throws [StateError] (every caller
  /// is inside a try -> "no ad") when the consent gate has not passed in
  /// this session — so an ad can never be requested before UMP.
  static AdRequest request() {
    if (!AdConsent.instance.canServe) {
      throw StateError('ad request before the UMP consent gate');
    }
    return AdRequest(nonPersonalizedAds: !personalisedNow);
  }

  @visibleForTesting
  static void resetForTest() {
    _ready = false;
    _inFlight = null;
    personalized = false;
  }
}
