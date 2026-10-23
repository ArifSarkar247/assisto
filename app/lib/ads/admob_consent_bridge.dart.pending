import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'consent.dart';

/// L3 — google_mobile_ads (9.1.0) UMP-backed [ConsentBridge].
/// ConsentInformation / ConsentForm only; every call is wrapped so a consent
/// failure is "no ads", never a crash. Called lazily by [AdConsent] right
/// before the first ad request — never at launch.
class AdmobConsentBridge implements ConsentBridge {
  @override
  bool get linked => true;

  @override
  Future<bool> requestUpdate(
      {required bool debugEea, required List<String> testDeviceIds}) {
    final done = Completer<bool>();
    try {
      final params = ConsentRequestParameters(
        tagForUnderAgeOfConsent: false,
        consentDebugSettings: (debugEea || testDeviceIds.isNotEmpty)
            ? ConsentDebugSettings(
                debugGeography: debugEea
                    ? DebugGeography.debugGeographyEea
                    : DebugGeography.debugGeographyDisabled,
                testIdentifiers: testDeviceIds,
              )
            : null,
      );
      ConsentInformation.instance.requestConsentInfoUpdate(params, () {
        if (!done.isCompleted) done.complete(true);
      }, (FormError e) {
        if (kDebugMode) debugPrint('UMP update failed: ${e.message}');
        if (!done.isCompleted) done.complete(false);
      });
    } catch (e) {
      if (!done.isCompleted) done.complete(false);
    }
    return done.future;
  }

  @override
  Future<void> loadAndShowIfRequired() async {
    final done = Completer<void>();
    try {
      await ConsentForm.loadAndShowConsentFormIfRequired((FormError? e) {
        if (e != null && kDebugMode) debugPrint('UMP form: ${e.message}');
        if (!done.isCompleted) done.complete();
      });
    } catch (_) {
      if (!done.isCompleted) done.complete();
    }
    return done.future;
  }

  @override
  Future<bool> canRequestAds() async {
    try {
      return await ConsentInformation.instance.canRequestAds();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<PrivacyOptionsStatus> privacyOptionsStatus() async {
    try {
      final s =
          await ConsentInformation.instance.getPrivacyOptionsRequirementStatus();
      switch (s) {
        case PrivacyOptionsRequirementStatus.required:
          return PrivacyOptionsStatus.required;
        case PrivacyOptionsRequirementStatus.notRequired:
          return PrivacyOptionsStatus.notRequired;
        case PrivacyOptionsRequirementStatus.unknown:
          return PrivacyOptionsStatus.unknown;
      }
    } catch (_) {
      return PrivacyOptionsStatus.unknown;
    }
  }

  @override
  Future<bool> showPrivacyOptionsForm() async {
    final done = Completer<bool>();
    try {
      await ConsentForm.showPrivacyOptionsForm((FormError? e) {
        if (!done.isCompleted) done.complete(e == null);
      });
    } catch (_) {
      if (!done.isCompleted) done.complete(false);
    }
    return done.future;
  }
}
