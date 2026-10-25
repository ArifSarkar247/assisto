import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

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

  /// The request every bridge uses.
  static AdRequest request() => AdRequest(nonPersonalizedAds: !personalized);

  @visibleForTesting
  static void resetForTest() {
    _ready = false;
    _inFlight = null;
    personalized = false;
  }
}
