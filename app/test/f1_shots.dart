// f1-founders: gallery states for test/screenshots_test.dart — Founding
// Member badge (Settings, My Circle settings + profile) and the feedback
// sheet (with screenshot, removed, offline error, full-page fallback).
import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:assisto/feedback/feedback_sheet.dart';
import 'package:assisto/models.dart';
import 'package:assisto/photo_studio/ps_session.dart' show PngMeta;
import 'package:assisto/screens/messenger/messenger_profile_screen.dart';
import 'package:assisto/screens/messenger/messenger_settings_screen.dart';
import 'package:assisto/screens/settings_screen.dart';

/// A synthetic "phone screen" thumbnail (app bar + cards), PNG.
Uint8List f1FakeShot({int w = 90, int h = 180}) {
  final raw = BytesBuilder();
  for (var y = 0; y < h; y++) {
    raw.addByte(0);
    for (var x = 0; x < w; x++) {
      final bar = y < 22;
      final card = (y > 34 && y < 74) || (y > 84 && y < 124);
      final inset = x > 8 && x < w - 8;
      if (bar) {
        raw.add([59, 110, 246]);
      } else if (card && inset) {
        raw.add([236, 240, 250]);
      } else {
        raw.add([250, 250, 252]);
      }
    }
  }
  final idat = ZLibEncoder().convert(raw.toBytes());
  List<int> chunk(String t, List<int> d) {
    final type = t.codeUnits;
    final crc = PngMeta.crc32([...type, ...d]);
    int b(int v, int s) => (v >> s) & 0xFF;
    return [b(d.length, 24), b(d.length, 16), b(d.length, 8), b(d.length, 0),
      ...type, ...d, b(crc, 24), b(crc, 16), b(crc, 8), b(crc, 0)];
  }
  int be(int v, int s) => (v >> s) & 0xFF;
  final ihdr = [be(w, 24), be(w, 16), be(w, 8), be(w, 0), be(h, 24), be(h, 16),
    be(h, 8), be(h, 0), 8, 2, 0, 0, 0];
  return Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10,
    ...chunk('IHDR', ihdr), ...chunk('IDAT', idat), ...chunk('IEND', [])]);
}

/// The stub user turned into a Founding Member (gallery names 'fm_*').
AppUser f1Founder(AppUser u) => AppUser(
    id: u.id,
    name: u.name,
    phone: u.phone,
    email: u.email,
    autonomyLevel: u.autonomyLevel,
    language: u.language,
    isFounder: true,
    founderSince: '2026-10-22T10:00:00+06:00',
    founderPremiumUntil: '2027-10-22T10:00:00+06:00');

const _meta = FeedbackMeta(
    appVersion: '1.0.0',
    appBuild: '151',
    deviceModel: 'realme RMX3491',
    osVersion: 'Android 13',
    language: 'bn',
    route: 'money');

Widget _sheetLike(Widget child) => Builder(builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return Scaffold(
        backgroundColor: Colors.black54,
        body: Align(
          alignment: Alignment.bottomCenter,
          child: Material(
            color: scheme.surfaceContainerLow,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            child: SafeArea(
              top: false,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 16),
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2)),
                ),
                Flexible(child: child),
              ]),
            ),
          ),
        ),
      );
    });

FeedbackMeta _m(String lang) => FeedbackMeta(
    appVersion: _meta.appVersion,
    appBuild: _meta.appBuild,
    deviceModel: _meta.deviceModel,
    osVersion: _meta.osVersion,
    language: lang,
    route: _meta.route);

final Map<String, Widget Function(String)> f1Shots = {
  'fm_settings': (_) => const SettingsScreen(),
  'fm_msgr_settings': (_) => const MessengerSettingsScreen(),
  'fm_msgr_profile': (_) => const MessengerProfileScreen(),
  'fb_sheet': (l) => _sheetLike(
      FeedbackForm(meta: _m(l), screenshot: f1FakeShot(), asSheet: true)),
  'fb_sheet_error': (l) => _sheetLike(FeedbackForm(
      meta: _m(l), screenshot: f1FakeShot(), asSheet: true,
      debugStartOffline: true)),
  'fb_screen': (l) => const FeedbackScreen(route: 'home'),
};
