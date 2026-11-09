// cctvbox: gallery states for test/screenshots_test.dart — Guard Box for IP
// cameras without a PC (an old phone pulls the camera's RTSP stream).
import 'package:flutter/material.dart';

import 'package:assisto/ipcam/ipcam_guard_screen.dart';

String _cam(String lang) => lang == 'bn' ? 'দোকানের ক্যামেরা' : 'Shop camera';
String _site(String lang) => lang == 'bn' ? 'আমাদের দোকান' : 'Our shop';

final Map<String, Widget Function(String)> ipcamShots = {
  'icg_pair': (_) => const IpCamGuardScreen(force: true, preview: IpCamPreview(paired: false)),
  'icg_camera': (l) => IpCamGuardScreen(
      force: true, preview: IpCamPreview(camera: _cam(l), site: _site(l), brand: 'imou')),
  'icg_tested': (l) => IpCamGuardScreen(
      force: true, preview: IpCamPreview(camera: _cam(l), site: _site(l), tested: true)),
  'icg_running': (l) => IpCamGuardScreen(
      force: true,
      preview: IpCamPreview(camera: _cam(l), site: _site(l), tested: true, running: true, alerts: 2)),
  'icg_running_lost': (l) => IpCamGuardScreen(
      force: true,
      preview: IpCamPreview(
          camera: _cam(l), site: _site(l), tested: true, running: true, camLost: true, lowPower: true,
          model: false)),
};
