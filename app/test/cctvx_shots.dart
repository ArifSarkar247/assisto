// cctvx: gallery states for test/screenshots_test.dart (and the a11y +
// dead-button sweeps) — CCTV extras: guard settings, alert actions,
// placement helper, privacy kit, alerts passed to me, Smart Cash Guard with
// the extras card.
import 'package:flutter/material.dart';

import 'package:assisto/screens/watchman/cash_guard_screen.dart';
import 'package:assisto/screens/watchman/cctvx_actions.dart';
import 'package:assisto/screens/watchman/cctvx_guard_screen.dart';
import 'package:assisto/screens/watchman/cctvx_inbox.dart';
import 'package:assisto/screens/watchman/cctvx_placement.dart';
import 'package:assisto/screens/watchman/cctvx_privacy_kit.dart';

import 'cashguard_fakes.dart';
import 'cctvx_fakes.dart';

final Map<String, Widget Function(String)> cctvxShots = {
  'cx_guard_settings': (_) => GuardSettingsScreen(
      source: FakeCctvx(), siteId: 1, hours: const {'open': '09:00', 'close': '21:00'}),
  'cx_guard_settings_error': (_) => GuardSettingsScreen(source: FakeCctvx('fail'), siteId: 1),
  'cx_alert_actions': (_) => Scaffold(
      body: AlertActionsSheet(
          source: FakeCctvx(), eventId: 201, cash: FakeCashGuard(), preview: kFakeEventActions)),
  'cx_placement': (_) => Scaffold(
      body: PlacementSheet(source: FakeCctvx(), cameraId: 11, preview: kFakePlacementDark)),
  'cx_privacy_kit': (_) => PrivacyKitScreen(source: FakeCctvx(), siteId: 1, preview: kFakeKit),
  'cx_inbox': (_) => GuardInboxScreen(source: FakeCctvx(), cash: FakeCashGuard()),
  'cx_inbox_empty': (_) => GuardInboxScreen(source: FakeCctvx('empty'), cash: FakeCashGuard()),
  'cx_cash_guard_extras': (_) => CashGuardScreen(
      source: FakeCashGuard('business'), siteId: 1, extras: FakeCctvx(),
      cameras: const [{'id': 11, 'name': 'Till'}]),
};
