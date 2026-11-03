// p3farm: Farmer mode gallery states for test/screenshots_test.dart — the
// Help tab (big buttons), the per-crop calendar, and the disease check with
// and without a connected vision key.
import 'package:flutter/material.dart';

import 'package:assisto/screens/farmer/farmer_help.dart';
import 'package:assisto/screens/farmer_mode_screen.dart';

import 'world_fake.dart';

final Map<String, Widget Function(String)> p3farmShots = {
  'farm_help': (l) => FarmerModeScreen(worldApi: FakeWorldApi(lang: l)),
  'farm_calendar': (l) =>
      FarmerModeScreen(initialTab: 2, worldApi: FakeWorldApi(lang: l)),
  'farm_dz_picker': (l) => FarmDiseaseScreen(
      worldApi: FakeWorldApi(lang: l, photoReady: false),
      initialGroup: 'rice',
      initialProblem: 'rice_blast'),
  'farm_dz_photo': (l) => FarmDiseaseScreen(
      worldApi: FakeWorldApi(lang: l, photoReady: true)),
};
