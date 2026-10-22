// w1-webphoto gallery states for test/screenshots_test.dart: the website
// passport photo opened in Photo Studio (free, watermarked preview) and the
// honest expired-link state.
import 'package:flutter/material.dart';

import 'package:assisto/photo_studio/ps_controller.dart';
import 'package:assisto/screens/photo_studio_screen.dart';
import 'package:assisto/screens/web_photo_link_screen.dart';

import 'w1_webphoto_fakes.dart';

Widget _studio({bool free = true}) {
  final b = WebPsBackend(free: free);
  final c = PhotoStudioController(webDeps(b));
  c.init().then((_) async {
    final r = await FakeWebPhotoApi(b).claim('gallery-token');
    if (r.import != null) c.loadWebImport(r.import!);
  });
  return PhotoStudioScreen(controller: c);
}

/// name -> builder(lang). Wired into screenshots_test.dart `specs`.
final Map<String, Widget Function(String)> w1Shots = {
  'web_photo_studio_free': (_) => _studio(),
  'web_photo_studio_premium': (_) => _studio(free: false),
  'web_photo_link_expired': (_) {
    final b = WebPsBackend();
    return WebPhotoLinkScreen(
        token: 'gallery-token', api: FakeWebPhotoApi(b, status: 410), deps: webDeps(b));
  },
};
