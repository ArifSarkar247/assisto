import '../ads/ads_bridge.dart' show RewardOutcome;

export '../ads/ads_bridge.dart' show RewardOutcome;

import '../ads/admob_platform.dart';
import 'admob_photo_bridge.dart';

/// Photo Studio's ad seam (ps1-photo). Reuses the a6 [RewardOutcome]; adds
/// what the studio needs on top of the a6 bridge:
///  * an INTERSTITIAL for the studio entry, and
///  * a rewarded ad carrying AdMob ServerSideVerification options
///    (userId + customData = the server ticket nonce). Only Google's signed
///    SSV callback (`GET /ads/ssv`) can unlock anything — [RewardOutcome.earned]
///    alone never does.
///
/// admob (owner 25 Oct): the real bridge is `admob_photo_bridge.dart`
/// (RewardedAd + ServerSideVerificationOptions); it is "linked" only while
/// the server serves REAL unit ids with rewarded on, and it never shows an
/// entry interstitial (natural breaks only). [NoopPhotoAdBridge] (host tests,
/// iOS) shows nothing and reports [RewardOutcome.unavailable]; there is no
/// bypass either way.
abstract class PhotoAdBridge {
  bool get linked;

  /// Show the entry interstitial. true only if it was really shown.
  Future<bool> showInterstitial(String unitId);

  /// Show one rewarded ad tied to a server ticket.
  Future<RewardOutcome> showRewardedSsv(String unitId,
      {required String userId, required String customData});
}

class NoopPhotoAdBridge implements PhotoAdBridge {
  const NoopPhotoAdBridge();
  @override
  bool get linked => false;
  @override
  Future<bool> showInterstitial(String unitId) async => false;
  @override
  Future<RewardOutcome> showRewardedSsv(String unitId,
          {required String userId, required String customData}) async =>
      RewardOutcome.unavailable;
}

/// admob (owner 25 Oct): the real AdMob bridge on Android, no-op elsewhere.
PhotoAdBridge createPhotoAdBridge() =>
    admobSupported() ? AdmobPhotoAdBridge() : const NoopPhotoAdBridge();
