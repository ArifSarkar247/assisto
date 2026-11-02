import 'dart:async';

import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../ads/ad_telemetry.dart';
import '../ads/admob_sdk.dart';
import '../ads/ads_service.dart';
import 'ps_ads.dart';

/// Photo Studio's AdMob bridge (admob, owner 25 Oct).
///
/// * Rewarded unlocks: a RewardedAd carrying ServerSideVerificationOptions
///   (userId + the server ticket nonce). Only Google's signed SSV callback to
///   our API unlocks anything — [RewardOutcome.earned] alone never does.
///   [linked] is true only while the server serves REAL unit ids with
///   rewarded on (Google's SSV never verifies a test unit, so on test ids
///   the "watch an ad" choice is not offered at all — no showpiece).
/// * NO entry interstitial: the owner allows interstitials only at natural
///   breaks (after a photo is saved — reported via AdMoments), never when a
///   screen opens. [showInterstitial] therefore never shows anything.
class AdmobPhotoAdBridge implements PhotoAdBridge {
  static const placement = 'rewarded_photo';

  @override
  bool get linked {
    try {
      return AdsService.instance.config.rewardedEnabled;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> showInterstitial(String unitId) async => false;

  @override
  Future<RewardOutcome> showRewardedSsv(String unitId,
      {required String userId, required String customData}) async {
    if (unitId.isEmpty || !linked || !await AdmobSdk.ensureReady()) {
      return RewardOutcome.unavailable;
    }
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
            try {
              await ad.setServerSideOptions(ServerSideVerificationOptions(
                  userId: userId, customData: customData));
            } catch (_) {}
            // one tracker per ad object: 1 impression, <=1 click, 1 paid
            final tr = AdTelemetry.track(placement, 'rewarded');
            ad.onPaidEvent = (Ad _, double micros, PrecisionType p, String cur) =>
                tr.paid(
                    valueMicros: micros,
                    currency: cur,
                    precision: AdTelemetry.precisionName(p.name));
            ad.fullScreenContentCallback = FullScreenContentCallback(
              onAdShowedFullScreenContent: (_) => tr.impression(),
              onAdImpression: (_) => tr.impression(),
              onAdClicked: (_) => tr.click(),
              onAdDismissedFullScreenContent: (a) {
                a.dispose();
                if (!done.isCompleted) {
                  done.complete(earned ? RewardOutcome.earned : RewardOutcome.dismissed);
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
    return done.future.timeout(const Duration(minutes: 2), onTimeout: () {
      if (!done.isCompleted) done.complete(RewardOutcome.unavailable);
      return RewardOutcome.unavailable;
    });
  }
}
