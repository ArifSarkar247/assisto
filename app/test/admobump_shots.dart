// admobump (owner 2 Nov): gallery states for test/screenshots_test.dart —
// Settings -> "বিজ্ঞাপনের গোপনীয়তা / Ads privacy": the tappable row where
// Google UMP says the privacy options are REQUIRED (EEA / US states), and the
// honest non-tappable line where they are not (e.g. Bangladesh).
import 'package:flutter/material.dart';

import 'package:assisto/ads/ad_privacy_tile.dart';
import 'package:assisto/ads/consent.dart';
import 'package:assisto/l10n/app_localizations.dart';

class _ShotUmp implements ConsentBridge {
  const _ShotUmp(this.required);
  final bool required;
  @override
  bool get linked => true;
  @override
  Future<bool> requestUpdate(
          {required bool debugEea, required List<String> testDeviceIds}) async =>
      true;
  @override
  Future<void> loadAndShowIfRequired() async {}
  @override
  Future<bool> canRequestAds() async => true;
  @override
  Future<PrivacyOptionsStatus> privacyOptionsStatus() async => required
      ? PrivacyOptionsStatus.required
      : PrivacyOptionsStatus.notRequired;
  @override
  Future<UmpConsentStatus> consentStatus() async => required
      ? UmpConsentStatus.obtained
      : UmpConsentStatus.notRequired;
  @override
  Future<bool> showPrivacyOptionsForm() async => true;
}

/// Called by galleryPrime for every shot: only admobump_* shots get a live
/// consent flow; every other shot keeps the inactive default.
void admobumpPrime(String name) {
  if (!name.startsWith('admobump_')) {
    AdConsent.instance.resetForTest();
    return;
  }
  final required = name == 'admobump_ads_privacy_required';
  AdConsent.instance.resetForTest(
      appId: 'ca-app-pub-1111111111111111~2222222222', // made-up, shape-valid
      bridge: _ShotUmp(required));
  AdConsent.instance.privacyStatus.value = required
      ? PrivacyOptionsStatus.required
      : PrivacyOptionsStatus.notRequired;
}

Widget _settingsLike() => Builder(builder: (context) {
      final t = AppLocalizations.of(context);
      return Scaffold(
        appBar: AppBar(title: Text(t.settingsTitle)),
        body: ListView(children: [
          ListTile(
            leading: const Icon(Icons.gavel_rounded),
            title: Text(t.legalTitle),
          ),
          const AdPrivacyTile(),
          const Divider(),
        ]),
      );
    });

final Map<String, Widget Function(String)> admobumpShots = {
  'admobump_ads_privacy_required': (_) => _settingsLike(),
  'admobump_ads_privacy_not_required': (_) => _settingsLike(),
};
