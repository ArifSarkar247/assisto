// cctvactivity (W10): gallery states for test/screenshots_test.dart (and the
// a11y + dead-button sweeps) — the Activity screen (summary, visitor log,
// time-lapse, empty day, family viewer).
import 'package:flutter/material.dart';

import 'package:assisto/screens/watchman/activity_screen.dart';

import 'cctvactivity_fakes.dart';

ActivityScreen _s(String mode, String lang, {int tab = 0, bool owner = true}) => ActivityScreen(
    source: FakeActivity(mode, lang: lang),
    siteId: 7,
    siteName: 'Rahim Store',
    owner: owner,
    initialTab: tab,
    today: DateTime(2026, 11, 2, 23));

final Map<String, Widget Function(String)> cctvactivityShots = {
  'cact_summary': (lang) => _s('data', lang),
  'cact_visitors': (lang) => _s('data', lang, tab: 1),
  'cact_timelapse': (lang) => _s('data', lang, tab: 2),
  'cact_empty_day': (lang) => _s('empty', lang),
  'cact_viewer': (lang) => _s('viewer', lang, owner: false),
};
