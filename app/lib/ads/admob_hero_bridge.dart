import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'ad_telemetry.dart';
import 'admob_sdk.dart';
import 'hero_ad.dart';

/// The home native card (h1 hero slot, BELOW the quick shortcuts) —
/// google_mobile_ads 9.1.0, the same lazy [AdmobSdk] init as every bridge.
///
/// * Rendered by AdMob's own Flutter NATIVE TEMPLATE (medium) — it carries
///   the AdChoices icon, Google's "Ad" attribution and the MediaView; our
///   [HeroAdFrame] adds the clear localized "Ad" label (h1AdLabel) above it.
/// * VideoOptions(startMuted) from the owner flag (default ON); the SDK
///   draws its own video controls (speaker toggle).
/// * Every SDK call is wrapped: a failure is null (= the normal logo block),
///   never a crash.
class AdmobHeroAdBridge implements HeroAdBridge {
  static const placement = 'home_native';

  @override
  bool get linked => true;

  @override
  Future<HeroAdHandle?> load(String unitId, {required bool startMuted}) async {
    if (unitId.isEmpty || !await AdmobSdk.ensureReady()) return null;
    final done = Completer<HeroAdHandle?>();
    NativeAd? ad;
    try {
      ad = NativeAd(
        adUnitId: unitId,
        request: AdmobSdk.request(),
        nativeAdOptions: NativeAdOptions(
          adChoicesPlacement: AdChoicesPlacement.topRightCorner,
          mediaAspectRatio: MediaAspectRatio.landscape,
          videoOptions: VideoOptions(
            startMuted: startMuted,
            clickToExpandRequested: false,
            customControlsRequested: false,
          ),
        ),
        nativeTemplateStyle: NativeTemplateStyle(
          templateType: TemplateType.medium,
          cornerRadius: 14,
        ),
        listener: NativeAdListener(
          onAdLoaded: (a) {
            if (done.isCompleted) {
              // too late: the slot already shows the logo block
              try {
                a.dispose();
              } catch (_) {}
              return;
            }
            done.complete(_Handle(a as NativeAd));
          },
          onAdFailedToLoad: (a, _) {
            try {
              a.dispose();
            } catch (_) {}
            if (!done.isCompleted) done.complete(null);
          },
          onAdImpression: (_) => AdTelemetry.impression(placement, 'native'),
          onAdClicked: (_) => AdTelemetry.click(placement, 'native'),
          onPaidEvent: (Ad _, double micros, PrecisionType p, String currency) =>
              AdTelemetry.paid(placement, 'native',
                  valueMicros: micros,
                  currency: currency,
                  precision: AdTelemetry.precisionName(p.name)),
        ),
      );
      await ad.load();
    } catch (_) {
      try {
        ad?.dispose();
      } catch (_) {}
      if (!done.isCompleted) done.complete(null);
    }
    return done.future.timeout(const Duration(seconds: 12), onTimeout: () {
      if (!done.isCompleted) done.complete(null);
      try {
        ad?.dispose();
      } catch (_) {}
      return null;
    });
  }
}

class _Handle implements HeroAdHandle {
  _Handle(this.ad);
  final NativeAd ad;

  // The Flutter plugin does not expose the media type; the SDK's own video
  // controls show the speaker whenever the creative is a video.
  @override
  bool get hasVideo => false;

  @override
  Widget view() => AdWidget(ad: ad);

  @override
  void dispose() {
    try {
      ad.dispose();
    } catch (_) {}
  }
}
