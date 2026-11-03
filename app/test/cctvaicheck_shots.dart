// cctvaicheck (W4 B3/B4): gallery states for test/screenshots_test.dart —
// the "AI দিয়ে যাচাই" switch and alert cards with the AI label.
import 'package:flutter/material.dart';

import 'package:assisto/screens/watchman/camera_alert_types.dart';
import 'package:assisto/screens/watchman/watchman_alerts.dart';

import 'cctvaicheck_fakes.dart';

final Map<String, Widget Function(String)> cctvaicheckShots = {
  'caic_switch_on': (lang) => CameraAlertTypesScreen(
      cameraId: 5, cameraName: 'Shop door', source: FakeAiAlertTypes('ready', lang: lang)),
  'caic_switch_nokey': (lang) => CameraAlertTypesScreen(
      cameraId: 5, cameraName: 'Shop door', source: FakeAiAlertTypes('nokey', lang: lang)),
  'caic_alert_labels': (lang) =>
      WatchmanAlertsScreen(source: FakeWatchmanAi(lang: lang), siteId: 1, owner: true),
};
