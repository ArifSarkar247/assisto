// admobump (owner 2 Nov) — CI GUARD: every AdMob ad request goes through
// the ONE consent gate (lib/ads/consent.dart + lib/ads/admob_sdk.dart).
//
// Fails when any file under lib/:
//  * builds an AdRequest / AdManagerAdRequest outside admob_sdk.dart;
//  * initialises / configures the Mobile Ads SDK outside admob_sdk.dart;
//  * touches Google UMP (ConsentInformation / ConsentForm) outside
//    admob_consent_bridge.dart;
//  * loads an ad (AppOpenAd / InterstitialAd / RewardedAd /
//    RewardedInterstitialAd .load, BannerAd / NativeAd / AdManager* ctor)
//    without `AdmobSdk.unitAllowed(`, `AdmobSdk.ensureReady()` and one
//    `request: AdmobSdk.request()` per load;
//  * imports google_mobile_ads and is not a reviewed bridge file (a new
//    file must be added to [_reviewed] on purpose, after review).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _reviewed = {
  'lib/ads/admob_sdk.dart',
  'lib/ads/admob_consent_bridge.dart',
  'lib/ads/admob_ads_bridge.dart',
  'lib/ads/admob_banner_bridge.dart',
  'lib/ads/admob_hero_bridge.dart',
  'lib/photo_studio/admob_photo_bridge.dart',
};

/// The source without comments (so doc comments may name the APIs).
String _code(String src) => src
    .split('\n')
    .map((l) {
      final t = l.trimLeft();
      if (t.startsWith('//')) return '';
      final i = l.indexOf(' // ');
      return i >= 0 ? l.substring(0, i) : l;
    })
    .join('\n');

Map<String, String> _libFiles() {
  final out = <String, String>{};
  for (final e in Directory('lib').listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    final rel = e.path.replaceAll('\\', '/');
    out[rel.startsWith('./') ? rel.substring(2) : rel] =
        _code(e.readAsStringSync());
  }
  return out;
}

final _adRequest = RegExp(r'\b(AdRequest|AdManagerAdRequest)\s*\(');
final _sdk = RegExp(r'\bMobileAds\s*\.\s*instance\b');
final _ump = RegExp(r'\b(ConsentInformation|ConsentForm)\s*\.');
final _load = RegExp(
    r'\b(AppOpenAd|InterstitialAd|RewardedAd|RewardedInterstitialAd|AdManagerInterstitialAd)\s*\.\s*load\s*\(|'
    r'\b(BannerAd|NativeAd|AdManagerBannerAd)\s*\(');
final _gmaImport = RegExp(r"^import 'package:google_mobile_ads/", multiLine: true);

void main() {
  final files = _libFiles();

  test('the scan sees the app sources (guard is not vacuous)', () {
    expect(files.length, greaterThan(100));
    for (final f in _reviewed) {
      expect(files.containsKey(f), isTrue, reason: '$f moved? update the guard');
    }
  });

  test('only reviewed bridge files import google_mobile_ads', () {
    final bad = [
      for (final e in files.entries)
        if (_gmaImport.hasMatch(e.value) && !_reviewed.contains(e.key)) e.key
    ];
    expect(bad, isEmpty,
        reason: 'new AdMob code must go through AdmobSdk (the consent gate) '
            'and be added to the reviewed list in this test');
  });

  test('AdRequest is built ONLY by AdmobSdk.request()', () {
    final bad = [
      for (final e in files.entries)
        if (_adRequest.hasMatch(e.value) && e.key != 'lib/ads/admob_sdk.dart')
          e.key
    ];
    expect(bad, isEmpty);
    expect(_adRequest.allMatches(files['lib/ads/admob_sdk.dart']!).length, 1);
    // ...and that one refuses before consent
    expect(files['lib/ads/admob_sdk.dart'],
        contains('if (!AdConsent.instance.canServe)'));
  });

  test('the Mobile Ads SDK is started only in admob_sdk.dart, after UMP', () {
    final bad = [
      for (final e in files.entries)
        if (_sdk.hasMatch(e.value) && e.key != 'lib/ads/admob_sdk.dart') e.key
    ];
    expect(bad, isEmpty);
    final sdk = files['lib/ads/admob_sdk.dart']!;
    final gate = sdk.indexOf('AdConsent.instance.allowsAds()');
    final init = sdk.indexOf('MobileAds.instance.initialize()');
    expect(gate, greaterThan(0));
    expect(init, greaterThan(0));
    // ensureReady() asks UMP before _init() can ever run
    expect(sdk.indexOf('_init()'), greaterThan(gate));
  });

  test('Google UMP is touched only by admob_consent_bridge.dart', () {
    final bad = [
      for (final e in files.entries)
        if (_ump.hasMatch(e.value) &&
            e.key != 'lib/ads/admob_consent_bridge.dart')
          e.key
    ];
    expect(bad, isEmpty);
  });

  test('every ad load goes through the gate', () {
    var loads = 0;
    for (final e in files.entries) {
      final n = _load.allMatches(e.value).length;
      if (n == 0) continue;
      loads += n;
      final src = e.value;
      expect(_reviewed.contains(e.key), isTrue, reason: e.key);
      expect(src, contains('AdmobSdk.unitAllowed('), reason: e.key);
      expect(src, contains('AdmobSdk.ensureReady()'), reason: e.key);
      expect('request: AdmobSdk.request()'.allMatches(src).length, n,
          reason: '${e.key}: every load must use AdmobSdk.request()');
    }
    // app-open, interstitial, 2x rewarded, banner, native = 6 today
    expect(loads, greaterThanOrEqualTo(6));
  });
}
