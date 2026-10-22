// tl1: gallery states for test/screenshots_test.dart — the OEM background
// guide on OPPO / Xiaomi / Samsung / vivo (first-run, tall "_bottom" shots so
// every step + the Done/Later buttons are visible), Samsung with battery
// already unrestricted, and a near-stock Walton phone that is all set.
import 'package:flutter/material.dart';

import 'package:assisto/screens/battery_guidance_screen.dart';

import 'tl1_fakes.dart';

Widget _guide(String phone, {bool? ignored = false, bool firstRun = true}) =>
    BatteryGuidanceScreen(
      firstRun: firstRun,
      native: FakeOemNative(tl1Phone(phone, ignored: ignored), avail: tl1Avail(phone)),
    );

final Map<String, Widget Function(String)> tl1Shots = {
  'oem_guide_oppo_bottom': (_) => _guide('oppo'),
  'oem_guide_xiaomi_bottom': (_) => _guide('xiaomi'),
  'oem_guide_samsung_bottom': (_) => _guide('samsung'),
  'oem_guide_vivo_bottom': (_) => _guide('vivo'),
  'oem_guide_samsung_done': (_) => _guide('samsung', ignored: true, firstRun: false),
  'oem_guide_walton_allset': (_) => _guide('walton', ignored: true, firstRun: false),
};
