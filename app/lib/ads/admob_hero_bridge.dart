import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'ad_telemetry.dart';
import 'admob_sdk.dart';
import 'hero_ad.dart';

/// The home native card (h1 hero slot, BELOW the quick shortcuts) —
/// google_mobile_ads 9.1.0, the same lazy [AdmobSdk] init as every bridge.
///
/// * Rendered by AdMob's own Flutter NATIVE TEMPLATE, SMALL (owner feedback
///   27 Oct: compact, ~90-110 dp): square icon left, headline, Google's "Ad"
///   badge, one secondary line, CTA button, and the SDK-drawn AdChoices icon.
///   The small template has NO MediaView, so no large image / video on home.
///   Our [HeroAdFrame] adds the clear localized "Ad" label (h1AdLabel) and
///   the separate "Remove ads" link OUTSIDE the ad view.
/// * VideoOptions(startMuted) from the owner flag (default ON); the SDK
///   draws its own video controls (speaker toggle).
/// * Every SDK call is wrapped: a failure is null (= the normal logo block),
///   never a crash.
class AdmobHeroAdBridge implements HeroAdBridge {
  static const placement = 'home_native';

  @override
  bool get linked => true;

  @override
  Future<HeroAdHandle?> load(String unitId,
      {required bool startMuted,
      HeroAdLook? look,
      HeroAdSize size = HeroAdSize.compact}) async {
    if (unitId.isEmpty || !await AdmobSdk.ensureReady()) return null;
    final done = Completer<HeroAdHandle?>();
    NativeAd? ad;
    // one tracker per NativeAd object: 1 impression, <=1 click, 1 paid
    final tr = AdTelemetry.track(placement, 'native');
    try {
      ad = NativeAd(
        adUnitId: unitId,
        request: AdmobSdk.request(),
        nativeAdOptions: NativeAdOptions(
          adChoicesPlacement: AdChoicesPlacement.topRightCorner,
          mediaAspectRatio: size == HeroAdSize.compact
              ? MediaAspectRatio.square
              : MediaAspectRatio.landscape,
          videoOptions: VideoOptions(
            startMuted: startMuted,
            clickToExpandRequested: false,
            customControlsRequested: false,
          ),
        ),
        nativeTemplateStyle: heroTemplateStyle(look, size),
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
          onAdImpression: (_) {
            if (tr.impressed) return; // a repeat callback is not a new view
            // the device daily cap counts REAL impressions only
            unawaited(HeroDailyCap.recordImpression());
            tr.impression();
          },
          onAdClicked: (_) => tr.click(),
          onPaidEvent: (Ad _, double micros, PrecisionType p, String currency) =>
              tr.paid(
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

/// Google's OFFICIAL native template for the size — SMALL (compact) or
/// MEDIUM (large) — styled from the app theme ([HeroAdLook]). Every asset
/// (icon / media, headline, Ad badge, body, CTA) lives inside the SDK's
/// NativeAdView and the SDK draws AdChoices; nothing of ours is drawn over
/// it and there is no close button.
@visibleForTesting
NativeTemplateStyle heroTemplateStyle(HeroAdLook? look, HeroAdSize size) {
  final type =
      size == HeroAdSize.compact ? TemplateType.small : TemplateType.medium;
  if (look == null) {
    return NativeTemplateStyle(templateType: type, cornerRadius: 14);
  }
  NativeTemplateTextStyle text(Color c, double size,
          {Color? bg, NativeTemplateFontStyle? style}) =>
      NativeTemplateTextStyle(
          textColor: c,
          backgroundColor: bg ?? look.background,
          style: style ?? NativeTemplateFontStyle.normal,
          size: look.templateTextSize(size));
  return NativeTemplateStyle(
    templateType: type,
    cornerRadius: 14,
    mainBackgroundColor: look.background,
    primaryTextStyle:
        text(look.headline, 14, style: NativeTemplateFontStyle.bold),
    secondaryTextStyle: text(look.body, 12),
    tertiaryTextStyle: text(look.body, 12),
    callToActionTextStyle: text(look.ctaText, 13,
        bg: look.ctaBackground, style: NativeTemplateFontStyle.bold),
  );
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
