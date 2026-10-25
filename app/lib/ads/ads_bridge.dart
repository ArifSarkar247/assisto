/// Seam between Assisto's ad rules and the Google Mobile Ads SDK.
///
/// The real implementation is `admob_ads_bridge.dart` (google_mobile_ads),
/// bound in `ads_binding.dart` on Android; [NoopAdsBridge] (host tests, iOS)
/// serves nothing. NO reward is ever granted from this side: only Google's
/// signed SSV callback to the server credits anything.
enum RewardOutcome { earned, dismissed, unavailable }

abstract class AdsBridge {
  /// Initialise the SDK (lazy — first real need only). Never throws.
  Future<bool> init();

  /// Load + show an app-open ad. true if it was shown.
  Future<bool> showAppOpen(String unitId);

  /// Load + show a rewarded ad. [RewardOutcome.earned] only when the SDK
  /// reported the reward callback.
  Future<RewardOutcome> showRewarded(String unitId);

  /// p2-money: a rewarded ad carrying AdMob ServerSideVerificationOptions
  /// (userId + customData = the server ticket nonce). ONLY Google's signed
  /// SSV callback credits anything; [RewardOutcome.earned] alone never does.
  Future<RewardOutcome> showRewardedSsv(String unitId,
      {required String userId, required String customData});

  bool get linked;
}

/// admob (owner 25 Oct): interstitial at a natural break. Separate seam so
/// existing [AdsBridge] fakes stay valid. true only if it was really shown.
abstract class InterstitialBridge {
  bool get linked;
  Future<bool> showInterstitial(String unitId, {required String placement});
}

class NoopInterstitialBridge implements InterstitialBridge {
  const NoopInterstitialBridge();
  @override
  bool get linked => false;
  @override
  Future<bool> showInterstitial(String unitId, {required String placement}) async =>
      false;
}

class NoopAdsBridge implements AdsBridge {
  const NoopAdsBridge();
  @override
  Future<bool> init() async => false;
  @override
  Future<bool> showAppOpen(String unitId) async => false;
  @override
  Future<RewardOutcome> showRewarded(String unitId) async =>
      RewardOutcome.unavailable;
  @override
  Future<RewardOutcome> showRewardedSsv(String unitId,
          {required String userId, required String customData}) async =>
      RewardOutcome.unavailable;
  @override
  bool get linked => false;
}
