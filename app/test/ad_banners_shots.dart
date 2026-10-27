// banners-everywhere (owner 26 Oct): review shots of representative screens
// WITH the bottom banner (a stand-in for Google's 320x50 test ad) and the
// "Remove ads" link — Free user Rahim / রহিম, bn + en, light + dark — plus a
// never-list screen (Safe Journey settings) that must show no ad.
// Not part of the normal suite (no _test suffix). Run on demand:
//   ASSISTO_SHOT_DIR=<dir> flutter test test/ad_banners_shots.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/ads/ad_banner_slot.dart';
import 'package:assisto/ads/ad_placements.dart';
import 'package:assisto/ads/ad_rules.dart';

import 'screenshots_test.dart' show gallerySetUpAll, gallerySpecs, galleryPump;

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

void main() {
  final out = Platform.environment['ASSISTO_SHOT_DIR'] ??
      '/home/ubuntu/assisto/screenshots/banners';
  setUpAll(() async {
    await gallerySetUpAll();
    Directory(out).createSync(recursive: true);
  });
  setUp(() {
    BannerPacer.resetForTest();
    AdBannerSlot.debugBridge = _ShotBridge();
    AdBannerSlot.debugLoadConfig = () async => AdConfig.fromJson({
          'plan': 'free',
          'placements': {'banner': true},
          'banner_screens': AdPlacements.bannerScreens.toList(),
        });
  });
  tearDown(() {
    AdBannerSlot.debugBridge = null;
    AdBannerSlot.debugLoadConfig = null;
  });

  final specs = gallerySpecs();
  for (final name in ['reminders', 'money', 'messenger', 'settings', 'journey_settings']) {
    for (final lang in ['bn', 'en']) {
      for (final b in Brightness.values) {
        testWidgets('banner shot $name $lang ${b.name}', (tester) async {
          debugDisableShadows = false;
          final key = GlobalKey();
          await galleryPump(tester, name, lang, b, specs[name]!.build(lang),
              specs[name]!.mode, key: key);
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 80));
          }
          final shown = find.byKey(const ValueKey('ad-banner-slot')).evaluate().length;
          expect(shown, name == 'journey_settings' ? 0 : 1, reason: name);
          final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final image = await tester.runAsync(() => boundary.toImage(pixelRatio: 2.0)) as ui.Image;
          final bytes = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
          File('$out/banner_${name}_${lang}_${b.name}.png')
              .writeAsBytesSync(bytes!.buffer.asUint8List());
          image.dispose();
          debugDisableShadows = true;
        });
      }
    }
  }
}
