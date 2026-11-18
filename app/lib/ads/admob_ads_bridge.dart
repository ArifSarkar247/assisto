import 'dart:async';

import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'ad_placements.dart' show AdTouchGuard;
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

  /// onPaidEvent -> this ad instance's tracker (once per instance).
  static OnPaidEventCallback _paid(AdInstanceTracker tr) =>
      (Ad ad, double micros, PrecisionType p, String currency) => tr.paid(
          valueMicros: micros,
          currency: currency,
          precision: AdTelemetry.precisionName(p.name));

  // faststart (owner 10 Nov): the app-open ad is shown ONLY when it is
  // already loaded; otherwise this time is skipped and one is preloaded in
  // the background for a later resume. Never a load-then-show wait, never a
  // late surprise ad over a Home the user is already using.
  AppOpenAd? _appOpen;
  AdInstanceTracker? _appOpenTr; // ads-nine: the preload's tracker
  String? _appOpenUnit;
  DateTime? _appOpenAt;
  bool _appOpenLoading = false;

  /// Google: an app-open ad expires 4 h after it loaded.
  static const appOpenMaxAge = Duration(hours: 4);

  bool _appOpenFresh(String unitId) {
    final at = _appOpenAt;
    return _appOpen != null &&
        _appOpenUnit == unitId &&
        at != null &&
        DateTime.now().difference(at) < appOpenMaxAge;
  }

  void _dropAppOpen() {
    try {
      _appOpen?.dispose();
    } catch (_) {}
    _appOpen = null;
    _appOpenAt = null;
  }

  /// Background preload (never awaited by a show; never throws).
  Future<void> preloadAppOpen(String unitId) async {
    if (_appOpenLoading || _appOpenFresh(unitId)) return;
    if (!AdmobSdk.unitAllowed(unitId)) return;
    _appOpenLoading = true;
    try {
      if (!await init()) return;
      final tr = AdTelemetry.track('app_open', 'app_open');
      if (AdmobSdk.requestAllowed) tr.requested(); // ads-nine
      await AppOpenAd.load(
        adUnitId: unitId,
        request: AdmobSdk.request(),
        adLoadCallback: AppOpenAdLoadCallback(
          onAdLoaded: (ad) {
            _dropAppOpen();
            _appOpen = ad;
            _appOpenTr = tr;
            _appOpenUnit = unitId;
            _appOpenAt = DateTime.now();
            _appOpenLoading = false;
          },
          onAdFailedToLoad: (_) {
            tr.failed();
            _appOpenLoading = false;
          },
        ),
      );
    } catch (_) {
      _appOpenLoading = false;
    } finally {
      // the load call returns before the callback; a stuck flag must
      // never block every later preload
      unawaited(Future<void>.delayed(const Duration(seconds: 30),
          () => _appOpenLoading = false));
    }
  }

  @override
  Future<bool> showAppOpen(String unitId) async {
    if (!AdmobSdk.unitAllowed(unitId)) return false;
    if (!_appOpenFresh(unitId)) {
      if (_appOpen != null) _dropAppOpen(); // expired / other unit
      unawaited(preloadAppOpen(unitId)); // for a later resume
      return false; // not loaded -> skip this time
    }
    final ad = _appOpen!;
    _appOpen = null; // one show per ad object
    _appOpenAt = null;
    final done = Completer<bool>();
    // one tracker per ad object: 1 request, 1 impression, <=1 click, 1 paid
    final tr = _appOpenTr ?? AdTelemetry.track('app_open', 'app_open');
    _appOpenTr = null;
    try {
      ad.onPaidEvent = _paid(tr);
      ad.fullScreenContentCallback = FullScreenContentCallback(
        onAdShowedFullScreenContent: (_) {
          tr.impression();
          if (!done.isCompleted) done.complete(true);
        },
        onAdImpression: (_) => tr.impression(),
        onAdClicked: (_) => tr.click(),
        onAdDismissedFullScreenContent: (a) {
          a.dispose();
          unawaited(preloadAppOpen(unitId)); // ready for the next resume
        },
        onAdFailedToShowFullScreenContent: (a, _) {
          a.dispose();
          if (!done.isCompleted) done.complete(false);
        },
      );
      await ad.show();
    } catch (_) {
      if (!done.isCompleted) done.complete(false);
    }
    // a preloaded ad shows at once; a short box only for a stuck callback
    return done.future.timeout(const Duration(seconds: 3), onTimeout: () => false);
  }

  @override
  Future<bool> showInterstitial(String unitId, {required String placement}) async {
    if (!AdmobSdk.unitAllowed(unitId) || !await init()) return false;
    final done = Completer<bool>();
    final loadedFrom = DateTime.now();
    // one tracker per ad object: 1 request, 1 impression, <=1 click, 1 paid
    final tr = AdTelemetry.track(placement, 'interstitial');
    try {
      if (AdmobSdk.requestAllowed) tr.requested(); // ads-nine
      await InterstitialAd.load(
        adUnitId: unitId,
        request: AdmobSdk.request(),
        adLoadCallback: InterstitialAdLoadCallback(
          onAdLoaded: (ad) {
            if (done.isCompleted) {
              ad.dispose();
              return;
            }
            ad.onPaidEvent = _paid(tr);
            ad.fullScreenContentCallback = FullScreenContentCallback(
              onAdImpression: (_) => tr.impression(),
              onAdClicked: (_) => tr.click(),
              onAdShowedFullScreenContent: (_) {
                tr.impression();
                if (!done.isCompleted) done.complete(true);
              },
              onAdDismissedFullScreenContent: (a) => a.dispose(),
              onAdFailedToShowFullScreenContent: (a, _) {
                a.dispose();
                if (!done.isCompleted) done.complete(false);
              },
            );
            // never under a finger that is still tapping (accidental clicks)
            unawaited(_showWhenIdle(ad, done, loadedFrom));
          },
          onAdFailedToLoad: (_) {
            tr.failed();
            if (!done.isCompleted) done.complete(false);
          },
        ),
      );
    } catch (_) {
      tr.failed();
      if (!done.isCompleted) done.complete(false);
    }
    // a slow network must never surprise the user much later
    return done.future.timeout(const Duration(seconds: 6), onTimeout: () {
      tr.failed();
      if (!done.isCompleted) done.complete(false);
      return false;
    });
  }

  /// Shows [ad] once the screen has been untouched for [AdTouchGuard.quiet]
  /// (at most [AdTouchGuard.maxWait] after the moment); otherwise no ad.
  static Future<void> _showWhenIdle(
      InterstitialAd ad, Completer<bool> done, DateTime since) async {
    try {
      while (!done.isCompleted) {
        final wait = AdTouchGuard.waitFor(DateTime.now(), since);
        if (wait == null) break;
        if (wait == Duration.zero) {
          if (done.isCompleted) break; // timed out meanwhile: never late
          ad.show();
          // ads-nine: counted as shown NOW, so a slow onAdShowed callback
          // can never let the caps / gap be skipped
          done.complete(true);
          return;
        }
        await Future<void>.delayed(wait);
      }
    } catch (_) {}
    try {
      ad.dispose();
    } catch (_) {}
    if (!done.isCompleted) done.complete(false);
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
    if (!AdmobSdk.unitAllowed(unitId) || !await init()) {
      return RewardOutcome.unavailable;
    }
    final done = Completer<RewardOutcome>();
    var earned = false;
    // one tracker per ad object: 1 request, 1 impression, <=1 click, 1 paid
    final tr = AdTelemetry.track('rewarded_credits', 'rewarded');
    try {
      if (AdmobSdk.requestAllowed) tr.requested(); // ads-nine
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
            ad.onPaidEvent = _paid(tr);
            ad.fullScreenContentCallback = FullScreenContentCallback(
              onAdShowedFullScreenContent: (_) => tr.impression(),
              onAdImpression: (_) => tr.impression(),
              onAdClicked: (_) => tr.click(),
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
            tr.failed();
            if (!done.isCompleted) done.complete(RewardOutcome.unavailable);
          },
        ),
      );
    } catch (_) {
      tr.failed();
      if (!done.isCompleted) done.complete(RewardOutcome.unavailable);
    }
    return done.future
        .timeout(const Duration(minutes: 2), onTimeout: () => RewardOutcome.unavailable);
  }
}
