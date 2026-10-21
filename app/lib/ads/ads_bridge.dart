/// Seam between Assisto's ad rules and the Google Mobile Ads SDK.
///
/// The real implementation is `admob_ads_bridge.dart.pending` (needs the
/// google_mobile_ads pubspec entry + manifest APPLICATION_ID from
/// `.phaseB/proposals/a6-leftovers-admob.md`). Until it is bound in
/// `ads_binding.dart`, [NoopAdsBridge] serves nothing — the rewarded sheet
/// shows its honest "ads not set up" state and NO reward is ever granted
/// without a real, completed ad.
enum RewardOutcome { earned, dismissed, unavailable }

abstract class AdsBridge {
  /// Initialise the SDK (lazy — first real need only). Never throws.
  Future<bool> init();

  /// Load + show an app-open ad. true if it was shown.
  Future<bool> showAppOpen(String unitId);

  /// Load + show a rewarded ad. [RewardOutcome.earned] only when the SDK
  /// reported the reward callback.
  Future<RewardOutcome> showRewarded(String unitId);

  bool get linked;
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
  bool get linked => false;
}
