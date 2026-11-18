// ads-nine (row 54): gallery shots — the honest "Why this ad?" sheet and a
// Free page with the bottom banner + the tappable "Ad (i)" label (bn + en).
// The banner is a stand-in for Google's 320x50 test ad (no SDK in tests).
import 'package:flutter/material.dart';

import 'package:assisto/ads/ad_banner_slot.dart';
import 'package:assisto/ads/ad_placements.dart';
import 'package:assisto/ads/ad_rules.dart';
import 'package:assisto/ads/ad_why_sheet.dart';

class _ShotHandle implements BannerAdHandle {
  @override
  double get height => 50;
  @override
  Widget view() => Container(
        color: const Color(0xFFECEFF1),
        alignment: Alignment.center,
        child: const Text('Test Ad · 320x50',
            style: TextStyle(color: Color(0xFF37474F), fontSize: 13)),
      );
  @override
  void dispose() {}
}

class _ShotBridge implements BannerBridge {
  @override
  bool get linked => true;
  @override
  Future<BannerAdHandle?> load(String unitId,
          {required double width, required String placement}) async =>
      _ShotHandle();
}

Future<AdConfig> _free() async => AdConfig.fromJson({
      'plan': 'free',
      'placements': {'banner': true},
      'banner_screens': AdPlacements.bannerScreens.toList(),
    });

final Map<String, Widget Function(String)> adsNineShots = {
  'ads_nine_why_sheet': (_) => Scaffold(
      body: SafeArea(child: AdWhySheet(personalised: false, onRemoveAds: () {}))),
  'ads_nine_banner_label': (lang) => Scaffold(
        appBar: AppBar(title: Text(lang == 'bn' ? 'অভিধান' : 'Dictionary')),
        body: ListView(children: [
          for (var i = 1; i <= 8; i++)
            ListTile(title: Text(lang == 'bn' ? 'শব্দ ${'০১২৩৪৫৬৭৮৯'[i]}' : 'Word $i')),
        ]),
        bottomNavigationBar: AdBannerSlot(
            screen: 'dictionary', bridge: _ShotBridge(), loadConfig: _free),
      ),
};
