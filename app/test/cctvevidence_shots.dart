// cctvevidence (W7): gallery states for test/screenshots_test.dart (and the
// a11y + dead-button sweeps) — a camera's Recording & evidence screen (SD
// health, video add-on, evidence address) and the alert sheet's SD-clip row.
import 'package:flutter/material.dart';

import 'package:assisto/screens/watchman/cctv_recording_screen.dart';
import 'package:assisto/screens/watchman/cctvx_actions.dart';

import 'cashguard_fakes.dart';
import 'cctvevidence_fakes.dart';
import 'cctvx_fakes.dart';

Map<String, dynamic> _actionsWithSd(String status) => {
      ...kFakeEventActions,
      'actions': {
        ...Map<String, dynamic>.from(kFakeEventActions['actions'] as Map),
        'sd_clip': {
          'status': status,
          'url': status == 'ready' ? 'https://example.test/api/v1/m/shop/sdclip/e1.ts' : null,
          'expires_at': '2026-11-10T09:30:00+06:00',
          'reason_text': status == 'unsupported'
              ? "Imou's official API cannot download SD-card video — watch it in the Imou Life app."
              : null,
        },
      },
    };

final Map<String, Widget Function(String)> cctvevidenceShots = {
  'cev_recording': (_) =>
      CctvRecordingScreen(source: FakeCctvEvidence(), cameraId: 11, cameraName: 'Gate',
          preview: fakeRecording()),
  'cev_recording_addon_on': (_) => CctvRecordingScreen(
      source: FakeCctvEvidence(), cameraId: 11, cameraName: 'Gate',
      preview: fakeRecording(active: true, today: 12)),
  'cev_recording_imou': (_) => CctvRecordingScreen(
      source: FakeCctvEvidence('imou'), cameraId: 12, cameraName: 'Shop floor',
      preview: fakeRecording(
          sd: 'error', label: 'SD card error — replace or format it', days: null,
          supported: false,
          supportText:
              "Imou's official API cannot download SD-card video — watch it in the Imou Life app.")),
  'cev_recording_error': (_) =>
      CctvRecordingScreen(source: FakeCctvEvidence('fail'), cameraId: 11),
  'cev_alert_sd_ready': (_) => Scaffold(
      body: AlertActionsSheet(
          source: FakeCctvx(), eventId: 201, cash: FakeCashGuard(), preview: _actionsWithSd('ready'))),
  'cev_alert_sd_pending': (_) => Scaffold(
      body: AlertActionsSheet(
          source: FakeCctvx(), eventId: 201, cash: FakeCashGuard(),
          preview: _actionsWithSd('pending'))),
};
