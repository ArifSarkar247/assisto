import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'ad_banner_slot.dart';
import 'ad_telemetry.dart';
import 'admob_sdk.dart';

/// google_mobile_ads banner for [AdBannerSlot] (anchored adaptive size,
/// falls back to the standard 320x50). Lazy [AdmobSdk] init; every call
/// wrapped; a failure is null (the slot takes no space).
class AdmobBannerBridge implements BannerBridge {
  @override
  bool get linked => true;

  @override
  Future<BannerAdHandle?> load(String unitId,
      {required double width, required String placement}) async {
    if (unitId.isEmpty || !await AdmobSdk.ensureReady()) return null;
    AdSize size = AdSize.banner;
    try {
      // the standard (not "large") anchored height keeps the list readable
      // ignore: deprecated_member_use
      final a = await AdSize.getAnchoredAdaptiveBannerAdSize(
          Orientation.portrait, width.truncate());
      if (a != null) size = a;
    } catch (_) {}
    final done = Completer<BannerAdHandle?>();
    BannerAd? ad;
    try {
      ad = BannerAd(
        size: size,
        adUnitId: unitId,
        request: AdmobSdk.request(),
        listener: BannerAdListener(
          onAdLoaded: (a) {
            if (done.isCompleted) {
              a.dispose();
              return;
            }
            done.complete(_Handle(a as BannerAd, size.height.toDouble()));
          },
          onAdFailedToLoad: (a, _) {
            a.dispose();
            if (!done.isCompleted) done.complete(null);
          },
          onAdImpression: (_) => AdTelemetry.impression(placement, 'banner'),
          onAdClicked: (_) => AdTelemetry.click(placement, 'banner'),
          onPaidEvent: (Ad _, double micros, PrecisionType p, String currency) =>
              AdTelemetry.paid(placement, 'banner',
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

class _Handle implements BannerAdHandle {
  _Handle(this.ad, this.height);
  final BannerAd ad;
  @override
  final double height;

  @override
  Widget view() => AdWidget(ad: ad);

  @override
  void dispose() {
    try {
      ad.dispose();
    } catch (_) {}
  }
}
