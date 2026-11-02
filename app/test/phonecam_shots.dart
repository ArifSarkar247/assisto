// cctvphone: gallery states for test/screenshots_test.dart — an old phone
// as an Assisto camera (camera-phone screens + the owner's pairing sheet).
import 'package:flutter/material.dart';

import 'package:assisto/phonecam/phone_camera_screen.dart';
import 'package:assisto/phonecam/phonecam_pair_sheet.dart';
import 'package:assisto/screens/watchman/watchman_screen.dart' show PhoneCamHealthPill;

String _cam(String lang) => lang == 'bn' ? 'সামনের দরজা' : 'Front door';
String _site(String lang) => lang == 'bn' ? 'আমাদের বাসা' : 'Our home';

Future<Map<String, dynamic>> pcFakePair() async => {
      'code': '12-HK7P4Q',
      'link': 'https://lifeassisto.com/pc/12-HK7P4Q',
      'valid_s': 742,
      'included': 2,
      'used': 1,
      'extra_needs_credits': false,
      'extra_camera_credits': 250,
      'cameras': const [],
    };

final Map<String, Widget Function(String)> phonecamShots = {
  'pc_pair_code': (_) => const PhoneCameraScreen(preview: PhoneCamPreview(paired: false)),
  'pc_ready': (l) => PhoneCameraScreen(
      preview: PhoneCamPreview(camera: _cam(l), site: _site(l), clips: 4, clipMb: 38)),
  'pc_running': (l) => PhoneCameraScreen(
      preview: PhoneCamPreview(
          running: true, camera: _cam(l), site: _site(l), alerts: 3, clips: 4, clipMb: 38)),
  'pc_running_warn': (l) => PhoneCameraScreen(
      preview: PhoneCamPreview(
          running: true,
          camera: _cam(l),
          site: _site(l),
          model: false,
          audio: true,
          warnings: const ['unplugged', 'hot'])),
  'pc_pair_sheet': (_) => const Scaffold(body: PhoneCamPairSheet(load: pcFakePair)),
  'pc_health_pills': (_) => const Scaffold(
        body: Padding(
          padding: EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            PhoneCamHealthPill(health: {'level': 86, 'charging': true, 'temp_c': 33.0}),
            SizedBox(height: 8),
            PhoneCamHealthPill(health: {'level': 41, 'charging': false, 'temp_c': 47.5}),
            SizedBox(height: 8),
            PhoneCamHealthPill(health: {'level': 90, 'charging': true, 'dark': true}),
          ]),
        ),
      ),
};
