import 'dart:async';

import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'ad_telemetry.dart';
import 'admob_sdk.dart';
import 'ads_bridge.dart';

/// google_mobile_ads-backed [AdsBridge] + [InterstitialBridge] (app-open,
/// rewarded with SSV, interstitial). Every SDK call is wrapped and
/// time-boxed: an ads failure is "no ad", never a crash. The SDK starts only
/// in [AdmobSdk.ensureReady] (consent first) right before the first request.
/// Impressions, clicks and Google's onPaidEvent value go to [AdTelemetry].
class AdmobAdsBridge implements AdsBridge, InterstitialBridge {
  @override
  bool get linked => true;

  @override
  Future<bool> init() => AdmobSdk.ensureReady();

  static OnPaidEventCallback _paid(String placement, String format) =>
      (Ad ad, double micros, PrecisionType p, String currency) =>
          AdTelemetry.paid(placement, format,
              valueMicros: micros,
              currency: currency,
              precision: AdTelemetry.precisionName(p.name));

  @override
  Future<bool> showAppOpen(String unitId) async {
    if (unitId.isEmpty || !await init()) return false;
    final done = Completer<bool>();
    try {
      await AppOpenAd.load(
        adUnitId: unitId,
        request: AdmobSdk.request(),
        adLoadCallback: AppOpenAdLoadCallback(
          onAdLoaded: (ad) {
            // loaded after the time box: never show a late surprise ad
            if (done.isCompleted) {
              ad.dispose();
              return;
            }
            ad.onPaidEvent = _paid('app_open', 'app_open');
            ad.fullScreenContentCallback = FullScreenContentCallback(
              onAdShowedFullScreenContent: (_) {
                if (!done.isCompleted) done.complete(true);
              },
              onAdImpression: (_) => AdTelemetry.impression('app_open', 'app_open'),
              onAdClicked: (_) => AdTelemetry.click('app_open', 'app_open'),
              onAdDismissedFullScreenContent: (a) => a.dispose(),
              onAdFailedToShowFullScreenContent: (a, _) {
                a.dispose();
                if (!done.isCompleted) done.complete(false);
              },
            );
            try {
              ad.show();
            } catch (_) {
              if (!done.isCompleted) done.complete(false);
            }
          },
          onAdFailedToLoad: (_) {
            if (!done.isCompleted) done.complete(false);
          },
        ),
      );
    } catch (_) {
      if (!done.isCompleted) done.complete(false);
    }
    return done.future.timeout(const Duration(seconds: 8), onTimeout: () {
      if (!done.isCompleted) done.complete(false);
      return false;
    });
  }

  @override
  Future<bool> showInterstitial(String unitId, {required String placement}) async {
    if (unitId.isEmpty || !await init()) return false;
    final done = Completer<bool>();
    try {
      await InterstitialAd.load(
        adUnitId: unitId,
        request: AdmobSdk.request(),
        adLoadCallback: InterstitialAdLoadCallback(
          onAdLoaded: (ad) {
            if (done.isCompleted) {
              ad.dispose();
              return;
            }
            ad.onPaidEvent = _paid(placement, 'interstitial');
            ad.fullScreenContentCallback = FullScreenContentCallback(
              onAdImpression: (_) => AdTelemetry.impression(placement, 'interstitial'),
              onAdClicked: (_) => AdTelemetry.click(placement, 'interstitial'),
              onAdShowedFullScreenContent: (_) {
                if (!done.isCompleted) done.complete(true);
              },
              onAdDismissedFullScreenContent: (a) => a.dispose(),
              onAdFailedToShowFullScreenContent: (a, _) {
                a.dispose();
                if (!done.isCompleted) done.complete(false);
              },
            );
            try {
              ad.show();
            } catch (_) {
              if (!done.isCompleted) done.complete(false);
            }
          },
          onAdFailedToLoad: (_) {
            if (!done.isCompleted) done.complete(false);
          },
        ),
      );
    } catch (_) {
      if (!done.isCompleted) done.complete(false);
    }
    // a slow network must never surprise the user much later
    return done.future.timeout(const Duration(seconds: 6), onTimeout: () {
      if (!done.isCompleted) done.complete(false);
      return false;
    });
  }

  @override
  Future<RewardOutcome> showRewardedSsv(String unitId,
          {required String userId, required String customData}) =>
      _rewarded(unitId,
          ssv: ServerSideVerificationOptions(userId: userId, customData: customData));

  @override
  Future<RewardOutcome> showRewarded(String unitId) => _rewarded(unitId);

  Future<RewardOutcome> _rewarded(String unitId,
      {ServerSideVerificationOptions? ssv}) async {
    if (unitId.isEmpty || !await init()) return RewardOutcome.unavailable;
    final done = Completer<RewardOutcome>();
    var earned = false;
    try {
      await RewardedAd.load(
        adUnitId: unitId,
        request: AdmobSdk.request(),
        rewardedAdLoadCallback: RewardedAdLoadCallback(
          onAdLoaded: (ad) async {
            if (done.isCompleted) {
              ad.dispose();
              return;
            }
            if (ssv != null) {
              // userId + server nonce: only Google's signed callback to our
              // API can grant anything (never this device)
              try {
                await ad.setServerSideOptions(ssv);
              } catch (_) {}
            }
            ad.onPaidEvent = _paid('rewarded_credits', 'rewarded');
            ad.fullScreenContentCallback = FullScreenContentCallback(
              onAdImpression: (_) =>
                  AdTelemetry.impression('rewarded_credits', 'rewarded'),
              onAdClicked: (_) => AdTelemetry.click('rewarded_credits', 'rewarded'),
              onAdDismissedFullScreenContent: (a) {
                a.dispose();
                if (!done.isCompleted) {
                  done.complete(
                      earned ? RewardOutcome.earned : RewardOutcome.dismissed);
                }
              },
              onAdFailedToShowFullScreenContent: (a, _) {
                a.dispose();
                if (!done.isCompleted) done.complete(RewardOutcome.unavailable);
              },
            );
            try {
              ad.show(onUserEarnedReward: (_, __) => earned = true);
            } catch (_) {
              if (!done.isCompleted) done.complete(RewardOutcome.unavailable);
            }
          },
          onAdFailedToLoad: (_) {
            if (!done.isCompleted) done.complete(RewardOutcome.unavailable);
          },
        ),
      );
    } catch (_) {
      if (!done.isCompleted) done.complete(RewardOutcome.unavailable);
    }
    return done.future
        .timeout(const Duration(minutes: 2), onTimeout: () => RewardOutcome.unavailable);
  }
}
