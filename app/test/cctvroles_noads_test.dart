// cctvroles (CCTV Guard V3 L) — CI GUARD: no ad on ANY CCTV screen.
// 1) no CCTV source file may import the ads package or build an ad widget;
// 2) every CCTV screen key is refused by the ad fence for every surface,
//    even if the server ever listed it.
import 'dart:io';

import 'package:assisto/ads/ad_placements.dart';
import 'package:assisto/ads/ad_rules.dart';
import 'package:flutter_test/flutter_test.dart';

bool _isCctvFile(String p) {
  final s = p.replaceAll('\\', '/');
  final name = s.split('/').last;
  return s.contains('/cctv') ||
      s.contains('/watchman/') ||
      s.contains('/phonecam/') ||
      name.startsWith('shop_live') ||
      name.startsWith('shop_box') ||
      name.startsWith('shop_camera') ||
      name.startsWith('shop_eod') ||
      name.contains('installer');
}

void main() {
  test('no CCTV source file touches the ads package', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart') && _isCctvFile(f.path))
        .toList();
    expect(files.length, greaterThan(20), reason: 'the CCTV files were not found');
    final bad = RegExp(r"import\s+'[^']*ads/|AdBannerSlot|BannerAd\b|InterstitialAd\b|"
        r'RewardedAd\b|AppOpenAd\b|NativeAd\b|AdExitPlacement|showExitAd');
    final hits = <String>[];
    for (final f in files) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (bad.hasMatch(lines[i])) hits.add('${f.path}:${i + 1}: ${lines[i].trim()}');
      }
    }
    expect(hits, isEmpty, reason: 'ads on a CCTV screen:\n${hits.join('\n')}');
  });

  test('every CCTV screen key is fenced for every ad surface', () {
    const keys = [
      'cctv', 'cctv_grid', 'cctv_team', 'cctv_partner', 'cctv_installer',
      'watchman', 'watchman_alerts', 'watchman_setup', 'watchman_zones',
      'shop_live', 'shop_box', 'shop_box_mode', 'shop_camera_settings',
      'shop_eod', 'guard_box', 'cash_guard', 'auto_guard', 'installer',
      'phonecam', 'camera_alerts', 'cctv_privacy_kit', 'cctv_access_log',
    ];
    for (final k in keys) {
      expect(AdRules.isBlockedScreen(k), isTrue, reason: k);
      for (final slot in AdSurface.values) {
        expect(AdPlacements.screenAllowed(slot, k), isFalse, reason: '$slot $k');
      }
    }
  });
}
