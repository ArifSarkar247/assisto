// cctvalerts (W3): gallery states for test/screenshots_test.dart (and the
// a11y + dead-button sweeps) — per-camera alert types.
import 'package:flutter/material.dart';

import 'package:assisto/screens/watchman/camera_alert_types.dart';

import 'cctvalerts_fakes.dart';

final Map<String, Widget Function(String)> cctvalertsShots = {
  'cxat_hikvision': (lang) => CameraAlertTypesScreen(
      cameraId: 5, cameraName: 'Shop door', source: FakeAlertTypes('hik', lang: lang)),
  'cxat_imou_sd_problem': (lang) => CameraAlertTypesScreen(
      cameraId: 6, cameraName: 'Gate (Imou)', source: FakeAlertTypes('imou', lang: lang)),
  'cxat_load_error': (lang) => CameraAlertTypesScreen(
      cameraId: 5, cameraName: 'Shop door', source: FakeAlertTypes('fail', lang: lang)),
};
