// safeplans: gallery states for test/screenshots_test.dart — Safety plans
// (free guardian with the ads card, Safe Family active, not on sale) and the
// guardian-only ad unlock page.
import 'package:flutter/material.dart';

import 'package:assisto/safe_plans/safe_ad_unlock_screen.dart';
import 'package:assisto/safe_plans/safe_plans_screen.dart';

import 'safeplans_fakes.dart';

final Map<String, Widget Function(String)> safeplansShots = {
  'spl_free_guardian': (_) => SafePlansScreen(api: FakeSafeApi(safeStatus())),
  'spl_family_active': (_) =>
      SafePlansScreen(api: FakeSafeApi(safeStatus(plan: 'family', total: 112, adsOk: false, why: 'paid_plan'))),
  'spl_not_on_sale': (_) => SafePlansScreen(api: FakeSafeApi(safeStatus(onSale: false))),
  'spl_ad_unlock': (_) => SafeAdUnlockScreen(api: FakeSafeApi(safeStatus())),
};
