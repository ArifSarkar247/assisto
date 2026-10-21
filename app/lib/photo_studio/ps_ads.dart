import '../ads/ads_bridge.dart' show RewardOutcome;

export '../ads/ads_bridge.dart' show RewardOutcome;

/// Photo Studio's ad seam (ps1-photo). Reuses the a6 [RewardOutcome]; adds
/// what the studio needs on top of the a6 bridge:
///  * an INTERSTITIAL for the studio entry, and
///  * a rewarded ad carrying AdMob ServerSideVerification options
///    (userId + customData = the server ticket nonce). Only Google's signed
///    SSV callback (`GET /ads/ssv`) can unlock anything — [RewardOutcome.earned]
///    alone never does.
///
/// AdMob is NOT linked in this build: [NoopPhotoAdBridge] shows nothing and
/// reports [RewardOutcome.unavailable], so free users see the honest
/// "ad couldn't load — try again or use credits" path; there is no bypass.
/// The real bridge (google_mobile_ads InterstitialAd + RewardedAd with
/// ServerSideVerificationOptions) is spelled out in
/// `.phaseB/proposals/ps1-photo.md` and binds in [createPhotoAdBridge].
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

PhotoAdBridge createPhotoAdBridge() => const NoopPhotoAdBridge();
