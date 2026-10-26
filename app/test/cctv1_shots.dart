// cctv1: gallery states for test/screenshots_test.dart (and therefore the
// a11y guideline sweep + dead-button sweep) — the Home & shop watchman.
import 'package:flutter/material.dart';

import 'package:assisto/screens/watchman/watchman_add_camera.dart';
import 'package:assisto/screens/watchman/watchman_alerts.dart';
import 'package:assisto/screens/watchman/watchman_screen.dart';
import 'package:assisto/screens/watchman/watchman_setup.dart';
import 'package:assisto/screens/watchman/watchman_viewers.dart';
import 'package:assisto/screens/watchman/watchman_widgets.dart';
import 'package:assisto/screens/watchman/watchman_zones.dart';

import 'cctv1_fakes.dart';

final _site = {'id': 1, 'name': 'Dhanmondi flat', 'kind': 'home', 'gateway': 'pc',
               'enrollment_token': 'PAIR-CODE-FAKE-1'};
const _limits = {'included_cameras': 0, 'credits_per_extra_camera': 30, 'period_days': 30};

final Map<String, Widget Function(String)> cctv1Shots = {
  'wm_first_run': (_) => WatchmanScreen(source: FakeWatchman('empty')),
  'wm_places': (_) => WatchmanScreen(source: FakeWatchman('data'), guide: false),
  'wm_places_guide': (_) => WatchmanScreen(source: FakeWatchman('data'), guide: true),
  'wm_gateway_offline': (_) => WatchmanScreen(source: FakeWatchman('offline'), guide: false),
  'wm_viewer': (_) => WatchmanScreen(source: FakeWatchman('viewer'), guide: false),
  'wm_feature_off': (_) => WatchmanScreen(source: FakeWatchman('off'), guide: false),
  'wm_load_error': (_) => WatchmanScreen(source: FakeWatchman('fail'), guide: false),
  'wm_setup_kind': (_) => WatchmanSetupScreen(source: FakeWatchman(), canShop: false),
  'wm_setup_gateway': (_) => WatchmanSetupScreen(source: FakeWatchman(), canShop: true, initialStep: 1),
  'wm_add_pick': (_) => WatchmanAddCameraScreen(
      source: FakeWatchman(), site: _site, limits: _limits, credits: 120),
  'wm_add_form_imou': (_) => WatchmanAddCameraScreen(
      source: FakeWatchman(), site: _site, limits: _limits, credits: 120,
      recheck: FakeWatchman.camera()),
  'wm_check_ok': (_) => WatchmanAddCameraScreen(
      source: FakeWatchman(), site: _site, limits: _limits, credits: 120,
      recheck: FakeWatchman.camera(),
      initialResult: {'id': 5, 'status': 'done', 'request': {'vendor': 'imou'}, 'result': FakeWatchman.result('ok')}),
  'wm_check_auth_failed': (_) => WatchmanAddCameraScreen(
      source: FakeWatchman(), site: _site, limits: _limits, credits: 120,
      recheck: FakeWatchman.camera(),
      initialResult: {'id': 5, 'status': 'done', 'request': {'vendor': 'imou'}, 'result': FakeWatchman.result('auth')}),
  'wm_check_no_gateway': (_) => WatchmanAddCameraScreen(
      source: FakeWatchman(), site: _site, limits: _limits, credits: 120,
      recheck: FakeWatchman.camera(),
      initialResult: {'id': 5, 'status': 'expired', 'request': {'vendor': 'imou'},
                      'result': {'ok': false, 'code': 'gateway_no_answer'}}),
  'wm_zones': (_) => WatchmanZonesScreen(source: FakeWatchman(), camera: FakeWatchman.camera()),
  'wm_alerts': (_) => WatchmanAlertsScreen(source: FakeWatchman(), siteId: 1, owner: true),
  'wm_alerts_empty': (_) => WatchmanAlertsScreen(source: FakeWatchman('empty'), siteId: 1, owner: true),
  'wm_alerts_viewer': (_) => WatchmanAlertsScreen(source: FakeWatchman('viewer'), siteId: 1, owner: false),
  'wm_viewers': (_) => WatchmanViewersScreen(source: FakeWatchman(), siteId: 1),
  'wm_pair_sheet': (_) => Scaffold(body: WatchmanPairSheet(site: _site)),
};
