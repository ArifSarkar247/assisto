// cashguard: gallery states for test/screenshots_test.dart (and the a11y +
// dead-button sweeps) — Smart Cash Guard, the clip player and Guard Box.
import 'package:flutter/material.dart';

import 'package:assisto/screens/watchman/cash_guard_clip.dart';
import 'package:assisto/screens/watchman/cash_guard_screen.dart';
import 'package:assisto/screens/watchman/guard_box_screen.dart';
import 'package:assisto/screens/watchman/watchman_alerts.dart';

import 'cashguard_fakes.dart';

final Map<String, Widget Function(String)> cashguardShots = {
  'cg_overview_free': (_) => CashGuardScreen(source: FakeCashGuard('free'), siteId: 1),
  'cg_overview_away': (_) => CashGuardScreen(source: FakeCashGuard('away'), siteId: 1),
  'cg_overview_business': (_) => CashGuardScreen(source: FakeCashGuard('business'), siteId: 1),
  'cg_overview_error': (_) => CashGuardScreen(source: FakeCashGuard('fail'), siteId: 1),
  'cg_alerts_cash': (_) => WatchmanAlertsScreen(
      source: FakeWatchmanCash(), siteId: 1, owner: true, cash: FakeCashGuard()),
  'cg_clip_player': (_) => Scaffold(
      body: CashClipSheet(
          source: FakeCashGuard(), eventId: 201, owner: true,
          preview: cashClipPreview([kTinyPng, kTinyPng, kTinyPng, kTinyPng], fps: 2))),
  'gb_setup': (_) => const GuardBoxScreen(
      force: true, preview: GuardBoxPreview(paired: false, running: false)),
  'gb_running': (_) => const GuardBoxScreen(
      force: true,
      preview: GuardBoxPreview(site: 'Mirpur shop', camera: 'Cash counter', stats: {
        'frames': 1240, 'avg_frame_ms': 38.0, 'events': 2, 'clips_sent': 2, 'detector': 'motion_only'})),
};
